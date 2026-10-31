/*
 * pjsip_jni.c - ys_pjsua_app (C) <-> JniBridge (Java) 桥
 *
 * novoone-app :sip-core（移植自 novoone-sip-demo/app/src/main/cpp/pjsip_jni.c）：
 *   - 12 个 native 入口 1:1 对齐 ys_pjsua_app.h API；
 *   - 6 个 ys_* 回调在 pjsua worker 线程触发，AttachCurrentThread 后
 *     调 JniBridge.onXxx 静态方法（Java 侧再切主线程收敛状态）；
 *   - jclass/jmethodID 在首个 native 调用时缓存（pjlib 自带
 *     JNI_OnLoad，本模块不能再定义一个；回调线程 FindClass 会因
 *     classloader 上下文缺失而失败，禁止在回调里 FindClass）。
 *
 * 相对 demo 版差异：
 *   - 包名 com.novoone.sipdemo -> com.yeastar.sipcore；
 *   - ys_incoming_call_sdp 回调追加 request_id / caller_id_name 两个
 *     INVITE 头参数（仅回调期间有效，Java 侧立即留存）；
 *   - 新增 nativeRejectCall（486 拒接）/ nativeSetOutgoingInviteHeaders
 *     （呼出 INVITE 附加头，一次性消费）；
 *   - 新增 nativeUnregisterAccount（登出注销）。
 *
 * 风格对齐仓库约定：C89 变量声明块首、4 空格缩进、K&R 大括号。
 */

#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "ys_pjsua_app.h"

/* ------------------------------------------------------------------ */
/* 全局缓存（ensure_init 一次性填充）                                   */
/* ------------------------------------------------------------------ */

/* pjlib 在 PJ_ANDROID 下自带 JNI_OnLoad（os_core_unix.c，仅缓存
 * pj_jni_jvm），静态库链入后 .so 中只允许一个 JNI_OnLoad，故本模块
 * 不再定义 JNI_OnLoad，改为在首个 native 调用时（必为带 classloader
 * 上下文的 Java 线程）一次性缓存 jclass/jmethodID——效果等同于
 * JNI_OnLoad 缓存：pjsua worker 线程的回调绝不 FindClass。 */

static JavaVM *g_vm = NULL;
static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;
static jclass g_bridge_class = NULL;        /* 全局引用，JniBridge */
static jmethodID g_mid_on_register_state;
static jmethodID g_mid_on_call_state;
static jmethodID g_mid_on_answer_sdp;
static jmethodID g_mid_on_incoming_sdp;
static jmethodID g_mid_on_transfer_state;
static jmethodID g_mid_on_reinvite_sdp;
static jmethodID g_mid_on_log;
static jmethodID g_mid_on_ip_change_progress;

/* 首个 native 调用时初始化（见上）：FindClass 只能在此处执行。
 * native 入口全部由 Java 主线程串行先行调用（nativeSetTransport），
 * 竞态窗口不存在；防御性二次检查容忍重复初始化（多一个全局引用
 * 仅泄漏无副作用）。 */
/* 返回 0 成功 / -1 失败（类查找失败：如 R8 混淆改类名）。失败后
 * g_bridge_class 保持 NULL：native 入口一律返回错误（Java 引擎标记
 * broken），回调入口判空返回——绝不以 NULL methodID 调
 * CallStaticVoidMethod（直接 native crash）。互斥锁防多线程首调
 * 竞争（正常路径主线程串行先行，防御性兜底）。 */
static int ensure_init(JNIEnv *env)
{
    jclass clazz;

    if (g_bridge_class != NULL)
        return 0;

    pthread_mutex_lock(&g_init_lock);
    if (g_bridge_class == NULL) {
        (*env)->GetJavaVM(env, &g_vm);

        clazz = (*env)->FindClass(env, "com/yeastar/sipcore/JniBridge");
        if (clazz == NULL) {
            (*env)->ExceptionClear(env);
            pthread_mutex_unlock(&g_init_lock);
            return -1;
        }

        g_bridge_class = (*env)->NewGlobalRef(env, clazz);
        (*env)->DeleteLocalRef(env, clazz);
        if (g_bridge_class == NULL) {
            pthread_mutex_unlock(&g_init_lock);
            return -1;
        }

        g_mid_on_register_state = (*env)->GetStaticMethodID(
            env, g_bridge_class, "onRegisterState", "(IILjava/lang/String;)V");
        g_mid_on_call_state = (*env)->GetStaticMethodID(
            env, g_bridge_class, "onCallState", "(III)V");
        g_mid_on_answer_sdp = (*env)->GetStaticMethodID(
            env, g_bridge_class, "onAnswerSdp", "(ILjava/lang/String;)V");
        /* 来电 offer + 两个 INVITE 头（X-Request-ID / X-Nov-Caller-ID-Name）
         * + From URI 号码，缺失时 C 侧传 NULL（Java 收到 null） */
        g_mid_on_incoming_sdp = (*env)->GetStaticMethodID(
            env, g_bridge_class, "onIncomingSdp",
            "(ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;"
            "Ljava/lang/String;)V");
        g_mid_on_reinvite_sdp = (*env)->GetStaticMethodID(
            env, g_bridge_class, "onReinviteSdp", "(ILjava/lang/String;)V");
        g_mid_on_transfer_state = (*env)->GetStaticMethodID(
            env, g_bridge_class, "onTransferState", "(III)V");
        g_mid_on_log = (*env)->GetStaticMethodID(
            env, g_bridge_class, "onLog", "(ILjava/lang/String;)V");
        /* 网络切换恢复进度（两个标量，无指针生命周期问题） */
        g_mid_on_ip_change_progress = (*env)->GetStaticMethodID(
            env, g_bridge_class, "onIpChangeProgress", "(II)V");

        if ((*env)->ExceptionCheck(env))
            (*env)->ExceptionClear(env);

        /* R8 混淆改方法名时 GetStaticMethodID 返回 NULL——此时不得以
         * NULL methodID 调 CallStaticVoidMethod（未定义行为，native crash），
         * 回滚全局引用并返回失败 */
        if (g_mid_on_register_state == NULL || g_mid_on_call_state == NULL ||
            g_mid_on_answer_sdp == NULL || g_mid_on_incoming_sdp == NULL ||
            g_mid_on_transfer_state == NULL || g_mid_on_reinvite_sdp == NULL ||
            g_mid_on_log == NULL || g_mid_on_ip_change_progress == NULL) {
            (*env)->DeleteGlobalRef(env, g_bridge_class);
            g_bridge_class = NULL;
            pthread_mutex_unlock(&g_init_lock);
            return -1;
        }
    }
    pthread_mutex_unlock(&g_init_lock);
    return 0;
}

/* 取当前线程 env：未 attach 的线程临时 attach 并由调用方 detach。
 * 返回 0 成功（*pattached=1 表示本次临时 attach）。 */
static int get_jni_env(JNIEnv **penv, int *pattached)
{
    *pattached = 0;
    *penv = NULL;

    if ((*g_vm)->GetEnv(g_vm, (void **)penv, JNI_VERSION_1_6) == JNI_OK)
        return 0;                           /* 已 attach（如主线程） */

    if ((*g_vm)->AttachCurrentThread(g_vm, penv, NULL) != JNI_OK)
        return -1;

    *pattached = 1;
    return 0;
}

/* const char* -> jstring：NULL 转 Java null（头缺失语义） */
static jstring cstr_to_jstring(JNIEnv *env, const char *s)
{
    if (s == NULL)
        return NULL;
    return (*env)->NewStringUTF(env, s);
}

/* ------------------------------------------------------------------ */
/* ys_pjsua_callback C 回调（pjsua worker 线程）                        */
/* ------------------------------------------------------------------ */

static void ys_cb_register_state(pjsua_acc_id acc_id, int status,
                                 const char *text)
{
    if (g_bridge_class == NULL)
        return;

    JNIEnv *env;
    int attached = 0;

    if (get_jni_env(&env, &attached) != 0)
        return;

    {
        jstring jtext = (*env)->NewStringUTF(env, text ? text : "");
        (*env)->CallStaticVoidMethod(env, g_bridge_class,
                                     g_mid_on_register_state,
                                     (jint)acc_id, (jint)status, jtext);
        if ((*env)->ExceptionCheck(env))
            (*env)->ExceptionClear(env);
    }

    if (attached)
        (*g_vm)->DetachCurrentThread(g_vm);
}

static void ys_cb_call_state(pjsua_call_id call_id, int state,
                             int last_status)
{
    if (g_bridge_class == NULL)
        return;

    JNIEnv *env;
    int attached = 0;

    if (get_jni_env(&env, &attached) != 0)
        return;

    (*env)->CallStaticVoidMethod(env, g_bridge_class, g_mid_on_call_state,
                                 (jint)call_id, (jint)state,
                                 (jint)last_status);
    if ((*env)->ExceptionCheck(env))
        (*env)->ExceptionClear(env);

    if (attached)
        (*g_vm)->DetachCurrentThread(g_vm);
}

static void ys_cb_call_answer_sdp(pjsua_call_id call_id, const char *sdp)
{
    if (g_bridge_class == NULL)
        return;

    JNIEnv *env;
    int attached = 0;

    if (get_jni_env(&env, &attached) != 0)
        return;

    {
        jstring jsdp = (*env)->NewStringUTF(env, sdp ? sdp : "");
        (*env)->CallStaticVoidMethod(env, g_bridge_class,
                                     g_mid_on_answer_sdp,
                                     (jint)call_id, jsdp);
        if ((*env)->ExceptionCheck(env))
            (*env)->ExceptionClear(env);
    }

    if (attached)
        (*g_vm)->DetachCurrentThread(g_vm);
}

/* REFER 转接进度（NOTIFY 状态码；final 2xx = 转接成功，应用挂断本方） */
static void ys_cb_call_transfer_state(pjsua_call_id call_id, int status,
                                       int is_final)
{
    if (g_bridge_class == NULL)
        return;

    JNIEnv *env;
    int attached = 0;

    if (get_jni_env(&env, &attached) != 0)
        return;

    {
        (*env)->CallStaticVoidMethod(env, g_bridge_class,
                                     g_mid_on_transfer_state,
                                     (jint)call_id, (jint)status,
                                     (jint)is_final);
        if ((*env)->ExceptionCheck(env))
            (*env)->ExceptionClear(env);
    }

    if (attached)
        (*g_vm)->DetachCurrentThread(g_vm);
}

/* 来电 INVITE：offer SDP + X-Request-ID / X-Nov-Caller-ID-Name 头 +
 * From URI user 部分（对端号码）。指针均仅回调期间有效，经
 * NewStringUTF 拷入 Java String 即完成留存（Java 侧无生命周期问题）。 */
static void ys_cb_incoming_call_sdp(pjsua_call_id call_id, const char *sdp,
                                    const char *request_id,
                                    const char *caller_id_name,
                                    const char *remote_number)
{
    if (g_bridge_class == NULL)
        return;

    JNIEnv *env;
    int attached = 0;

    if (get_jni_env(&env, &attached) != 0)
        return;

    {
        jstring jsdp = (*env)->NewStringUTF(env, sdp ? sdp : "");
        jstring jreq = cstr_to_jstring(env, request_id);
        jstring jcid = cstr_to_jstring(env, caller_id_name);
        jstring jnum = cstr_to_jstring(env, remote_number);
        (*env)->CallStaticVoidMethod(env, g_bridge_class,
                                     g_mid_on_incoming_sdp,
                                     (jint)call_id, jsdp, jreq, jcid, jnum);
        if ((*env)->ExceptionCheck(env))
            (*env)->ExceptionClear(env);
    }

    if (attached)
        (*g_vm)->DetachCurrentThread(g_vm);
}

static void ys_cb_call_reinvite_sdp(pjsua_call_id call_id, const char *sdp)
{
    if (g_bridge_class == NULL)
        return;

    JNIEnv *env;
    int attached = 0;

    if (get_jni_env(&env, &attached) != 0)
        return;

    {
        jstring jsdp = (*env)->NewStringUTF(env, sdp ? sdp : "");
        (*env)->CallStaticVoidMethod(env, g_bridge_class,
                                     g_mid_on_reinvite_sdp,
                                     (jint)call_id, jsdp);
        if ((*env)->ExceptionCheck(env))
            (*env)->ExceptionClear(env);
    }

    if (attached)
        (*g_vm)->DetachCurrentThread(g_vm);
}

/* pjsua 日志（高频）：level<=3 进 UI，全量由 Java 侧转 logcat */
static void ys_cb_log(int level, const char *msg)
{
    JNIEnv *env;
    int attached = 0;

    if (g_bridge_class == NULL)
        return;

    if (!msg || !msg[0])
        return;

    if (get_jni_env(&env, &attached) != 0)
        return;

    {
        jstring jmsg = (*env)->NewStringUTF(env, msg);
        (*env)->CallStaticVoidMethod(env, g_bridge_class, g_mid_on_log,
                                     (jint)level, jmsg);
        if ((*env)->ExceptionCheck(env))
            (*env)->ExceptionClear(env);
    }

    if (attached)
        (*g_vm)->DetachCurrentThread(g_vm);
}

/* 网络切换恢复进度：step=pjsua_ip_change_op、status=pj_status_t，均为
 * 值拷贝，直接转发（COMPLETED 步由 Java 侧常量判定） */
static void ys_cb_ip_change_progress(int step, int status)
{
    if (g_bridge_class == NULL)
        return;

    JNIEnv *env;
    int attached = 0;

    if (get_jni_env(&env, &attached) != 0)
        return;

    (*env)->CallStaticVoidMethod(env, g_bridge_class,
                                 g_mid_on_ip_change_progress,
                                 (jint)step, (jint)status);
    if ((*env)->ExceptionCheck(env))
        (*env)->ExceptionClear(env);

    if (attached)
        (*g_vm)->DetachCurrentThread(g_vm);
}

/* ------------------------------------------------------------------ */
/* Java native 入口                                                    */
/* ------------------------------------------------------------------ */

/* String -> C 缓冲（str 为 NULL/空时返回 -1） */
static int copy_jstring(JNIEnv *env, jstring js, char *dst, int dst_size)
{
    const char *cs;
    int n;

    if (!js)
        return -1;

    cs = (*env)->GetStringUTFChars(env, js, NULL);
    if (!cs)
        return -1;

    n = (int)strlen(cs);
    if (n > dst_size - 1)
        n = dst_size - 1;
    memcpy(dst, cs, (size_t)n);
    dst[n] = '\0';

    (*env)->ReleaseStringUTFChars(env, js, cs);
    return 0;
}

JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeSetTransport(JNIEnv *env,
                                                      jclass clazz,
                                                      jint transport)
{
    if (ensure_init(env) != 0)
        return -1;

    (void)env;
    (void)clazz;
    return (jint)ys_set_sip_transport((int)transport);
}

JNIEXPORT void JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeSetUserAgent(JNIEnv *env,
                                                      jclass clazz,
                                                      jstring ua)
{
    char buf[160];

    if (ensure_init(env) != 0)
        return;

    (void)clazz;
    if (copy_jstring(env, ua, buf, (int)sizeof(buf)) == 0)
        ys_set_user_agent(buf);
}

JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeInitPjsua(JNIEnv *env,
                                                   jclass clazz,
                                                   jint sip_port)
{
    ys_pjsua_callback cb;

    if (ensure_init(env) != 0)
        return -1;

    (void)env;
    (void)clazz;

    memset(&cb, 0, sizeof(cb));
    cb.ys_register_state    = &ys_cb_register_state;
    cb.ys_call_state        = &ys_cb_call_state;
    cb.ys_call_transfer_state = &ys_cb_call_transfer_state;
    cb.ys_call_answer_sdp   = &ys_cb_call_answer_sdp;
    cb.ys_incoming_call_sdp = &ys_cb_incoming_call_sdp;
    cb.ys_call_reinvite_sdp = &ys_cb_call_reinvite_sdp;
    cb.ys_log               = &ys_cb_log;
    cb.ys_ip_change_progress = &ys_cb_ip_change_progress;

    return (jint)ys_init_pjsua(&cb, (int)sip_port);
}

JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeRegisterAccount(JNIEnv *env,
                                                         jclass clazz,
                                                         jstring server,
                                                         jstring user,
                                                         jstring pass,
                                                         jstring proxy,
                                                         jstring authUser,
                                                         jstring displayName,
                                                         jint expires)
{
    ys_acc_registerinfo ri;

    if (ensure_init(env) != 0)
        return -1;

    (void)clazz;
    memset(&ri, 0, sizeof(ri));

    strcpy(ri.realm, "*");
    if (copy_jstring(env, server, ri.reg_uri, (int)sizeof(ri.reg_uri)) != 0)
        return -1;
    if (copy_jstring(env, user, ri.username, (int)sizeof(ri.username)) != 0)
        return -1;
    if (copy_jstring(env, pass, ri.passwd, (int)sizeof(ri.passwd)) != 0)
        return -1;
    if (proxy != NULL)
        copy_jstring(env, proxy, ri.proxy_uri, (int)sizeof(ri.proxy_uri));
    if (authUser != NULL)
        copy_jstring(env, authUser, ri.auth_username,
                     (int)sizeof(ri.auth_username));
    if (displayName != NULL)
        copy_jstring(env, displayName, ri.registername,
                     (int)sizeof(ri.registername));
    ri.register_expires = (int)expires;

    return (jint)ys_register_account(&ri);
}

JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeUnregisterAccount(JNIEnv *env,
                                                           jclass clazz,
                                                           jint acc_id)
{
    if (ensure_init(env) != 0)
        return -1;

    (void)env;
    (void)clazz;
    return (jint)ys_unregister_account((pjsua_acc_id)acc_id);
}

/* 刷新注册（重发 REGISTER，不删账号、不影响通话）：推送唤醒用 */
JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeReregisterAccount(JNIEnv *env,
                                                           jclass clazz,
                                                           jint acc_id)
{
    if (ensure_init(env) != 0)
        return -1;

    (void)env;
    (void)clazz;
    return (jint)ys_reregister_account((pjsua_acc_id)acc_id);
}

JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeMakeCall(JNIEnv *env,
                                                  jclass clazz,
                                                  jint acc_id,
                                                  jstring dest,
                                                  jstring sdp)
{
    char dst_buf[128];
    char *sdp_buf;
    pjsua_call_id call_id = -1;
    const char *cs;
    jsize sdp_len;
    int rc;

    if (ensure_init(env) != 0)
        return -1;

    (void)clazz;
    if (copy_jstring(env, dest, dst_buf, (int)sizeof(dst_buf)) != 0)
        return -1;

    /* SDP 单条可达数 KB（含 ICE 候选），堆缓冲避免栈溢出 */
    cs = (*env)->GetStringUTFChars(env, sdp, NULL);
    if (!cs)
        return -1;
    sdp_len = (*env)->GetStringUTFLength(env, sdp);
    sdp_buf = (char *)malloc((size_t)sdp_len + 1);
    if (!sdp_buf) {
        (*env)->ReleaseStringUTFChars(env, sdp, cs);
        return -1;
    }
    memcpy(sdp_buf, cs, (size_t)sdp_len);
    sdp_buf[sdp_len] = '\0';
    (*env)->ReleaseStringUTFChars(env, sdp, cs);

    rc = ys_make_call_with_sdp((pjsua_acc_id)acc_id, dst_buf, sdp_buf,
                               &call_id);
    free(sdp_buf);

    return rc == 0 ? (jint)call_id : -1;
}

JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeAnswerCall(JNIEnv *env,
                                                    jclass clazz,
                                                    jint call_id,
                                                    jint code,
                                                    jstring sdp)
{
    char *sdp_buf;
    const char *cs;
    jsize sdp_len;
    int rc;

    if (ensure_init(env) != 0)
        return -1;

    (void)clazz;

    cs = (*env)->GetStringUTFChars(env, sdp, NULL);
    if (!cs)
        return -1;
    sdp_len = (*env)->GetStringUTFLength(env, sdp);
    sdp_buf = (char *)malloc((size_t)sdp_len + 1);
    if (!sdp_buf) {
        (*env)->ReleaseStringUTFChars(env, sdp, cs);
        return -1;
    }
    memcpy(sdp_buf, cs, (size_t)sdp_len);
    sdp_buf[sdp_len] = '\0';
    (*env)->ReleaseStringUTFChars(env, sdp, cs);

    rc = ys_answer_call_with_sdp((pjsua_call_id)call_id,
                                 (unsigned)code, sdp_buf);
    free(sdp_buf);

    return (jint)rc;
}

/* 来电拒接（振铃期 486 Decline；呼出/通话中调用库层返回 -1） */
JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeRejectCall(JNIEnv *env,
                                                    jclass clazz,
                                                    jint call_id)
{
    if (ensure_init(env) != 0)
        return -1;

    (void)env;
    (void)clazz;
    return (jint)ys_reject_call((pjsua_call_id)call_id);
}

/* 盲转（REFER）：dst 纯号码或完整 URI */
JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeXferCall(JNIEnv *env,
                                                  jclass clazz,
                                                  jint call_id,
                                                  jstring dst)
{
    char buf[128];

    if (ensure_init(env) != 0)
        return -1;

    (void)clazz;
    if (copy_jstring(env, dst, buf, (int)sizeof(buf)) != 0)
        return -1;
    return (jint)ys_xfer_call((pjsua_call_id)call_id, buf);
}

/* 咨询转（REFER + Replaces）：call_id 对端 <-> dest_call_id 对端 */
JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeXferReplaces(JNIEnv *env,
                                                      jclass clazz,
                                                      jint call_id,
                                                      jint dest_call_id)
{
    if (ensure_init(env) != 0)
        return -1;

    (void)env;
    (void)clazz;
    return (jint)ys_xfer_replaces_call((pjsua_call_id)call_id,
                                       (pjsua_call_id)dest_call_id);
}

/* REGISTER 附加自定义头（粘性直到清除；推送唤醒双头）。null = 清除 */
JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeSetRegisterHeaders(JNIEnv *env,
                                                            jclass clazz,
                                                            jstring headers)
{
    char buf[512];

    if (ensure_init(env) != 0)
        return -1;

    (void)clazz;
    if (headers == NULL)
        return (jint)ys_set_register_headers(NULL);

    if (copy_jstring(env, headers, buf, (int)sizeof(buf)) != 0)
        return -1;
    return (jint)ys_set_register_headers(buf);
}

/* 下一次呼出 INVITE 附加自定义头（"Name: Value\n" 多行，一次性消费；
 * NULL 仅清除）。缓冲上限对齐库层 g_invite_headers（1024）。 */
JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeSetOutgoingInviteHeaders(JNIEnv *env,
                                                                  jclass clazz,
                                                                  jstring headers)
{
    char buf[1024];

    if (ensure_init(env) != 0)
        return -1;

    (void)clazz;
    if (headers == NULL)
        return (jint)ys_set_outgoing_invite_headers(NULL);

    if (copy_jstring(env, headers, buf, (int)sizeof(buf)) != 0)
        return -1;
    return (jint)ys_set_outgoing_invite_headers(buf);
}

/* 用新 offer SDP 发 re-INVITE（hold/resume/换网）。headers 为附加
 * 自定义头（"Name: Value\n" 多行；NULL = 无），随 re-INVITE 携带 */
JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeReinviteCall(JNIEnv *env,
                                                      jclass clazz,
                                                      jint call_id,
                                                      jstring sdp,
                                                      jstring headers)
{
    char *sdp_buf;
    char hdr_buf[1024];
    const char *cs;
    jsize sdp_len;
    int rc;

    if (ensure_init(env) != 0)
        return -1;

    (void)clazz;

    cs = (*env)->GetStringUTFChars(env, sdp, NULL);
    if (!cs)
        return -1;
    sdp_len = (*env)->GetStringUTFLength(env, sdp);
    sdp_buf = (char *)malloc((size_t)sdp_len + 1);
    if (!sdp_buf) {
        (*env)->ReleaseStringUTFChars(env, sdp, cs);
        return -1;
    }
    memcpy(sdp_buf, cs, (size_t)sdp_len);
    sdp_buf[sdp_len] = '\0';
    (*env)->ReleaseStringUTFChars(env, sdp, cs);

    hdr_buf[0] = '\0';
    if (headers != NULL) {
        copy_jstring(env, headers, hdr_buf, (int)sizeof(hdr_buf));
    }
    rc = ys_reinvite_with_sdp((pjsua_call_id)call_id, sdp_buf,
                              hdr_buf[0] ? hdr_buf : NULL);
    free(sdp_buf);

    return (jint)rc;
}

/* 网络切换恢复：启动库层信令恢复状态机（异步，进度经
 * ys_cb_ip_change_progress 回调，COMPLETED 后引擎走媒体恢复） */
JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeHandleIpChange(JNIEnv *env,
                                                        jclass clazz)
{
    if (ensure_init(env) != 0)
        return -1;

    (void)env;
    (void)clazz;
    return (jint)ys_handle_ip_change();
}

JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeHangup(JNIEnv *env,
                                                jclass clazz,
                                                jint call_id)
{
    if (ensure_init(env) != 0)
        return -1;

    (void)env;
    (void)clazz;
    return (jint)ys_hangup_call((pjsua_call_id)call_id);
}

JNIEXPORT void JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeHangupAll(JNIEnv *env,
                                                   jclass clazz)
{
    if (ensure_init(env) != 0)
        return;

    (void)env;
    (void)clazz;
    ys_hangup_all_calls();
}

JNIEXPORT jint JNICALL
Java_com_yeastar_sipcore_JniBridge_nativeDestroy(JNIEnv *env,
                                                 jclass clazz)
{
    if (ensure_init(env) != 0)
        return -1;

    (void)env;
    (void)clazz;
    return (jint)ys_destroy_pjsua();
}
