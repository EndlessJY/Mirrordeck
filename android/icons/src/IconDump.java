import android.content.Context;
import android.content.Intent;
import android.content.ComponentName;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;

/**
 * Prints the launcher icon of each given package as "package base64-png",
 * or "package -" when it has none. Run with app_process from adb shell:
 *
 *   CLASSPATH=/data/local/tmp/lanadb-icons.dex app_process / IconDump 96 pkg...
 */
public final class IconDump {
    private static Drawable launcherIcon(PackageManager manager, String name) throws Exception {
        Intent launch = manager.getLaunchIntentForPackage(name);
        if (launch != null && launch.getComponent() != null) {
            return manager.getActivityIcon(launch.getComponent());
        }
        return manager.getApplicationIcon(name);
    }

    private static Drawable rawIcon(PackageManager manager, String name) throws Exception {
        ApplicationInfo app = manager.getApplicationInfo(name, 0);
        int resource = app.icon != 0 ? app.icon : app.roundIcon;
        Intent launch = manager.getLaunchIntentForPackage(name);
        ComponentName component = launch != null ? launch.getComponent() : null;
        if (component != null) {
            ActivityInfo activity = manager.getActivityInfo(component, 0);
            if (activity.getIconResource() != 0) {
                resource = activity.getIconResource();
            }
        }
        if (resource == 0) {
            throw new IllegalStateException("no icon");
        }
        Resources resources = manager.getResourcesForApplication(app);
        return resources.getDrawableForDensity(resource, 480, null);
    }

    public static void main(String[] args) throws Exception {
        int size = Integer.parseInt(args[0]);
        Looper.prepareMainLooper();
        Class<?> threadClass = Class.forName("android.app.ActivityThread");
        Object thread = threadClass.getMethod("systemMain").invoke(null);
        Context system = (Context) threadClass.getMethod("getSystemContext").invoke(thread);
        // Calls made as "android" from the shell's uid are refused by some
        // vendor icon themes (ColorOS reads a setting for them); as the shell
        // package they match the caller.
        Context context = system;
        try {
            context = system.createPackageContext("com.android.shell", 0);
        } catch (Throwable ignored) {
            // keep the system context
        }
        PackageManager manager = context.getPackageManager();
        PrintStream out = new PrintStream(System.out, false, "UTF-8");
        for (int index = 1; index < args.length; index++) {
            String name = args[index];
            try {
                Drawable icon = null;
                try {
                    icon = launcherIcon(manager, name);
                } catch (Throwable ignored) {
                    // fall back to the app's own icon resource below
                }
                if (icon == null) {
                    icon = rawIcon(manager, name);
                }
                if (icon == null) {
                    throw new IllegalStateException("no icon");
                }
                Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
                icon.setBounds(0, 0, size, size);
                icon.draw(new Canvas(bitmap));
                ByteArrayOutputStream png = new ByteArrayOutputStream();
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, png);
                bitmap.recycle();
                out.println(name + " " + Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP));
            } catch (Throwable error) {
                out.println(name + " -");
            }
            out.flush();
        }
        System.exit(0);
    }
}
