package cz.acrobits.ali;

import android.app.Application;
import android.content.Context;
import android.content.res.Resources;
import android.os.Handler;
import android.os.Looper;

import java.io.IOException;
import java.io.InputStream;

/**
 * 全局 Context / 主线程 Handler 工具（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * 包名与类名与 Acrobits SDK 完全一致，宿主 App 零改动编译；
 * 内部仅为轻量 Context 持有 + 主线程调度。
 */
public class AndroidUtil {

    /** 主线程 Handler（App 侧广泛用于 post / postDelayed） */
    public static final Handler handler = new Handler(Looper.getMainLooper());

    private static Application sApplication;

    private AndroidUtil() {
    }

    /**
     * Application.onCreate 设置（早于一切 SDK 调用）。
     * {@link #getApplicationContext()} 返回该实例（App 依赖此语义做
     * as MainApplication 强转）。
     */
    public static void setContext(Application app) {
        sApplication = app;
    }

    /** 兼容 Acrobits：Context 传入时同样接受（取 applicationContext） */
    public static void setContext(Context context) {
        if (context instanceof Application) {
            sApplication = (Application) context;
        } else if (context != null && context.getApplicationContext() != null) {
            Object app = context.getApplicationContext();
            if (app instanceof Application) {
                sApplication = (Application) app;
            }
        }
    }

    /** 任意可用 Context；未初始化抛 IllegalStateException */
    public static Context getContext() {
        return requireApp("getContext");
    }

    /** Application 实例（setContext 传入者；MainApplication.instance() 依赖强转成功） */
    public static Context getApplicationContext() {
        return requireApp("getApplicationContext");
    }

    private static Application requireApp(String where) {
        if (sApplication == null) {
            throw new IllegalStateException(
                    "AndroidUtil not initialized - call AndroidUtil.setContext(application) first (" + where + ")");
        }
        return sApplication;
    }

    /** App 版本号（versionName；取失败返回 null） */
    public static String getApplicationVersion() {
        try {
            return requireApp("getApplicationVersion").getPackageManager()
                    .getPackageInfo(requireApp("getApplicationVersion").getPackageName(), 0).versionName;
        } catch (Exception e) {
            return null;
        }
    }

    /** 打开 assets 资源流（调用方负责关闭） */
    public static InputStream getAsset(String name) {
        try {
            return requireApp("getAsset").getAssets().open(name);
        } catch (IOException e) {
            return null;
        }
    }

    /** 主线程执行（已在主线程则同步执行） */
    public static void rendezvous(Runnable r) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            r.run();
        } else {
            handler.post(r);
        }
    }

    /** 系统服务（Context.getSystemService(Class)） */
    public static <T> T getSystemService(Class<T> service) {
        try {
            return requireApp("getSystemService").getSystemService(service);
        } catch (Exception e) {
            return null;
        }
    }

    /** 应用 Resources */
    public static Resources getResources() {
        return requireApp("getResources").getResources();
    }
}
