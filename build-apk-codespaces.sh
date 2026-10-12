#!/usr/bin/env bash
# Builds Tonearm.apk in a GitHub Codespace (x86-64 Linux) using the official Android SDK tools.
# Run from the repo root, where tonearm.html lives:  bash build-apk-codespaces.sh
set -e
ROOT=$PWD
SRC=$ROOT/tonearm.html
SDK=$HOME/android-sdk
BT=$SDK/build-tools/35.0.0
JAR=$SDK/platforms/android-35/android.jar
[ -f "$SRC" ] || { echo "tonearm.html not found in $ROOT. Upload it to the repo root first."; exit 1; }
command -v javac >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq openjdk-17-jdk-headless zip unzip; }

if [ ! -d "$BT" ]; then
  echo "Installing Android SDK (one time, about 2 minutes)..."
  mkdir -p "$SDK/cmdline-tools"
  wget -q -O /tmp/ct.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  unzip -q -o /tmp/ct.zip -d /tmp/ct && rm -rf "$SDK/cmdline-tools/latest" && mv /tmp/ct/cmdline-tools "$SDK/cmdline-tools/latest"
  yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null || true
  "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" "platforms;android-35" "build-tools;35.0.0"
fi

APP=$ROOT/android-app
mkdir -p "$APP/src/com/tonearm/player" "$APP/assets" && cd "$APP"
cp "$SRC" assets/index.html

cat > AndroidManifest.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.tonearm.player">
  <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="29"/>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
  <uses-permission android:name="android.permission.WAKE_LOCK"/>
  <application android:label="Tonearm" android:allowBackup="false" android:theme="@android:style/Theme.DeviceDefault.NoActionBar">
    <activity android:name=".MainActivity" android:exported="true" android:launchMode="singleTask"
      android:configChanges="orientation|screenSize|keyboardHidden|smallestScreenSize|screenLayout">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
    <service android:name=".PlaybackService" android:exported="false" android:foregroundServiceType="mediaPlayback"/>
  </application>
</manifest>
EOF

cat > src/com/tonearm/player/MainActivity.java <<'EOF'
package com.tonearm.player;
import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.webkit.*;

public class MainActivity extends Activity {
  static MainActivity inst;
  WebView web; ValueCallback<Uri[]> pending;

  /** Sends a transport command (play, pause, toggle, next, prev) into the page. */
  static void cmd(final String c) {
    final MainActivity a = inst;
    if (a == null || a.web == null) return;
    a.web.post(new Runnable() { public void run() {
      a.web.evaluateJavascript("window.tonearmCmd&&window.tonearmCmd('" + c + "')", null);
    }});
  }

  /** Called by the page as Android.update(title, artist, playing). */
  class Bridge {
    @JavascriptInterface public void update(final String t, final String a, final boolean p) {
      final PlaybackService s = PlaybackService.inst;
      if (s != null) {
        new Handler(Looper.getMainLooper()).post(new Runnable() { public void run() { s.apply(t, a, p); }});
      } else if (p) {
        Intent i = new Intent(MainActivity.this, PlaybackService.class).setAction("update")
          .putExtra("t", t).putExtra("a", a).putExtra("p", true);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i); else startService(i);
      }
    }
  }

  @Override protected void onCreate(Bundle b) {
    super.onCreate(b);
    inst = this;
    web = new WebView(this); setContentView(web);
    WebSettings s = web.getSettings();
    s.setJavaScriptEnabled(true); s.setDomStorageEnabled(true);
    s.setMediaPlaybackRequiresUserGesture(false);
    web.addJavascriptInterface(new Bridge(), "Android");
    web.setWebViewClient(new WebViewClient());
    web.setWebChromeClient(new WebChromeClient() {
      @Override public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
        if (pending != null) pending.onReceiveValue(null);
        pending = cb;
        Intent i = new Intent(Intent.ACTION_GET_CONTENT);
        i.addCategory(Intent.CATEGORY_OPENABLE); i.setType("*/*");
        i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        startActivityForResult(i, 1); return true;
      }
    });
    web.loadUrl("file:///android_asset/index.html");
  }
  @Override protected void onActivityResult(int req, int res, Intent d) {
    if (req != 1 || pending == null) return;
    Uri[] out = null;
    if (res == RESULT_OK && d != null) {
      if (d.getClipData() != null) {
        int n = d.getClipData().getItemCount(); out = new Uri[n];
        for (int i = 0; i < n; i++) out[i] = d.getClipData().getItemAt(i).getUri();
      } else if (d.getData() != null) out = new Uri[]{ d.getData() };
    }
    pending.onReceiveValue(out); pending = null;
  }
  // Note: we never call web.onPause(), so audio keeps playing with the screen off.
  @Override public void onBackPressed() { moveTaskToBack(true); }
  @Override protected void onDestroy() {
    inst = null;
    stopService(new Intent(this, PlaybackService.class));
    super.onDestroy();
  }
}
EOF

cat > src/com/tonearm/player/PlaybackService.java <<'EOF'
package com.tonearm.player;
import android.app.*;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

/** Foreground service: keeps playback alive, owns the notification, lock-screen and headset controls. */
public class PlaybackService extends Service {
  static PlaybackService inst;
  static final String CH = "tonearm_playback";
  MediaSession ms; PowerManager.WakeLock wl; AudioManager am;
  String title = "Tonearm", artist = ""; boolean playing = false;

  AudioManager.OnAudioFocusChangeListener focus = new AudioManager.OnAudioFocusChangeListener() {
    public void onAudioFocusChange(int c) {
      if (c == AudioManager.AUDIOFOCUS_LOSS || c == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) MainActivity.cmd("pause");
    }
  };

  @Override public void onCreate() {
    super.onCreate();
    inst = this;
    am = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
    wl = ((PowerManager) getSystemService(Context.POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tonearm:play");
    if (Build.VERSION.SDK_INT >= 26) {
      NotificationChannel c = new NotificationChannel(CH, "Playback", NotificationManager.IMPORTANCE_LOW);
      ((NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE)).createNotificationChannel(c);
    }
    ms = new MediaSession(this, "Tonearm");
    ms.setCallback(new MediaSession.Callback() {
      @Override public void onPlay() { MainActivity.cmd("play"); }
      @Override public void onPause() { MainActivity.cmd("pause"); }
      @Override public void onSkipToNext() { MainActivity.cmd("next"); }
      @Override public void onSkipToPrevious() { MainActivity.cmd("prev"); }
    });
    ms.setActive(true);
  }

  @Override public int onStartCommand(Intent i, int flags, int id) {
    String a = i == null ? null : i.getAction();
    if ("update".equals(a)) {
      apply(i.getStringExtra("t"), i.getStringExtra("a"), i.getBooleanExtra("p", true));
    } else if (a != null) {
      MainActivity.cmd(a);  // prev / toggle / next from the notification buttons
    } else {
      apply(title, artist, playing);
    }
    return START_NOT_STICKY;
  }

  void apply(String t, String a, boolean p) {
    title = t == null ? "Tonearm" : t; artist = a == null ? "" : a;
    if (p && !playing) am.requestAudioFocus(focus, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
    playing = p;
    if (playing && !wl.isHeld()) wl.acquire();
    if (!playing && wl.isHeld()) wl.release();
    ms.setMetadata(new MediaMetadata.Builder()
      .putString(MediaMetadata.METADATA_KEY_TITLE, title)
      .putString(MediaMetadata.METADATA_KEY_ARTIST, artist).build());
    ms.setPlaybackState(new PlaybackState.Builder()
      .setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE
        | PlaybackState.ACTION_SKIP_TO_NEXT | PlaybackState.ACTION_SKIP_TO_PREVIOUS)
      .setState(playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f)
      .build());
    startForeground(1, buildNotification());
  }

  PendingIntent act(String action) {
    int f = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0);
    return PendingIntent.getService(this, action.hashCode(), new Intent(this, PlaybackService.class).setAction(action), f);
  }

  Notification buildNotification() {
    Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CH) : new Notification.Builder(this);
    int f = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0);
    b.setSmallIcon(android.R.drawable.ic_media_play)
     .setContentTitle(title).setContentText(artist).setOngoing(playing)
     .setVisibility(Notification.VISIBILITY_PUBLIC)
     .setContentIntent(PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), f))
     .addAction(android.R.drawable.ic_media_previous, "Previous", act("prev"))
     .addAction(playing ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play, playing ? "Pause" : "Play", act("toggle"))
     .addAction(android.R.drawable.ic_media_next, "Next", act("next"))
     .setStyle(new Notification.MediaStyle().setMediaSession(ms.getSessionToken()).setShowActionsInCompactView(0, 1, 2));
    return b.build();
  }

  @Override public void onTaskRemoved(Intent r) { stopForeground(true); stopSelf(); }
  @Override public void onDestroy() {
    inst = null;
    if (wl.isHeld()) wl.release();
    am.abandonAudioFocus(focus);
    ms.release();
    super.onDestroy();
  }
  @Override public IBinder onBind(Intent i) { return null; }
}
EOF

[ -f "$ROOT/key.jks" ] || keytool -genkey -keystore "$ROOT/key.jks" -alias k -keyalg RSA -keysize 2048 -validity 10000 -storepass tonearm -keypass tonearm -dname "CN=Tonearm"
rm -rf build && mkdir -p build/classes
"$BT/aapt2" link -o build/base.apk -I "$JAR" --manifest AndroidManifest.xml -A assets --min-sdk-version 24 --target-sdk-version 29
javac --release 8 -nowarn -cp "$JAR" -d build/classes src/com/tonearm/player/*.java
"$BT/d8" --release --min-api 24 --lib "$JAR" --output build $(find build/classes -name '*.class')
(cd build && zip -q base.apk classes.dex)
"$BT/zipalign" -f 4 build/base.apk build/aligned.apk
"$BT/apksigner" sign --ks "$ROOT/key.jks" --ks-pass pass:tonearm --out "$ROOT/Tonearm.apk" build/aligned.apk
echo "Done: $ROOT/Tonearm.apk  (right-click it in the Explorer and choose Download)"
