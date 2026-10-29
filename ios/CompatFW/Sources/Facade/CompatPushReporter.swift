//
//  CompatPushReporter.swift
//  CompatFW
//
//  Acrobits Push Token Reporter 的 compat 实现:App 经账户 XML 下发
//  pushTokenReporter* 节点(占位符模板),SDK 在 token 变化/账户就绪/
//  注册成功时自动拼请求上报——线上此职责由 Acrobits SDK 内建,App 源码
//  按此契约接入,compat 必须承担(dev-webrtc 缺口 #1)。
//
//  报文契约对齐 E3 实测(dev-webrtc App 层 PushReporter.swift 同源):
//  token=base64(Data)、selector=40HEX:8HEX 装机一次生成、POST url
//  2xx 即成功;4xx 不重试,网络/5xx 退避 1s/4s/16s(3 次后等下个触发源)。
//
//  线程纪律:状态仅主线程读写(URLSession 回调切主线程),对齐
//  CompatAdapter 主线程纪律。
//

import Foundation
import Security

private func compatLog(_ message: String) {
    NSLog("[compat] %@", message)
    // 双写 Sip.log:token 上报链路是呼入问题复测的取证观察面(纯 NSLog
    // 不落 Sip.log;前缀对齐引擎管道,App 侧拉 /Documents/logs/Sip/Sip.log)
    SipCoreLogger.writeLine("\(SipLogPrefixEngine) [compat] [PUSH-REPORT] \(message)")
}

final class CompatPushReporter {

    static let shared = CompatPushReporter()

    // MARK: - 配置(账户 XML 下发;App 登录链每次 register 全量重写)

    private struct ReporterConfig {
        let url: String
        let postData: String
        let contentType: String
        let customHeaders: [String: String]
    }

    private var config: ReporterConfig?
    private var username = ""
    private var tokenCalls: Data?   // VoIP(usage=IncomingCall)
    private var tokenMsgs: Data?    // APNs(usage=Other)
    private var debouncer: DispatchWorkItem?

    /// selector 持久化键(40HEX:8HEX,装机一次生成永不重生成;线上 Acrobits
    /// 同形态,服务器按 (username, selector) 唯一索引 UPSERT)
    private static let selectorKey = "compat.push.selector"
    /// 去抖窗口:三触发源短时连发合并为一次上报
    private static let debounceSec: TimeInterval = 1.0
    /// 网络失败指数退避序列(1s/4s/16s,共 3 次重试;4xx 不重试)
    private static let retryDelays: [TimeInterval] = [1.0, 4.0, 16.0]

    private init() {}

    // MARK: - 对外入口(CompatAdapter / CompatBridge 接线)

    /// saveAccount 时:解析 pushTokenReporter* 节点(配置就绪后补发挂起上报)
    /// 状态仅主线程读写(setToken 来自 RN 桥线程,入口统一收敛;
    /// 上报主体 asyncAfter 主队列回调,天然主线程)
    func updateAccount(username: String, xml: XmlTree) {
        compatMain {
            self.username = username
            func node(_ name: String) -> String? {
                xml.getValueForNode(name)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let url = node("pushTokenReporterUrl"), !url.isEmpty,
               let postData = node("pushTokenReporterPostData"), !postData.isEmpty {
                let contentType = node("pushTokenReporterContentType") ?? ""
                config = ReporterConfig(
                    url: url,
                    postData: postData,
                    contentType: contentType.isEmpty ? "application/json" : contentType,
                    customHeaders: Self.parseCustomHeaders(node("pushTokenReporterCustomHeaders") ?? ""))
                compatLog("reporter config ready (url=\(url))")
            } else {
                compatLog("reporter config absent in account xml")
            }
            scheduleReport()
        }
    }

    /// deleteAccount 时:配置随账户清除(系统 token 保留,下次登录直接可用)
    func clearAccount() {
        compatMain {
            config = nil
            username = ""
            compatLog("reporter config cleared")
        }
    }

    /// setRegistrationId:token 变化触发(幂等,同值跳过)
    func setToken(_ token: Data?, usage: PushTokenUsage) {
        compatMain {
            switch usage {
            case .IncomingCall:
                guard token != tokenCalls else { return }
                tokenCalls = token
            case .Other:
                guard token != tokenMsgs else { return }
                tokenMsgs = token
            default:
                return
            }
            compatLog("token updated (usage=\(usage.rawValue))")
            scheduleReport()
        }
    }

    /// 注册成功触发一次(确保注册后服务端可关联 token 与账号)
    func reportOnRegistered() {
        compatMain {
            compatLog("token trigger: sip registered (200)")
            scheduleReport()
        }
    }

    // MARK: - 上报主体(1s 去抖合并连发;退避重试)

    private func scheduleReport() {
        debouncer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performTokenReport(attempt: 0)
        }
        debouncer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceSec, execute: work)
    }

    private func performTokenReport(attempt: Int) {
        guard let config = config, !config.url.isEmpty else {
            // 配置未就绪:挂起——App 冷启动 push 唤醒注册先于登录链
            // saveAccount 属正常时序,配置就绪时 updateAccount 补发
            compatLog("token pending: reporter config not ready")
            return
        }
        let body = Self.expandTemplate(config.postData, username: username,
                                       tokenCalls: tokenCalls, tokenMsgs: tokenMsgs)
        guard let url = URL(string: config.url) else {
            compatLog("token invalid url: \(config.url)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in config.customHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = Data(body.utf8)
        compatLog("token POST body=\(body)")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    compatLog("token FAILED (network): \(error.localizedDescription)")
                    self.retryTokenReport(attempt: attempt)
                } else if (200...299).contains(status) {
                    compatLog("token OK (\(status))")
                } else if (400...499).contains(status) {
                    // 4xx 报文问题重试无益;下次触发源(注册成功/登录链)自然重发
                    compatLog("token FAILED (\(status), no retry): \(Self.responseBodyText(data))")
                } else {
                    compatLog("token FAILED (\(status)): \(Self.responseBodyText(data))")
                    self.retryTokenReport(attempt: attempt)
                }
            }
        }.resume()
    }

    private func retryTokenReport(attempt: Int) {
        guard attempt < Self.retryDelays.count else {
            compatLog("token give up after \(Self.retryDelays.count) retries (wait next trigger)")
            return
        }
        let delay = Self.retryDelays[attempt]
        compatLog("token retry #\(attempt + 1) after \(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performTokenReport(attempt: attempt + 1)
        }
    }

    // MARK: - 占位符模板与 selector

    /// App 下发模板的占位符集(E3 契约消费面):%account[username]%、
    /// %selector%、%pushTokenIncomingCall%、%pushTokenOther%(token=
    /// base64(Data);未设置上报空串——对齐线上早期上报,服务器清旧 token)
    static func expandTemplate(_ template: String, username: String,
                               tokenCalls: Data?, tokenMsgs: Data?) -> String {
        template
            .replacingOccurrences(of: "%account[username]%", with: username)
            .replacingOccurrences(of: "%selector%", with: selectorValue())
            .replacingOccurrences(of: "%pushTokenIncomingCall%",
                                  with: tokenCalls?.base64EncodedString() ?? "")
            .replacingOccurrences(of: "%pushTokenOther%",
                                  with: tokenMsgs?.base64EncodedString() ?? "")
    }

    /// selector 生成(40HEX:8HEX,装机一次持久化;已存值正则校验防残键)
    private static func selectorValue() -> String {
        if let saved = UserDefaults.standard.string(forKey: selectorKey),
           saved.range(of: "^[0-9A-F]{40}:[0-9A-F]{8}$", options: .regularExpression) != nil {
            return saved
        }
        let selector = "\(randomHex(20)):\(randomHex(4))"
        UserDefaults.standard.set(selector, forKey: selectorKey)
        compatLog("token selector generated (\(selector.suffix(8)))")
        return selector
    }

    private static func randomHex(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, bytes, raw.baseAddress!)
        }
        return data.map { String(format: "%02X", $0) }.joined()
    }

    /// CustomHeaders 解析:每行一条 "Name: Value"(App 模板=单行 Bearer)
    static func parseCustomHeaders(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                headers[name] = value
            }
        }
        return headers
    }

    private static func responseBodyText(_ data: Data?) -> String {
        guard let data = data, let text = String(data: data, encoding: .utf8) else {
            return "(no body)"
        }
        return String(text.prefix(200))
    }
}
