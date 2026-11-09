import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
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
    public static void main(String[] args) throws Exception {
        int size = Integer.parseInt(args[0]);
        Looper.prepareMainLooper();
        Class<?> threadClass = Class.forName("android.app.ActivityThread");
        Object thread = threadClass.getMethod("systemMain").invoke(null);
        Context context = (Context) threadClass.getMethod("getSystemContext").invoke(thread);
        PackageManager manager = context.getPackageManager();
        PrintStream out = new PrintStream(System.out, false, "UTF-8");
        for (int index = 1; index < args.length; index++) {
            String name = args[index];
            try {
                Drawable icon;
                Intent launch = manager.getLaunchIntentForPackage(name);
                if (launch != null && launch.getComponent() != null) {
                    icon = manager.getActivityIcon(launch.getComponent());
                } else {
                    icon = manager.getApplicationIcon(name);
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
