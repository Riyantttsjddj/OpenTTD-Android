package org.openttd.android;

import android.content.pm.ActivityInfo;
import android.os.Bundle;
import android.util.Log;

import org.libsdl.app.SDLActivity;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * The activity that hosts the game.
 *
 * SDLActivity loads the native libraries and runs SDL_main() on a thread of its
 * own; this subclass adds the two things OpenTTD needs on top of that: a
 * writable home for the game's files, and the read-only data shipped inside the
 * APK unpacked into it.
 *
 * Getting the order right is the whole point of this class. The environment has
 * to exist before the game looks at the filesystem, and the data has to be on
 * disk before the game looks for it, but {@code onCreate()} returning is what
 * lets SDL start the game. So the preparation runs on a background thread that
 * is started first thing in {@code onCreate()}, and {@link #getArguments()} --
 * which SDL calls on the game's own thread, immediately before entering native
 * code -- waits for it. The game therefore never starts until the filesystem is
 * ready, while the window still appears without waiting for the unpack.
 *
 * The two things that need to agree on the layout below are this class and the
 * game's own base-path detection, which reads the environment.
 */
public class OpenTTD extends SDLActivity {
    private static final String TAG = "OpenTTD";

    /** Directory inside the APK holding everything that has to be unpacked. */
    private static final String ASSET_ROOT = "game";
    /** Asset listing every unpacked asset, one relative path per line. */
    private static final String MANIFEST_ASSET = ASSET_ROOT + "/manifest.txt";
    /** Asset holding a fingerprint of the unpacked data. */
    private static final String VERSION_ASSET = ASSET_ROOT + "/data-version.txt";

    /** Preparation of the filesystem; completed before the game may start. */
    private Thread preparation;

    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL2", "main" };
    }

    /**
     * Keep the game in landscape, ignoring whatever the window reports.
     *
     * SDL asks for an orientation once its surface exists, and with no hint it
     * derives one from the window's width and height -- a comparison that can
     * go the wrong way at startup, when the window is still being sized.  That
     * would leave the game in portrait until the first rotation.  Overriding
     * the decision removes the guess: the app is landscape in both rotations
     * and never portrait.
     */
    @Override
    public void setOrientationBis(int w, int h, boolean resizable, String hint) {
        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        preparation = new Thread(this::prepareStorage, "OpenTTDPrepare");
        preparation.start();
        super.onCreate(savedInstanceState);
    }

    /**
     * Make sure the process ends once the user has actually left the game.
     *
     * The native SDL_main() returns when the player quits, which makes SDL's
     * Java glue finish() this activity the way Android expects.  That produces
     * this callback, where the activity can be torn down cleanly before the
     * process goes away.
     *
     * Killing the process here -- and only here, and only when the activity is
     * really finishing -- is what prevents the next launch from starting inside
     * a half-torn-down process.  Returning normally from SDL_main without
     * ending the process lets Android keep the process alive in the background
     * (for a fast cold start), and a second SDL_main() in that process would
     * restart the game on top of leftover state — the sound subsystem, the
     * window, and the asset manager that the first game left behind.  So end
     * the process explicitly once the activity is finished.
     *
     * isFinishing() distinguishes a real quit from a configuration change:
     * during a rotation the activity is recreated without finishing, and
     * killing the process there would drop the game the user is still playing.
     */
    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (isFinishing()) {
            android.os.Process.killProcess(android.os.Process.myPid());
        }
    }

    @Override
    protected String[] getArguments() {
        /* Runs on the thread that is about to call SDL_main(), so this is the
         * last point at which the filesystem can be made ready. Note that an
         * interrupt here is not a failure to report: it means the activity is
         * going away regardless. */
        try {
            preparation.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return new String[0];
    }

    private void prepareStorage() {
        try {
            prepareFilesystem();
            unpackGameData();
        } catch (Exception e) {
            Log.e(TAG, "Could not prepare the game's storage", e);
        }
    }

    /**
     * Point the game's home directory at this app's private storage, then
     * unpack the bundled data into it.
     *
     * Android gives an app no home directory, no writable working directory and
     * no temporary directory. OpenTTD derives all of its base paths from HOME
     * plus the XDG variables and creates its configuration and save
     * directories there, so all of them are set to the one location that is
     * writable.
     */
    private void prepareFilesystem() {
        File home = new File(getFilesDir(), "home");
        File cache = getCacheDir();

        //noinspection ResultOfMethodCallIgnored
        home.mkdirs();
        //noinspection ResultOfMethodCallIgnored
        cache.mkdirs();

        /* The personal directory is the home directory itself rather than a
         * nested one, so the roots below are used as given. */
        setEnv("HOME", home.getAbsolutePath());
        setEnv("XDG_DATA_HOME", home.getAbsolutePath());
        setEnv("XDG_CONFIG_HOME", home.getAbsolutePath());
        setEnv("XDG_CACHE_HOME", cache.getAbsolutePath());
        setEnv("TMPDIR", cache.getAbsolutePath());

        /* SDL turns the system locale into a LANG value, and a locale the game
         * has no translation for only produces a warning on every start. */
        setEnv("LANG", "en_US.UTF-8");
    }

    private static void setEnv(String name, String value) {
        SDLActivity.nativeSetenv(name, value);
    }

    /**
     * Unpack the game data bundled in the APK into the home directory.
     *
     * Assets are compressed inside the APK and cannot be read as files, so the
     * base sets, translations and fonts are copied out once. A fingerprint of
     * what was packaged decides whether the copy is still current, which also
     * covers reinstalling over an older version.
     */
    private void unpackGameData() {
        File home = new File(getFilesDir(), "home");
        File stamp = new File(getFilesDir(), "install.stamp");

        String wanted = readAsset(VERSION_ASSET);
        if (!wanted.isEmpty() && stamp.isFile() && wanted.equals(readFile(stamp))) {
            Log.i(TAG, "Bundled game data is already unpacked");
            return;
        }

        List<String> manifest = readAssetLines(MANIFEST_ASSET);
        if (manifest.isEmpty()) {
            Log.e(TAG, "Asset " + MANIFEST_ASSET + " is missing; the game will not find its data");
            return;
        }

        int copied = 0;
        long copiedBytes = 0;
        byte[] buffer = new byte[65536];

        for (String path : manifest) {
            File destination = new File(home, path);
            File parent = destination.getParentFile();
            if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
                Log.e(TAG, "Cannot create " + parent);
                continue;
            }

            try (InputStream in = getAssets().open(ASSET_ROOT + "/" + path);
                 OutputStream out = new FileOutputStream(destination)) {
                int read;
                while ((read = in.read(buffer)) > 0) {
                    out.write(buffer, 0, read);
                    copiedBytes += read;
                }
                copied++;
            } catch (IOException e) {
                Log.e(TAG, "Cannot unpack " + path + ": " + e);
            }
        }

        Log.i(TAG, "Unpacked " + copied + " file(s), " + copiedBytes + " bytes, into " + home);

        /* Only record success once the data is on disk, so an interrupted first
         * run is retried instead of leaving a half-populated directory. */
        if (copied > 0 && !wanted.isEmpty()) {
            try (OutputStream out = new FileOutputStream(stamp)) {
                out.write(wanted.getBytes(StandardCharsets.UTF_8));
            } catch (IOException e) {
                Log.w(TAG, "Cannot record the unpack state: " + e);
            }
        }
    }

    /** Read a whole asset as UTF-8, or return an empty string when it is absent. */
    private String readAsset(String name) {
        try (InputStream in = getAssets().open(name)) {
            return new String(readAll(in), StandardCharsets.UTF_8);
        } catch (IOException e) {
            Log.w(TAG, "Asset " + name + " is not available: " + e);
            return "";
        }
    }

    /** Read an asset and split it into trimmed lines. */
    private List<String> readAssetLines(String name) {
        List<String> lines = new ArrayList<>();
        for (String line : readAsset(name).split("\n")) {
            line = line.trim();
            if (!line.isEmpty()) lines.add(line);
        }
        return lines;
    }

    private static String readFile(File file) {
        try (InputStream in = new FileInputStream(file)) {
            return new String(readAll(in), StandardCharsets.UTF_8).trim();
        } catch (IOException e) {
            return "";
        }
    }

    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[65536];
        int read;
        while ((read = in.read(buffer)) > 0) {
            out.write(buffer, 0, read);
        }
        return out.toByteArray();
    }
}
