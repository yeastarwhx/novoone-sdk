package com.yeastar.sipcore;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.UUID;
import java.util.concurrent.Executors;

import cz.acrobits.ali.AndroidUtil;

/**
 * FCM token 上报 uc-push（SDK 内置，对齐 Acrobits pushTokenReporter 机制）。
 *
 * 报文契约（旧栈 26.9.x 实测）：POST {pushTokenReporterUrl}，
 * Header 取 pushTokenReporterCustomHeaders（Authorization Bearer）；
 * body 含 username/selector/userAgentId/token_calls/token_msgs/clientType/
 * provider/tenantCode/appVersion/deviceModel/appId。
 *
 * 关键字段：
 * - token_calls/token_msgs = base64(FCM token 完整原文)——不可截取/替换
 *   前缀，否则服务器以下发目标解码时被 FCM 拒绝，上报 SUCCESS 但静默不推
 * - selector = <一次生成持久化的40位大写HEX>:<固定尾段>——服务器按
 *   (username, selector) UPSERT、按推送 payload 的 s= 匹配；首段随机
 *   不影响，尾段为协议标识必须对齐
 *
 * 配置来源：AccountXml 的 pushTokenReporterUrl/pushTokenReporterCustomHeaders
 * 字段（App 创建账户时写入，与 Acrobits SDK 原生机制同源）；body 由 SDK
 * 按契约自组（不经 PostData 模板，避免占位符语义漂移）。
 *
 * 触发时机：token 到达（setRegistrationId）即时 + 注册成功（200）补报；
 * 凭证/token 未就绪时挂起，待另一侧到达后随下一时机补发。
 */
final class PushTokenReporter {

    private static final String TAG = "Acrobits.SdkBridge";

    private static final String PREFS_NAME = "push_token_report";
    private static final String KEY_SELECTOR = "selector";
    private static final String KEY_FCM_TOKEN = "fcm_token";

    /** selector 尾段：旧栈 SDK 推送协议固定值（服务器 payload s= 带回匹配） */
    private static final String SELECTOR_TAIL = "256F773B";

    private static final int CONNECT_TIMEOUT_MS = 5000;
    private static final int READ_TIMEOUT_MS = 5000;

    /** 一次性短请求专用单线程（不占引擎/App 线程资源） */
    private static final java.util.concurrent.ExecutorService EXECUTOR =
            Executors.newSingleThreadExecutor(new java.util.concurrent.ThreadFactory() {
                @Override
                public Thread newThread(Runnable r) {
                    Thread t = new Thread(r, "PushTokenReporter");
                    t.setDaemon(true);
                    return t;
                }
            });

    private PushTokenReporter() {
    }

    /** FCM token 到达（Instance.Notifications.Push.setRegistrationId） */
    static void onToken(String token) {
        if (token == null || token.isEmpty()) {
            return;
        }
        prefs().edit().putString(KEY_FCM_TOKEN, token).apply();
        reportAsync();
    }

    /** 注册成功（onRegisterState 200）——凭证就绪，token 已在则补发 */
    static void onRegistered() {
        reportAsync();
    }

    private static void reportAsync() {
        EXECUTOR.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    report();
                } catch (Throwable t) {
                    android.util.Log.w(TAG, "push token report failed (retry next trigger): " + t);
                }
            }
        });
    }

    private static void report() throws Exception {
        SdkBridge.AccountSnapshot snap = SdkBridge.get().accountSnapshot();
        Context ctx = AndroidUtil.getApplicationContext();
        if (snap == null || ctx == null
                || snap.pushTokenReporterUrl == null || snap.pushTokenReporterUrl.isEmpty()) {
            android.util.Log.i(TAG, "push token report pending: no url/snapshot");
            return;
        }
        SharedPreferences sp = prefs();
        String token = sp.getString(KEY_FCM_TOKEN, null);
        String username = snap.username;
        if (token == null || token.isEmpty()
                || username == null || username.isEmpty()) {
            /* 凭证/token 冷启动未就绪：挂起，待另一侧到达后随下一时机补发 */
            android.util.Log.i(TAG, "push token report pending: missing token/username");
            return;
        }

        StringBuilder body = new StringBuilder("{");
        body.append("\"username\":\"").append(jsonEscape(username)).append("\",");
        body.append("\"selector\":\"").append(ensureSelector(sp)).append("\",");
        body.append("\"userAgentId\":\"").append(userAgentId(ctx)).append("\",");
        body.append("\"token_calls\":\"").append(wrapToken(token)).append("\",");
        body.append("\"token_msgs\":\"").append(wrapToken(token)).append("\",");
        body.append("\"clientType\":\"Android\",");
        body.append("\"provider\":\"FCM\",");
        body.append("\"tenantCode\":\"").append(jsonEscape(tenantOf(snap))).append("\",");
        body.append("\"appVersion\":\"").append(jsonEscape(appVersion(ctx))).append("\",");
        body.append("\"deviceModel\":\"").append(jsonEscape(deviceModel())).append("\",");
        body.append("\"appId\":\"").append(jsonEscape(ctx.getPackageName())).append("\"");
        body.append("}");

        String urlStr = snap.pushTokenReporterUrl;
        HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
        try {
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
            conn.setReadTimeout(READ_TIMEOUT_MS);
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/json");
            /* HTTP UA 对齐旧栈 SDK HTTP 层（服务器链路按此前缀识别） */
            conn.setRequestProperty("User-Agent",
                    "Mobile/" + appVersion(ctx) + "-Android-" + userAgentId(ctx));
            if (snap.pushTokenReporterCustomHeaders != null
                    && !snap.pushTokenReporterCustomHeaders.isEmpty()) {
                String[] kv = snap.pushTokenReporterCustomHeaders.split(":", 2);
                if (kv.length == 2) {
                    conn.setRequestProperty(kv[0].trim(), kv[1].trim());
                }
            }
            byte[] payload = body.toString().getBytes("UTF-8");
            conn.setFixedLengthStreamingMode(payload.length);
            OutputStream os = conn.getOutputStream();
            try {
                os.write(payload);
            } finally {
                os.close();
            }
            int code = conn.getResponseCode();
            if (code >= 200 && code < 300) {
                android.util.Log.i(TAG, "push token reported: " + username + " http=" + code);
            } else {
                android.util.Log.w(TAG, "push token report rejected: http=" + code);
            }
        } finally {
            conn.disconnect();
        }
    }

    private static SharedPreferences prefs() {
        return AndroidUtil.getApplicationContext()
                .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
    }

    /** selector：首段一次生成持久化（SHA-1 of 随机种子），尾段协议固定值 */
    private static String ensureSelector(SharedPreferences sp) throws Exception {
        String cached = sp.getString(KEY_SELECTOR, null);
        if (cached != null && !cached.isEmpty()) {
            return cached;
        }
        String seed = UUID.randomUUID().toString() + UUID.randomUUID().toString();
        byte[] sha1 = MessageDigest.getInstance("SHA-1").digest(seed.getBytes("UTF-8"));
        StringBuilder hex = new StringBuilder(40);
        for (byte b : sha1) {
            hex.append(String.format("%02X", b));
        }
        String selector = hex + ":" + SELECTOR_TAIL;
        sp.edit().putString(KEY_SELECTOR, selector).apply();
        return selector;
    }

    /** token 包装：base64(FCM token 完整原文) */
    private static String wrapToken(String fcmToken) {
        return android.util.Base64.encodeToString(
                fcmToken.getBytes(java.nio.charset.StandardCharsets.UTF_8),
                android.util.Base64.NO_WRAP);
    }

    private static String userAgentId(Context ctx) {
        String id = android.provider.Settings.Secure.getString(
                ctx.getContentResolver(), android.provider.Settings.Secure.ANDROID_ID);
        return id != null && !id.isEmpty() ? id : "unknown";
    }

    private static String appVersion(Context ctx) {
        try {
            String v = ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0).versionName;
            return v != null ? v : "";
        } catch (Throwable t) {
            return "";
        }
    }

    private static String deviceModel() {
        return Build.MANUFACTURER + " " + Build.MODEL;
    }

    /** tenantCode：注册 host 剥端口后的裸域（按首个 ':' 截断——SIP 域名/IPv4
     *  场景适用；IPv6 字面量 host 不支持，出现时需另行适配） */
    private static String tenantOf(SdkBridge.AccountSnapshot snap) {
        String host = snap.host != null ? snap.host : "";
        int colon = host.indexOf(':');
        return colon > 0 ? host.substring(0, colon) : host;
    }

    private static String jsonEscape(String s) {
        if (s == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':
                    sb.append("\\\"");
                    break;
                case '\\':
                    sb.append("\\\\");
                    break;
                case '\n':
                    sb.append("\\n");
                    break;
                case '\r':
                    sb.append("\\r");
                    break;
                case '\t':
                    sb.append("\\t");
                    break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                    break;
            }
        }
        return sb.toString();
    }
}
