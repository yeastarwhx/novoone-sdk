package com.novosdk.ali;

import android.app.Application;
import android.content.Context;
import android.content.res.Resources;
import android.os.Handler;

import java.io.InputStream;

/**
 * 全局 Context / 主线程 Handler 工具（NovoSDK API 层，Acrobits 后端）。
 *
 * 全方法转发真身 cz.acrobits.ali.AndroidUtil（线上直连同源同行为；
 * 真身类为纯 Java 静态工具，早于 SDK init 调用安全）。此前复刻版
 * 与真身双源持有 Context，按线上一致原则收归真身单源（2026-11-06）。
 */
public class AndroidUtil {

    /** 主线程 Handler（转发真身同字段） */
    public static final Handler handler = cz.acrobits.ali.AndroidUtil.handler;

    private AndroidUtil() {
    }

    /** Application.onCreate 设置（早于一切 SDK 调用；转发真身） */
    public static void setContext(Application app) {
        cz.acrobits.ali.AndroidUtil.setContext(app);
    }

    /** 兼容重载：Context 传入（真身单签名接收 Context） */
    public static void setContext(Context context) {
        cz.acrobits.ali.AndroidUtil.setContext(context);
    }

    /** 任意可用 Context */
    public static Context getContext() {
        return cz.acrobits.ali.AndroidUtil.getContext();
    }

    /** Application 实例 */
    public static Context getApplicationContext() {
        return cz.acrobits.ali.AndroidUtil.getApplicationContext();
    }

    /** App 版本号 */
    public static String getApplicationVersion() {
        return cz.acrobits.ali.AndroidUtil.getApplicationVersion();
    }

    /** 打开 assets 资源流（调用方负责关闭） */
    public static InputStream getAsset(String name) {
        return cz.acrobits.ali.AndroidUtil.getAsset(name);
    }

    /** 主线程执行（已在主线程则同步执行，真身同语义） */
    public static void rendezvous(Runnable r) {
        cz.acrobits.ali.AndroidUtil.rendezvous(r);
    }

    /** 系统服务 */
    public static <T> T getSystemService(Class<T> service) {
        return cz.acrobits.ali.AndroidUtil.getSystemService(service);
    }

    /** 应用 Resources */
    public static Resources getResources() {
        return cz.acrobits.ali.AndroidUtil.getResources();
    }
}
