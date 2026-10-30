#ifndef YS_PJSUA_APP_H_
#define YS_PJSUA_APP_H_

/*
 * ys_pjsua_app - novoone-app-sip (pjproject 2.17 WebRTC 集成模式)
 *                应用层封装
 *
 * 接口形状与 novoone 旧版封装保持一致，便于多端 (Linux/iOS/Android)
 * 迁移：返回值 0 成功、-1 失败；回调通过
 * ys_pjsua_callback 结构体注入；本头文件不依赖任何 pjsip 头。
 *
 * 分层约定：
 *   - 信令 (SIP 注册/呼叫控制) 由本层封装，各端调用 ys_* 即可；
 *   - 媒体 (SDP 生成/解析) 由各端 WebRTC SDK 负责，通过 SDP 直通
 *     回调交互：呼出前用 WebRTC 生成 offer 交给 ys_make_call_with_sdp；
 *     收到 ys_call_answer_sdp / ys_incoming_call_sdp 后交给 WebRTC
 *     setRemoteDescription。
 *
 * Threading: 回调在 pjsua 内部线程触发，上层自行切换到 UI 线程。
 */

typedef int pjsua_call_id;
typedef int pjsua_acc_id;

#ifdef __cplusplus
#  define YS_BEGIN_DECL    extern "C" {
#  define YS_END_DECL      }
#else
#  define YS_BEGIN_DECL
#  define YS_END_DECL
#endif

/* 呼叫状态（取值对齐 pjsip_inv_state / novoone ys_pjsip_inv_state） */
typedef enum ys_pjsip_inv_state
{
	YS_PJSIP_INV_STATE_NULL,			/* Before INVITE is sent or received */
	YS_PJSIP_INV_STATE_CALLING,			/* After INVITE is sent 			 */
	YS_PJSIP_INV_STATE_INCOMING,		/* After INVITE is received.	    	 */
	YS_PJSIP_INV_STATE_EARLY,			/* After response with To tag.	     */
	YS_PJSIP_INV_STATE_CONNECTING,		/* After 2xx is sent/received.	     */
	YS_PJSIP_INV_STATE_CONFIRMED,		/* After ACK is sent/received.	     */
	YS_PJSIP_INV_STATE_DISCONNECTED,	/* Session is terminated.		     */
} ys_pjsip_inv_state;

/* 注册账号信息（字段名对齐 novoone acc_registerinfo，未列出的
 * 字段（stun/keepalive/srtp 等）在 WebRTC 集成模式下无意义，已略去）
 *
 * 两种服务器架构：
 *   直连架构：reg_uri 填服务器地址即可，proxy_uri 留空，
 *     所有请求直发服务器；
 *   Outbound Proxy 架构（如 novo-one 云平台）：reg_uri 填 Server Host
 *     域（如 "wangjf1:5060"，仅作 SIP 域标识，无需可解析），
 *     proxy_uri 填代理地址（如 "sip.cn-1.dev.novo-one.com:5060"），
 *     REGISTER/INVITE 等所有请求经代理转发（自动生成 Route 头）。
 */
typedef struct ys_acc_registerinfo
{
	char reg_uri[64];			/* 服务器/域 "host[:port]"，如 "10.10.21.101" 或 "wangjf1:5060" */
	char realm[64];				/* 认证域，"*" 表示任意 */
	char username[64];			/* 分机号（SIP 账号 id 与 From user） */
	char auth_username[64];		/* 独立认证用户名，留空 = 用 username */
	char registername[128];		/* 显示名（From display），可留空 */
	char passwd[64];
	char proxy_uri[64];			/* Outbound Proxy "host[:port]"，留空 = 直连 reg_uri */
	int  register_expires;		/* 注册时效秒数，<=0 用库默认 300 */
	int  transport;				/* 0=UDP（默认） 1=TCP 2=TLS，见 ys_set_sip_transport */
	int  dstport;				/* 兼容保留：端口请直接写进 reg_uri/proxy_uri */
} ys_acc_registerinfo;

/*
 * 应用回调集合。不需要的回调置 NULL 即可。
 */
typedef struct ys_pjsua_callback
{
	/* 注册状态变化：status 为 SIP 状态码 (200 成功)，text 为状态文本 */
	void (*ys_register_state)(pjsua_acc_id acc_id, int status,
	                          const char *text);
	/* 呼叫状态变化：state 见 ys_pjsip_inv_state，last_status 为
	 * 最后一个 SIP 响应码 (180/200/486/...) */
	void (*ys_call_state)(pjsua_call_id call_id, int state,
	                      int last_status);
	/* 呼出后收到 200 OK 携带的 answer SDP，
	 * 交给 WebRTC setRemoteDescription */
	void (*ys_call_answer_sdp)(pjsua_call_id call_id, const char *sdp);
	/* 来电 INVITE 携带的 offer SDP：交给 WebRTC setRemoteDescription，
	 * 生成 answer 后调 ys_answer_call_with_sdp 接听。
	 * request_id / caller_id_name 为 INVITE 头 X-Request-ID /
	 * X-Nov-Caller-ID-Name 的值（业务透传：呼叫跟踪/来电身份匹配），
	 * remote_number 为 From URI 的 user 部分（对端号码，如
	 * "66669" <sip:66669@dom> 提取 "66669"）。头/号码缺失时为 NULL；
	 * 与 sdp 同生命周期：仅回调期间有效，上层需要留存必须在回调内拷贝 */
	void (*ys_incoming_call_sdp)(pjsua_call_id call_id, const char *sdp,
	                              const char *request_id,
	                              const char *caller_id_name,
	                              const char *remote_number);
	/* 对端 re-INVITE SDP（hold/resume）：异步应答链——收到后应用生成
	 * answer 并调 ys_answer_call_with_sdp 完成，否则被库层回 488 */
	void (*ys_call_reinvite_sdp)(pjsua_call_id call_id, const char *sdp);
	/* 转接（REFER）进度：status 为 NOTIFY 携带的状态码，is_final 表示
	 * 转接终结（成功 2xx / 失败 3xx-6xx）。final 2xx 后应用应挂断本方 */
	void (*ys_call_transfer_state)(pjsua_call_id call_id, int status,
	                               int is_final);
	/* 日志回调：level 1=ERROR..5=TRACE；msg 以 NUL 结尾 */
	void (*ys_log)(int level, const char *msg);
	/* 网络切换恢复进度（ys_handle_ip_change 触发）：step 取
	 * pjsua_ip_change_op 枚举值（pjsua.h），重要节点：
	 *   PJSUA_IP_CHANGE_OP_COMPLETED = 全部完成（信令恢复链收尾，
	 *   应用此时可发起媒体侧 ICE restart re-INVITE）；
	 * status 为该步结果（0 成功）。尾部追加字段：库与 App 须同
	 * 版本（结构体布局变更，App 侧同步重编） */
	void (*ys_ip_change_progress)(int step, int status);
} ys_pjsua_callback;

YS_BEGIN_DECL

/*
 * 初始化 pjsua（WebRTC 集成模式）并启动：内部完成 pjsua_create /
 * pjsua_init / UDP transport 创建 / pjsua_start。须最先调用。
 *
 * cb       回调集合（内部拷贝，可传栈变量）
 * sip_port 本地 SIP 端口，<=0 用 5060
 * 返回 0 成功，-1 失败
 */
int ys_init_pjsua(const ys_pjsua_callback *cb, int sip_port);

/*
 * 销毁 pjsua（挂断所有通话、注销账号、释放资源）
 */
int ys_destroy_pjsua(void);

/*
 * 设置 SIP 传输层：0=UDP（默认） 1=TCP 2=TLS。
 * 须在 ys_init_pjsua 之前调用；影响 transport 创建与 proxy Route 头
 * 的 ;transport= 参数。TCP/TLS 本地绑定随机端口（对齐常见客户端行为，
 * 云代理沿连接原路回包）。TLS 须库以 PJ_HAS_SSL_SOCK=1 编译交付，
 * 本地固定 5061（服务端 TLS 常规端口；客户端到 proxy 的 5061），
 * 证书校验关闭（对齐旧栈 provisioning verifyCerts=0：服务器 Contact
 * 直连 IP 场景校验必败）。
 */
int ys_set_sip_transport(int transport);

/*
 * 设置统一 User-Agent（REGISTER / INVITE / 应答等所有出站消息的
 * 基础 UA 头）。须在 ys_init_pjsua 之前调用，留空 = pjsua 默认 UA。
 * 值由上层引擎按手机配置拼装传入（格式约定）：
 *   "Mobile/126.9.1-{iOS|Android}-{设备标识}"
 * 前缀 Mobile 为旧栈核心标记不得改动；126.9.1 为自研 SDK 独立定义的
 * 版本序列（与 RN 工程 version / 安卓 versionName 同值，非 app 版本
 * 26.x 推导），服务器按「UA 版本首位 >= 100」识别自研 WebRTC 栈并对
 * 其强制 DTLS。旧栈版本首位为年份两位数，永不 >= 100，新旧判定无歧义。
 */
void ys_set_user_agent(const char *ua);

/*
 * 注册账号。返回 acc_id (>=0)，失败返回 -1。
 */
pjsua_acc_id ys_register_account(const ys_acc_registerinfo *reginfo);

/*
 * 注销并删除账号。
 */
int ys_unregister_account(pjsua_acc_id acc_id);

/*
 * 刷新注册（重发 REGISTER，不删账号、不影响进行中的通话）。
 * 推送唤醒场景：账号已在册（含注册失败待重试）时用本接口让服务器
 * 尽快看到注册并按 X-Nov-Push-Session 双头配对下发 INVITE；避免
 * 删号重建路径强制拆除正在振铃的通话（deleting account while
 * call is active）。
 */
int ys_reregister_account(pjsua_acc_id acc_id);

/*
 * 通知库"本机网络已切换"（WiFi<->蜂窝 / WiFi<->WiFi 本地 IP 变化），
 * 启动信令恢复（上游 pjsua_handle_ip_change 状态机）：
 *   1. 临时开启 keep_inv_after_tsx_timeout（在途请求超时不挂断通话）；
 *   2. 主动 shutdown 全部 TCP/TLS 连接（淘汰半开死链，静默断网场景
 *      被动检测不到的盲区由此覆盖）；
 *   3. 账号：更新 Contact 并经新连接 re-REGISTER；
 *   4. 活跃通话 dialog 换 transport 选择（不发库内 re-INVITE——
 *      WebRTC 模式媒体重协商由应用生成 ICE restart offer 走
 *      ys_reinvite_with_sdp）。
 * listener 不重启（纯 outbound 客户端，listener 无入站用途）。
 * 进度经 ys_ip_change_progress 上报：SHUTDOWN_TP（step 1）完成后即
 * 可发起媒体恢复（新请求自动走新连接），不必等 COMPLETED。
 * 须在网络稳定后（应用侧防抖）调用。
 * 返回 0 表示状态机已启动（非恢复完成），-1 失败。
 */
int ys_handle_ip_change(void);

/*
 * 用应用层 (WebRTC SDK) 生成的 offer SDP 呼出 (ICE gathering 完成
 * 后调用)。User-Agent 使用 ys_set_user_agent 设置的统一 UA。
 *
 * dst_number 纯号码 ("2001") 或完整 URI ("sip:2001@server")
 *            纯号码时自动使用注册账号的域名拼 URI
 * sdp_str    以 "v=0" 开头的完整 SDP 字符串
 * 返回 0 成功，call_id 经 p_call_id 带出
 */
int ys_make_call_with_sdp(pjsua_acc_id acc_id, const char *dst_number,
                          const char *sdp_str, pjsua_call_id *p_call_id);

/*
 * 用 WebRTC 生成的 answer SDP 接听来电（配合 ys_incoming_call_sdp）。
 * code 通常为 200。
 */
int ys_answer_call_with_sdp(pjsua_call_id call_id, unsigned code,
                            const char *sdp_str);

/*
 * 拒接来电（振铃期）：向对端发 486 Decline。
 * 仅对来电未接状态有效（INCOMING/EARLY），通话中调用返回 -1。
 */
int ys_reject_call(pjsua_call_id call_id);

/*
 * 设置下一次呼出 INVITE 附加的自定义头（业务透传，如
 * "X-Request-ID: <uuid>"）。多个头用 '\n' 分隔，每行 "Name: Value"。
 * 一次性消费：仅在紧接着的第一次 ys_make_call_with_sdp 生效并被清除；
 * 传 NULL 仅清除。
 */
int ys_set_outgoing_invite_headers(const char *headers);

/*
 * 设置 REGISTER 附加的自定义头（粘性：随之后的每次注册发出，直到
 * 清除）。推送唤醒场景：X-Nov-Push-Session / X-REQUEST-ID 双头，
 * 服务器按 pushId 配对下发 INVITE；调用方在短延时（约 3s，对齐
 * 旧栈时序）后传 NULL 撤除。每行 "Name: Value"，'\n' 分隔。
 */
int ys_set_register_headers(const char *headers);

/*
 * 用 WebRTC 生成的新 offer SDP 发起 re-INVITE（hold/resume）。
 */
int ys_reinvite_with_sdp(pjsua_call_id call_id, const char *sdp_str);

/*
 * 盲转（SIP REFER）：把 call_id 通话转给 dst_number（纯号码或完整 URI，
 * 拼法同 ys_make_call_with_sdp）。转接进度经 ys_call_transfer_state 上报。
 */
int ys_xfer_call(pjsua_call_id call_id, const char *dst_number);

/*
 * 咨询转（REFER + Replaces）：让 call_id 的对端与 dest_call_id 的对端
 * 建立通话（两路均须为本方活跃通话，典型：A=原始通话，B=已接通的咨询
 * 通话）。转接进度经 ys_call_transfer_state 上报。
 */
int ys_xfer_replaces_call(pjsua_call_id call_id, pjsua_call_id dest_call_id);

/*
 * 挂断指定通话。
 */
int ys_hangup_call(pjsua_call_id call_id);

/*
 * 挂断所有通话。
 */
void ys_hangup_all_calls(void);

/*
 * 泵 SIP 事件（最多等待 max_wait msec）。
 * 仅用于应用自己管理事件循环的场景（如 Linux 单线程 POC）；
 * iOS/Android 使用 pjsua 内部 worker 线程，无需调用。
 */
void ys_handle_events(unsigned max_wait);

YS_END_DECL
#endif /* YS_PJSUA_APP_H_ */
