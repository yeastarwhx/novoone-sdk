/*
 * ys_pjsua_app - novoone-app-sip (pjproject 2.17 WebRTC 集成模式)
 *
 * 应用层封装，接口形状与 novoone 旧版封装保持一致。信令流程全部收敛到这里：
 * 各端 (iOS/Android/Linux) 上层只调 ys_* 接口 + 处理 SDP 直通回调，
 * 不再直接触碰 pjsua C API、缓冲区生命周期和 User-Agent 头构造。
 */

#include "ys_pjsua_app.h"

#include <pjsua-lib/pjsua.h>
#include <pjsua-lib/pjsua_webrtc.h>
#include <string.h>

#define THIS_FILE "ys_pjsua_app"

/* ------------------------------------------------------------------ */
/* 内部状态（单账号 POC；多账号时改为数组）                              */
/* ------------------------------------------------------------------ */

static ys_pjsua_callback g_cb;                 /* 应用回调集合（拷贝） */
static char g_user_agent[128];                 /* 统一 UA，空 = pjsua 默认 */
static int g_sip_transport = 0;                /* 0=UDP 1=TCP */

/* pjsua 持有 acc 配置字符串的指针直到重新注册，必须用稳定存储 */
static char g_acc_id_buf[256];
static char g_acc_reg_buf[128];
static char g_acc_proxy_buf[256];
static char g_acc_user_buf[64];
static char g_acc_pass_buf[64];

/* 非主线程调用 ys_* 接口时的 pjsip 线程注册（每线程一份描述符） */
static thread_local pj_thread_desc g_tls_desc;
static thread_local pj_thread_t *g_tls_thread = NULL;

/* 下一次呼出 INVITE 附加的自定义头（一次性消费；ys_* 调用方约定
 * 主线程串行，无需加锁） */
static char g_invite_headers[1024];

/* REGISTER 附加自定义头（粘性直到清除；推送唤醒双头 X-Nov-Push-Session/
 * X-REQUEST-ID，约 3s 后撤除对齐旧栈时序）。解析入静态节点数组：
 * pjsua_acc_add 会 clone reg_hdr_list，帧上安全 */
static char g_reg_headers[512];
static pjsip_generic_string_hdr g_reg_hdr_nodes[8];
static char g_reg_hdr_names[8][64];
static char g_reg_hdr_values[8][128];

/* 前向声明：解析实现位于 ys_set_outgoing_invite_headers 之后 */
static int build_reg_hdr_list(pjsip_hdr *reg_hdr_list);

static void ys_thread_register(void)
{
	if (!pj_thread_is_registered())
		pj_thread_register("ys_app", g_tls_desc, &g_tls_thread);
}

/* ------------------------------------------------------------------ */
/* pjsua 回调 -> ys_ 回调桥接（pjsua 内部线程）                          */
/* ------------------------------------------------------------------ */

static void bridge_on_log_message(int level, const char *data, int len)
{
	/* SIP 消息 dump（level 4）单条可达数千字节（一个 INVITE 含 SDP），
	 * 缓冲必须装下整条，否则应用侧日志被截断 */
	if (g_cb.ys_log && data && len > 0) {
		char buf[8192];
		int n = len < (int)sizeof(buf) - 1 ? len : (int)sizeof(buf) - 1;
		memcpy(buf, data, n);
		buf[n] = '\0';
		g_cb.ys_log(level, buf);
	}
}

static void bridge_on_reg_state(pjsua_acc_id acc_id)
{
	if (!g_cb.ys_register_state)
		return;

	pjsua_acc_info ai;
	if (pjsua_acc_get_info(acc_id, &ai) != PJ_SUCCESS)
		return;

	char text[80];
	int n = (int)ai.status_text.slen;
	if (n > (int)sizeof(text) - 1)
		n = (int)sizeof(text) - 1;
	if (n < 0)
		n = 0;
	memcpy(text, ai.status_text.ptr, n);
	text[n] = '\0';

	g_cb.ys_register_state(acc_id, (int)ai.status, text);
}

static void bridge_on_call_state(pjsua_call_id call_id, pjsip_event *e)
{
	if (!g_cb.ys_call_state)
		return;

	pjsua_call_info ci;
	if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS)
		return;

	g_cb.ys_call_state(call_id, (int)ci.state, (int)ci.last_status);
	(void)e;
}

/* 网络切换恢复进度：转发 step(pjsua_ip_change_op)/status 两个标量，
 * COMPLETED 步是应用侧媒体恢复（ICE restart re-INVITE）的触发点 */
static void bridge_on_ip_change_progress(pjsua_ip_change_op op,
                                         pj_status_t status,
                                         const pjsua_ip_change_op_info *info)
{
	(void)info;
	if (!g_cb.ys_ip_change_progress)
		return;

	g_cb.ys_ip_change_progress((int)op, (int)status);
}


/* pj_str_t (不保证 NUL 结尾) -> 栈缓冲后交给应用 */
static void dispatch_sdp(pjsua_call_id call_id, const pj_str_t *sdp,
                         void (*fn)(pjsua_call_id, const char *))
{
	if (!fn || !sdp || sdp->slen <= 0 || !sdp->ptr)
		return;

	char buf[8192];
	int n = (int)sdp->slen;
	if (n > (int)sizeof(buf) - 1) {
		/* 截断必须显式告警：offer 含完整 ICE 候选可超 8KB，尾部
		 * candidate 丢失会直接断媒且极难排障 */
		PJ_LOG(2, (THIS_FILE,
		           "dispatch_sdp: SDP %d bytes exceeds buffer %d, TRUNCATED",
		           n, (int)sizeof(buf) - 1));
		n = (int)sizeof(buf) - 1;
	}
	memcpy(buf, sdp->ptr, n);
	buf[n] = '\0';

	fn(call_id, buf);
}

static void bridge_on_incoming_call_sdp(pjsua_call_id call_id,
                                        const pj_str_t *remote_sdp,
                                        const pj_str_t *request_id,
                                        const pj_str_t *caller_id_name,
                                        const pj_str_t *remote_number)
{
	/* pj_str_t (不保证 NUL 结尾) -> 栈缓冲后一起交给应用；头与 SDP
	 * 同生命周期契约：仅回调期间有效，上层需留存必须在回调内拷贝 */
	char sdp_buf[8192];
	char req_buf[128];
	char cid_buf[256];
	char num_buf[64];
	const char *req = NULL;
	const char *cid = NULL;
	const char *num = NULL;
	int n;

	if (!g_cb.ys_incoming_call_sdp)
		return;

	sdp_buf[0] = '\0';
	if (remote_sdp && remote_sdp->slen > 0 && remote_sdp->ptr) {
		n = (int)remote_sdp->slen;
		if (n > (int)sizeof(sdp_buf) - 1) {
			PJ_LOG(2, (THIS_FILE,
			           "incoming SDP %d bytes exceeds buffer %d, TRUNCATED",
			           n, (int)sizeof(sdp_buf) - 1));
			n = (int)sizeof(sdp_buf) - 1;
		}
		memcpy(sdp_buf, remote_sdp->ptr, n);
		sdp_buf[n] = '\0';
	}
	if (request_id && request_id->slen > 0 && request_id->ptr) {
		n = (int)request_id->slen;
		if (n > (int)sizeof(req_buf) - 1)
			n = (int)sizeof(req_buf) - 1;
		memcpy(req_buf, request_id->ptr, n);
		req_buf[n] = '\0';
		req = req_buf;
	}
	if (caller_id_name && caller_id_name->slen > 0 && caller_id_name->ptr) {
		n = (int)caller_id_name->slen;
		if (n > (int)sizeof(cid_buf) - 1)
			n = (int)sizeof(cid_buf) - 1;
		memcpy(cid_buf, caller_id_name->ptr, n);
		cid_buf[n] = '\0';
		cid = cid_buf;
	}
	if (remote_number && remote_number->slen > 0 && remote_number->ptr) {
		n = (int)remote_number->slen;
		if (n > (int)sizeof(num_buf) - 1)
			n = (int)sizeof(num_buf) - 1;
		memcpy(num_buf, remote_number->ptr, n);
		num_buf[n] = '\0';
		num = num_buf;
	}

	g_cb.ys_incoming_call_sdp(call_id, sdp_buf, req, cid, num);
}

/* on_incoming_call 桥接：注册它只是为了阻止 pjsua 把未应答的来电按
 * 480 拒绝（pjsua_call.c process_incoming_call：应用未挂 on_incoming_call
 * 时对来电立即回 480 Temporarily Unavailable）。WebRTC 模式下真正的
 * 来电处理在更早触发的 on_incoming_call_sdp（verify_request 阶段已把
 * offer 交给应用），200 应答由应用完成 WebRTC 协商后异步调
 * ys_answer_call_with_sdp 发出，这里不做任何应答动作。 */
static void bridge_on_incoming_call(pjsua_acc_id acc_id,
                                    pjsua_call_id call_id,
                                    pjsip_rx_data *rdata)
{
	PJ_LOG(4, (THIS_FILE, "incoming call %d (acc %d, WebRTC async answer)",
	           call_id, acc_id));
	/* 180 Ringing：pjsua 不自动应答振铃（上游设计由应用显式发），
	 * 不发则对端/服务器不知被叫振铃——实测 8 秒即被 CANCEL（487）。
	 * 180 无 SDP 可立即发出；200 仍由应用完成 WebRTC 协商后异步调
	 * ys_answer_call_with_sdp。EARLY 状态同时驱动上层视图
	 * IncomingTrying -> IncomingRinging（弹屏/可接听条件）。 */
	pjsua_call_answer(call_id, 180, NULL, NULL);
	(void)rdata;
}

static void bridge_on_call_answer_sdp(pjsua_call_id call_id,
                                      const pj_str_t *remote_sdp)
{
	dispatch_sdp(call_id, remote_sdp, g_cb.ys_call_answer_sdp);
}

static void bridge_on_call_reinvite_sdp(pjsua_call_id call_id,
                                        const pj_str_t *remote_sdp)
{
	dispatch_sdp(call_id, remote_sdp, g_cb.ys_call_reinvite_sdp);
}

static void bridge_on_call_transfer_status(pjsua_call_id call_id,
                                           int st_code,
                                           const pj_str_t *st_text,
                                           pj_bool_t final,
                                           pj_bool_t *p_cont)
{
	if (!g_cb.ys_call_transfer_state)
		return;

	g_cb.ys_call_transfer_state(call_id, st_code, final ? 1 : 0);
	(void)st_text;
	/* 转接终结（成功/失败）后不再继续订阅 NOTIFY 进度 */
	if (p_cont && final)
		*p_cont = PJ_FALSE;
}

/* re-INVITE 的实际处理在 on_call_reinvite_sdp（WebRTC 异步应答）里做，
 * 这里必须挂一个非空回调仅仅是为了让库层注册 inv 会话的 on_rx_reinvite
 * （pjsua_call_subsys_init 只在应用挂了 on_call_rx_reinvite 时注册它）。
 * 没有它，re-INVITE 的异步应答标记（rx_reinv_async）不会被 inv 层读取，
 * re-INVITE 会被库层直接拒绝 488 "No SDP answer"。 */
static void bridge_on_call_rx_reinvite(pjsua_call_id call_id,
                                       const pjmedia_sdp_session *offer,
                                       pjsip_rx_data *rdata,
                                       void *reserved,
                                       pj_bool_t *async,
                                       pjsip_status_code *code,
                                       pjsua_call_setting *opt)
{
	PJ_UNUSED_ARG(offer);
	PJ_UNUSED_ARG(rdata);
	/* async/code 交回默认值（不在此应答）：流程继续走库层的
	 * WebRTC 分支 -> on_call_reinvite_sdp -> 应用异步
	 * ys_answer_call_with_sdp() */
	if (async)
		*async = PJ_FALSE;
	if (code)
		*code = PJSIP_SC_OK;
	PJ_LOG(4, (THIS_FILE, "re-INVITE on call %d (async WebRTC answer)",
	           call_id));
	(void)reserved;
	(void)opt;
}

/* ------------------------------------------------------------------ */
/* 生命周期                                                             */
/* ------------------------------------------------------------------ */

int ys_init_pjsua(const ys_pjsua_callback *cb, int sip_port)
{
	pj_status_t status;

	if (cb)
		g_cb = *cb;
	else
		memset(&g_cb, 0, sizeof(g_cb));

	ys_thread_register();

	status = pjsua_create();
	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_init_pjsua: pjsua_create failed: %d", status));
		return -1;
	}

	pjsua_config cfg;
	pjsua_config_default(&cfg);
	if (g_user_agent[0])
		cfg.user_agent = pj_str(g_user_agent);
	cfg.cb.on_reg_state = &bridge_on_reg_state;
	cfg.cb.on_call_state = &bridge_on_call_state;
	cfg.cb.on_call_transfer_status = &bridge_on_call_transfer_status;
	cfg.cb.on_incoming_call = &bridge_on_incoming_call;
	cfg.cb.on_incoming_call_sdp = &bridge_on_incoming_call_sdp;
	cfg.cb.on_call_answer_sdp = &bridge_on_call_answer_sdp;
	cfg.cb.on_call_reinvite_sdp = &bridge_on_call_reinvite_sdp;
	cfg.cb.on_call_rx_reinvite = &bridge_on_call_rx_reinvite;
	cfg.cb.on_log_message = &bridge_on_log_message;
	cfg.cb.on_ip_change_progress = &bridge_on_ip_change_progress;
	cfg.max_calls = 4;

	pjsua_logging_config log_cfg;
	pjsua_logging_config_default(&log_cfg);
	/* 日志级别 4：SIP 报文 dump（TX/RX）与状态机保留，5 级最细轨迹
	 * 去掉（量约降一半，排障主力信息不受影响）；应用侧 SDK 日志文件
	 * 同按 4 过滤。应用挂了 ys_log 回调时日志走回调（避免 console
	 * 双打）；未挂回调则保留 console 输出便于排障 */
	log_cfg.level = 4;
	log_cfg.console_level = g_cb.ys_log ? 0 : 3;

	pjsua_media_config media_cfg;
	pjsua_media_config_default(&media_cfg);

	status = pjsua_init(&cfg, &log_cfg, &media_cfg);
	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_init_pjsua: pjsua_init failed: %d", status));
		return -1;
	}

	pjsua_transport_config tcfg;
	pjsua_transport_config_default(&tcfg);

	pjsua_transport_id tid;
	if (g_sip_transport == 0) {
		tcfg.port = sip_port > 0 ? sip_port : 5060;
		status = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &tcfg, &tid);
	} else if (g_sip_transport == 1) {
		/* TCP：本地绑随机端口（port=0）。云代理沿连接原路回包，
		 * 对齐参考客户端（Contact: ...:50328;transport=tcp）的行为 */
		tcfg.port = 0;
		status = pjsua_transport_create(PJSIP_TRANSPORT_TCP, &tcfg, &tid);
	} else {
		/* TLS：同样本地随机端口（服务端 TLS 端口 5061 由 proxy URI
		 * 携带）。pjsip 客户端默认不校验服务端证书（verify_server=
		 * FALSE，对齐旧栈 provisioning verifyCerts=0——服务器
		 * Contact 直连 IP 场景证书校验必败）；无客户端证书要求 */
		tcfg.port = 0;
		status = pjsua_transport_create(PJSIP_TRANSPORT_TLS, &tcfg, &tid);
	}
	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_init_pjsua: %s transport failed: %d",
		           g_sip_transport == 2 ? "TLS" :
		           (g_sip_transport ? "TCP" : "UDP"), status));
		return -1;
	}


	status = pjsua_start();
	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_init_pjsua: pjsua_start failed: %d", status));
		return -1;
	}

	PJ_LOG(3, (THIS_FILE, "ys_init_pjsua: ready (port=%d)", tcfg.port));
	return 0;
}

int ys_destroy_pjsua(void)
{
	ys_thread_register();
	pjsua_destroy();
	memset(&g_cb, 0, sizeof(g_cb));
	return 0;
}

int ys_set_sip_transport(int transport)
{
	if (transport < 0 || transport > 2)
		return -1;
#if !defined(PJ_HAS_SSL_SOCK) || !PJ_HAS_SSL_SOCK
	/* 注意：本函数在 ys_init_pjsua 之前调用（pjlib 未初始化、线程未
	 * 注册），此处禁止任何 pjlib 调用——包括 PJ_LOG（实测会触发
	 * pj_thread_this 断言直接 abort，2026-09-15 启动崩溃根因） */
	if (transport == 2)
		return -1;
#endif
	g_sip_transport = transport;
	return 0;
}

void ys_set_user_agent(const char *ua)
{
	if (ua && ua[0])
		snprintf(g_user_agent, sizeof(g_user_agent), "%s", ua);
	else
		g_user_agent[0] = '\0';
}

/* ------------------------------------------------------------------ */
/* 账号                                                                */
/* ------------------------------------------------------------------ */

pjsua_acc_id ys_register_account(const ys_acc_registerinfo *reginfo)
{
	if (!reginfo || !reginfo->reg_uri[0] || !reginfo->username[0]) {
		PJ_LOG(1, (THIS_FILE, "ys_register_account: invalid reginfo"));
		return -1;
	}

	ys_thread_register();

	/* reg_uri / proxy_uri 自带 "host[:port]" 形式（端口写在串里，
	 * dstport 仅兼容保留）。填入稳定存储：pjsua 持有指针直到下次注册。
	 * 账号 id 的 user 部分恒为分机号（username）；认证用户名独立
	 * （auth_username，缺省同 username）；显示名拼进 id 的引号段 */
	if (reginfo->registername[0])
		snprintf(g_acc_id_buf, sizeof(g_acc_id_buf), "\"%s\" <sip:%s@%s>",
		         reginfo->registername, reginfo->username, reginfo->reg_uri);
	else
		snprintf(g_acc_id_buf, sizeof(g_acc_id_buf), "sip:%s@%s",
		         reginfo->username, reginfo->reg_uri);
	snprintf(g_acc_reg_buf, sizeof(g_acc_reg_buf), "sip:%s", reginfo->reg_uri);
	/* Route 的 ;transport= 参数：0=udp 1=tcp 2=tls */
	const char *tsport = g_sip_transport == 2 ? "tls" :
	                     (g_sip_transport ? "tcp" : "udp");
	if (reginfo->proxy_uri[0]) {
		/* Outbound Proxy 架构：registrar 显示 Server Host 域（仅标识），
		 * 实际所有请求经 proxy 转发（pjsua 自动生成 Route 头，
		 * 参考包 Route: <sip:proxy;transport=tcp;lr>） */
		snprintf(g_acc_proxy_buf, sizeof(g_acc_proxy_buf), "sip:%s;transport=%s;lr",
		         reginfo->proxy_uri, tsport);
	} else {
		/* 直连架构：无独立代理，请求直达 registrar */
		snprintf(g_acc_proxy_buf, sizeof(g_acc_proxy_buf), "sip:%s;transport=%s",
		         reginfo->reg_uri, tsport);
	}
	snprintf(g_acc_user_buf, sizeof(g_acc_user_buf), "%s",
	         reginfo->auth_username[0] ? reginfo->auth_username
	                                   : reginfo->username);
	snprintf(g_acc_pass_buf, sizeof(g_acc_pass_buf), "%s", reginfo->passwd);

	pjsua_acc_config acc;
	pjsua_acc_config_default(&acc);
	acc.id = pj_str(g_acc_id_buf);
	acc.reg_uri = pj_str(g_acc_reg_buf);
	acc.proxy_cnt = 1;
	acc.proxy[0] = pj_str(g_acc_proxy_buf);
	if (reginfo->register_expires > 0)
		acc.reg_timeout = (unsigned)reginfo->register_expires;
	/* 注册失败自动重试（默认 0 不重试）：进程被推送拉起的冷启动窗口
	 * DNS/网络可能未就绪（实测 502 PJ_ERESOLVE），不重试则账号停在
	 * "在册未注册"直到下个外部事件。10s 间隔与来电推送窗口匹配 */
	acc.reg_retry_interval = 10;
	/* 网络切换恢复（ys_handle_ip_change）时上游对活跃通话的处理标志：
	 * 0 = 只换 dialog transport 不发库内 re-INVITE。WebRTC 模式下库内
	 * re-INVITE 走 pjmedia 生成 SDP（media_channel_create_sdp，本模式
	 * med_endpt=NULL 必失败），媒体重协商必须由应用侧 WebRTC ICE
	 * restart offer 经 ys_reinvite_with_sdp 发起，故恒置 0 */
	acc.ip_change_cfg.reinvite_flags = 0;
	/* P-hint: background 仅由推送唤醒路径经 ys_set_register_headers
	 * 粘性注入（普通注册不带）：服务器按该头识别"推送唤醒的后台注册"
	 * 并把 pending 呼入 INVITE 下发到这条注册（旧栈 26.9.12 TCP 实测
	 * 2026-09-16：唤醒 re-REGISTER 带此头后 INVITE 沿注册连接到达；
	 * 缺此头则 TCP 场景 INVITE 不下发）。此前"旧栈不带此头"的结论
	 * 误自前台正常注册的对比，已更正 */

	/* 推送唤醒双头等自定义 REGISTER 头（粘性直到 ys_set_register_headers
	 * 清除；pjsua_acc_add clone reg_hdr_list，静态节点安全） */
	if (g_reg_headers[0]) {
		int n = build_reg_hdr_list(&acc.reg_hdr_list);
		PJ_LOG(4, (THIS_FILE, "ys_register_account: %d custom REGISTER"
		           " header(s) attached", n));
	}
	acc.cred_count = 1;
	acc.cred_info[0].realm =
		pj_str((char *)(reginfo->realm[0] ? reginfo->realm : "*"));
	acc.cred_info[0].scheme = pj_str((char *)"digest");
	acc.cred_info[0].username = pj_str(g_acc_user_buf);
	acc.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
	acc.cred_info[0].data = pj_str(g_acc_pass_buf);

	pjsua_acc_id acc_id = PJSUA_INVALID_ID;
	pj_status_t status = pjsua_acc_add(&acc, PJ_TRUE, &acc_id);
	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_register_account: acc_add failed: %d", status));
		return -1;
	}

	PJ_LOG(3, (THIS_FILE, "ys_register_account: %s -> registering",
	           g_acc_id_buf));
	return acc_id;
}

int ys_unregister_account(pjsua_acc_id acc_id)
{
	ys_thread_register();
	if (acc_id < 0 || pjsua_acc_is_valid(acc_id) == PJ_FALSE)
		return -1;
	return pjsua_acc_del(acc_id) == PJ_SUCCESS ? 0 : -1;
}

int ys_reregister_account(pjsua_acc_id acc_id)
{
	ys_thread_register();
	if (acc_id < 0 || pjsua_acc_is_valid(acc_id) == PJ_FALSE)
		return -1;

	/* 重发前同步最新粘性头：acc 的 reg_hdr_list 是注册时的快照
	 * （pjsua_acc_add clone），注册后 ys_set_register_headers 设置
	 * 的推送双头不在其中。经 get_config/modify 更新头列表
	 * （disable_reg_on_modify 避免多一次 un-REGISTER 往返），随后
	 * set_registration 按新头组包重发。build_reg_hdr_list 挂的是
	 * 静态节点，modify 内部 clone 到 acc pool，生命周期安全 */
	if (g_reg_headers[0]) {
		pj_pool_t *pool = pjsua_pool_create("ysrereg", 512, 512);
		if (pool) {
			pjsua_acc_config cfg;
			pjsua_acc_config_default(&cfg);
			if (pjsua_acc_get_config(acc_id, pool, &cfg) == PJ_SUCCESS) {
				pj_list_init(&cfg.reg_hdr_list); /* 丢弃旧头快照，防重复 */
				build_reg_hdr_list(&cfg.reg_hdr_list);
				cfg.disable_reg_on_modify = PJ_TRUE;
				pjsua_acc_modify(acc_id, &cfg);
			}
			pj_pool_release(pool);
		}
	}

	pj_status_t status = pjsua_acc_set_registration(acc_id, PJ_TRUE);
	if (status != PJ_SUCCESS) {
		PJ_LOG(2, (THIS_FILE, "ys_reregister_account: acc %d failed: %d",
		           acc_id, status));
		return -1;
	}
	PJ_LOG(3, (THIS_FILE, "ys_reregister_account: acc %d -> re-REGISTER",
	           acc_id));
	return 0;
}

int ys_handle_ip_change(void)
{
	ys_thread_register();

	/* shutdown_transport=TRUE（默认）：主动 shutdown 全部 TCP/TLS 连接
	 * ——半开死链的唯一可靠淘汰手段，静默断网被动检测不到。
	 * restart_listener=FALSE（改默认，2026-09-30 P0 实测）：本工程为
	 * 纯 outbound 客户端（proxy 架构，所有连接主动出站，listener 无
	 * 入站用途），而上游重启 listener 在网络切换瞬间 bind 新接口存在
	 * 竞态失败且不重试——一旦失败 TCP factory 永久丢失，后续所有
	 * 请求 PJSIP_EUNSUPTRANSPORT（真机实测）。listener 保持原绑定，
	 * 出站连接不受影响。异步状态机，进度经 bridge_on_ip_change_progress
	 * 上报，应用在 SHUTDOWN_TP 步完成后即可走媒体恢复 */
	pjsua_ip_change_param param;
	pjsua_ip_change_param_default(&param);
	param.restart_listener = PJ_FALSE;

	pj_status_t status = pjsua_handle_ip_change(&param);
	if (status != PJ_SUCCESS) {
		PJ_LOG(2, (THIS_FILE, "ys_handle_ip_change: failed: %d", status));
		return -1;
	}
	PJ_LOG(3, (THIS_FILE, "ys_handle_ip_change: recovery started"));
	return 0;
}

/* ------------------------------------------------------------------ */
/* 呼叫（WebRTC SDP 直通）                                              */
/* ------------------------------------------------------------------ */

/* 参考 novoone：纯号码 + 账号域名 -> "sip:number@domain" */
static int build_dst_url(pjsua_acc_id acc_id, const char *dst_number,
                         char *dst_url, int url_size)
{
	if (strncmp(dst_number, "sip:", 4) == 0) {
		snprintf(dst_url, url_size, "%s", dst_number);
		return 0;
	}

	pjsua_acc_info info;
	if (pjsua_acc_get_info(acc_id, &info) != PJ_SUCCESS)
		return -1;

	char acc_uri[256];
	snprintf(acc_uri, sizeof(acc_uri), "%.*s",
	         (int)info.acc_uri.slen, info.acc_uri.ptr);

	const char *at = strchr(acc_uri, '@');
	if (!at)
		return -1;

	snprintf(dst_url, url_size, "sip:%s%s", dst_number, at);
	/* 去掉可能的 '>'（acc_uri 可能带尖括号形式） */
	char *gt = strrchr(dst_url, '>');
	if (gt)
		*gt = '\0';
	return 0;
}

/* 解析 g_invite_headers 的 "Name: Value" 行（'\n' 分隔）构造 msg_data。
 * 头节点与 name/value 用静态存储：pjsua_call_make_call_with_sdp_str
 * 内部（pjsua_process_msg_data）会把头 clone 进消息 pool，调用返回后
 * 本列表即失效可复用 */
static int build_invite_msg_data(pjsua_msg_data *msg_data)
{
	static pjsip_generic_string_hdr hdrs[8];
	static char name_buf[8][64];
	static char value_buf[8][128];
	char *p = g_invite_headers;
	int count = 0;

	pjsua_msg_data_init(msg_data);

	while (*p && count < 8) {
		char *line_end = strchr(p, '\n');
		char *colon = strchr(p, ':');
		char *name_end;
		char *value_start;
		char *value_end;
		int name_len;
		int value_len;

		if (!colon || (line_end && colon > line_end)) {
			/* 无冒号的行跳过 */
			if (!line_end)
				break;
			p = line_end + 1;
			continue;
		}

		name_end = colon;
		while (name_end > p && name_end[-1] == ' ')
			name_end--;
		name_len = (int)(name_end - p);
		if (name_len <= 0 || name_len >= (int)sizeof(name_buf[0])) {
			if (!line_end)
				break;
			p = line_end + 1;
			continue;
		}

		value_start = colon + 1;
		while (*value_start == ' ')
			value_start++;
		value_end = line_end ? line_end : p + strlen(p);
		while (value_end > value_start && value_end[-1] == '\r')
			value_end--;
		value_len = (int)(value_end - value_start);
		if (value_len >= (int)sizeof(value_buf[0]))
			value_len = (int)sizeof(value_buf[0]) - 1;

		memcpy(name_buf[count], p, name_len);
		name_buf[count][name_len] = '\0';
		if (value_len > 0)
			memcpy(value_buf[count], value_start, value_len);
		value_buf[count][value_len] = '\0';

		{
			pj_str_t hname = pj_str(name_buf[count]);
			pj_str_t hvalue = pj_str(value_buf[count]);
			pjsip_generic_string_hdr_init2(&hdrs[count], &hname, &hvalue);
			pj_list_push_back(&msg_data->hdr_list, &hdrs[count]);
			count++;
		}

		if (!line_end)
			break;
		p = line_end + 1;
	}

	return count;
}

int ys_set_outgoing_invite_headers(const char *headers)
{
	if (headers && headers[0])
		snprintf(g_invite_headers, sizeof(g_invite_headers), "%s", headers);
	else
		g_invite_headers[0] = '\0';
	return 0;
}

/* 解析 "Name: Value" 行到静态头节点数组（规则与 g_invite_headers 一致：
 * 无冒号行跳过、名/值去首尾空格、最多 8 个） */
static int build_reg_hdr_list(pjsip_hdr *reg_hdr_list)
{
	char *p = g_reg_headers;
	int count = 0;
	while (*p && count < 8) {
		char *line_end = strchr(p, '\n');
		char *colon = strchr(p, ':');
		char *name_end;
		char *value_start;
		char *value_end;
		int name_len;
		int value_len;

		if (!colon || (line_end && colon > line_end)) {
			if (!line_end)
				break;
			p = line_end + 1;
			continue;
		}

		name_end = colon;
		while (name_end > p && name_end[-1] == ' ')
			name_end--;
		name_len = (int)(name_end - p);
		if (name_len <= 0 || name_len >= (int)sizeof(g_reg_hdr_names[0])) {
			if (!line_end)
				break;
			p = line_end + 1;
			continue;
		}

		value_start = colon + 1;
		while (*value_start == ' ')
			value_start++;
		value_end = line_end ? line_end : p + strlen(p);
		while (value_end > value_start && value_end[-1] == '\r')
			value_end--;
		value_len = (int)(value_end - value_start);
		if (value_len >= (int)sizeof(g_reg_hdr_values[0]))
			value_len = (int)sizeof(g_reg_hdr_values[0]) - 1;

		memcpy(g_reg_hdr_names[count], p, name_len);
		g_reg_hdr_names[count][name_len] = '\0';
		if (value_len > 0)
			memcpy(g_reg_hdr_values[count], value_start, value_len);
		g_reg_hdr_values[count][value_len] = '\0';

		{
			pj_str_t hname = pj_str(g_reg_hdr_names[count]);
			pj_str_t hvalue = pj_str(g_reg_hdr_values[count]);
			pjsip_generic_string_hdr_init2(&g_reg_hdr_nodes[count],
			                               &hname, &hvalue);
			pj_list_push_back(reg_hdr_list, &g_reg_hdr_nodes[count]);
			count++;
		}

		if (!line_end)
			break;
		p = line_end + 1;
	}
	return count;
}

int ys_set_register_headers(const char *headers)
{
	if (headers && headers[0])
		snprintf(g_reg_headers, sizeof(g_reg_headers), "%s", headers);
	else
		g_reg_headers[0] = '\0';
	return 0;
}

int ys_make_call_with_sdp(pjsua_acc_id acc_id, const char *dst_number,
                          const char *sdp_str, pjsua_call_id *p_call_id)
{
	if (!dst_number || !sdp_str || !p_call_id) {
		PJ_LOG(1, (THIS_FILE, "ys_make_call_with_sdp: invalid parameters"));
		return -1;
	}

	ys_thread_register();

	if (acc_id < 0 || pjsua_acc_is_valid(acc_id) == PJ_FALSE) {
		PJ_LOG(1, (THIS_FILE, "ys_make_call_with_sdp: invalid account %d", acc_id));
		return -1;
	}

	char dst_url[256];
	if (build_dst_url(acc_id, dst_number, dst_url, sizeof(dst_url)) != 0 ||
	    pjsua_verify_url(dst_url) != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_make_call_with_sdp: invalid dst: %s", dst_number));
		return -1;
	}

	PJ_LOG(3, (THIS_FILE, "ys_make_call_with_sdp: %s (SDP %d bytes)",
	           dst_url, (int)strlen(sdp_str)));

	pj_str_t dst = pj_str(dst_url);
	/* sdp_str 为 const，库层接口历史签名未标 const，内容只读 */
	pj_str_t offer = pj_str((char *)sdp_str);

	/* 应用预置的呼出自定义头（如 X-Request-ID），一次性消费 */
	pjsua_msg_data msg_data;
	pjsua_msg_data *p_msg_data = NULL;
	if (g_invite_headers[0] && build_invite_msg_data(&msg_data) > 0) {
		p_msg_data = &msg_data;
		PJ_LOG(4, (THIS_FILE, "ys_make_call_with_sdp: %d custom header(s)"
		           " attached", (int)pj_list_size(&msg_data.hdr_list)));
	}

	pj_status_t status = pjsua_call_make_call_with_sdp_str(
		acc_id, &dst, &offer, NULL, NULL, p_msg_data, p_call_id);

	g_invite_headers[0] = '\0';

	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_make_call_with_sdp: failed: %d", status));
		return -1;
	}
	return 0;
}

int ys_answer_call_with_sdp(pjsua_call_id call_id, unsigned code,
                            const char *sdp_str)
{
	if (!sdp_str) {
		PJ_LOG(1, (THIS_FILE, "ys_answer_call_with_sdp: invalid parameters"));
		return -1;
	}

	ys_thread_register();

	pj_str_t sdp = pj_str((char *)sdp_str);
	pj_status_t status = pjsua_call_answer_with_sdp_str(
		call_id, code, &sdp, NULL, NULL);
	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_answer_call_with_sdp: failed: %d", status));
		return -1;
	}
	return 0;
}

int ys_reinvite_with_sdp(pjsua_call_id call_id, const char *sdp_str)
{
	if (!sdp_str) {
		PJ_LOG(1, (THIS_FILE, "ys_reinvite_with_sdp: invalid parameters"));
		return -1;
	}

	ys_thread_register();

	pj_str_t sdp = pj_str((char *)sdp_str);
	pj_status_t status = pjsua_call_reinvite_with_sdp_str(
		call_id, &sdp, NULL, NULL);
	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_reinvite_with_sdp: failed: %d", status));
		return -1;
	}
	return 0;
}

int ys_hangup_call(pjsua_call_id call_id)
{
	ys_thread_register();
	return pjsua_call_hangup(call_id, 0, NULL, NULL) == PJ_SUCCESS ? 0 : -1;
}

int ys_xfer_call(pjsua_call_id call_id, const char *dst_number)
{
	if (!dst_number || !dst_number[0]) {
		PJ_LOG(1, (THIS_FILE, "ys_xfer_call: invalid dst"));
		return -1;
	}

	ys_thread_register();

	if (pjsua_call_is_active(call_id) == PJ_FALSE) {
		PJ_LOG(1, (THIS_FILE, "ys_xfer_call: call %d not active", call_id));
		return -1;
	}

	/* REFER 目标 URI：纯号码拼当前账号域（同 build_dst_url 语义），
	 * 须取默认账号（本封装单账号模型） */
	char dest[256];
	pjsua_acc_id acc_id = pjsua_acc_get_default();
	if (acc_id == PJSUA_INVALID_ID) {
		PJ_LOG(1, (THIS_FILE, "ys_xfer_call: no default account"));
		return -1;
	}
	if (build_dst_url(acc_id, dst_number, dest, sizeof(dest)) != 0) {
		PJ_LOG(1, (THIS_FILE, "ys_xfer_call: bad dst: %s", dst_number));
		return -1;
	}

	pj_str_t dst = pj_str(dest);
	pj_status_t status = pjsua_call_xfer(call_id, &dst, NULL);
	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_xfer_call: failed: %d", status));
		return -1;
	}
	PJ_LOG(3, (THIS_FILE, "ys_xfer_call: REFER sent (call %d -> %s)",
	           call_id, dest));
	return 0;
}

int ys_xfer_replaces_call(pjsua_call_id call_id, pjsua_call_id dest_call_id)
{
	ys_thread_register();

	if (pjsua_call_is_active(call_id) == PJ_FALSE ||
	    pjsua_call_is_active(dest_call_id) == PJ_FALSE) {
		PJ_LOG(1, (THIS_FILE, "ys_xfer_replaces_call: call %d/%d not active",
		           call_id, dest_call_id));
		return -1;
	}

	/* 0 = 默认要求对端支持 Replaces（服务器/SIP 终端常规支持） */
	pj_status_t status = pjsua_call_xfer_replaces(call_id, dest_call_id,
	                                              0, NULL);
	if (status != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_xfer_replaces_call: failed: %d", status));
		return -1;
	}
	PJ_LOG(3, (THIS_FILE, "ys_xfer_replaces_call: REFER+Replaces sent "
	           "(call %d peer -> call %d peer)", call_id, dest_call_id));
	return 0;
}

int ys_reject_call(pjsua_call_id call_id)
{
	pjsua_call_info ci;

	ys_thread_register();

	if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS) {
		PJ_LOG(1, (THIS_FILE, "ys_reject_call: invalid call %d", call_id));
		return -1;
	}

	/* 仅来电未接状态可拒接（UAS 且 INCOMING/EARLY）；呼出中/通话中
	 * 调用属误用，拒绝以防把回铃误转 486 */
	if (ci.role != PJSIP_ROLE_UAS ||
	    (ci.state != PJSIP_INV_STATE_INCOMING &&
	     ci.state != PJSIP_INV_STATE_EARLY)) {
		PJ_LOG(2, (THIS_FILE, "ys_reject_call: call %d not rejectable"
		           " (role=%d state=%d)", call_id,
		           (int)ci.role, (int)ci.state));
		return -1;
	}

	/* 486 Busy Here（pjsua_call_hangup 对 UAS 未接来电以传入码发终结
	 * 响应；UAS 未接默认推导同为 DECLINE 语义档，显式传码明确为忙线） */
	return pjsua_call_hangup(call_id, PJSIP_SC_BUSY_HERE, NULL, NULL)
	       == PJ_SUCCESS ? 0 : -1;
}

void ys_hangup_all_calls(void)
{
	ys_thread_register();
	pjsua_call_hangup_all();
}

void ys_handle_events(unsigned max_wait)
{
	ys_thread_register();
	pjsua_handle_events(max_wait);
}
