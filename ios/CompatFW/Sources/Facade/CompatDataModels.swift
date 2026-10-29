//
//  CompatDataModels.swift
//  CompatFW
//
//  Acrobits 兼容层:数据类(XmlTree / JsonDict / Event / Stream 等),
//  纯数据容器,无引擎依赖,直接给出可用实现。
//

import Foundation

// MARK: - XmlTree(App 组账户 XML / push payload 解析的载体)

@objcMembers public final class XmlTree: NSObject {
    @objc public let name: String
    @objc public var data: String?
    private(set) var attributes: [String: String] = [:]
    private(set) var children: [XmlTree] = []

    @objc public init(name: String) {
        self.name = name
        super.init()
    }

    /// NSDictionary -> XmlTree:每个键转同名子节点,嵌套 dict 递归转子树
    @objc public static func from(dictionary: [AnyHashable: Any]) -> XmlTree {
        let tree = XmlTree(name: "root")
        func append(_ dict: [AnyHashable: Any], to node: XmlTree) {
            for (rawKey, rawValue) in dict {
                let key = String(describing: rawKey)
                if let nested = rawValue as? [AnyHashable: Any] {
                    let child = XmlTree(name: key)
                    append(nested, to: child)
                    node.children.append(child)
                } else {
                    let child = XmlTree(name: key)
                    child.data = String(describing: rawValue)
                    node.children.append(child)
                }
            }
        }
        append(dictionary, to: tree)
        return tree
    }

    @objc public func setNodeValue(value: String, name: String) {
        if let existing = children.first(where: { $0.name == name }) {
            existing.data = value
        } else {
            let child = XmlTree(name: name)
            child.data = value
            children.append(child)
        }
    }

    @objc public func getValueForNode(_ name: String) -> String? {
        children.first(where: { $0.name == name })?.data
    }

    @objc public func setAttribute(name: String, value: String) {
        attributes[name] = value
    }

    @objc public func getAttribute(name: String) -> String? {
        attributes[name]
    }

    @objc public func getNode(name: String) -> XmlTree? {
        children.first(where: { $0.name == name })
    }

    @objc public func removeNode(name: String) -> Bool {
        guard let index = children.firstIndex(where: { $0.name == name }) else { return false }
        children.remove(at: index)
        return true
    }

    @objc public func addNode(_ node: XmlTree) {
        children.append(node)
    }

    @objc public func isEmpty() -> Bool {
        children.isEmpty && attributes.isEmpty && (data ?? "").isEmpty
    }

    @objc public func toString(_ pretty: Bool) -> String? {
        func render(_ node: XmlTree, depth: Int) -> String {
            let indent = pretty ? String(repeating: "  ", count: depth) : ""
            var line = "\(indent)<\(node.name)"
            for (key, value) in node.attributes.sorted(by: { $0.key < $1.key }) {
                line += " \(key)=\"\(value)\""
            }
            if node.children.isEmpty {
                if let data = node.data, !data.isEmpty {
                    line += ">\(data)</\(node.name)>"
                } else {
                    line += "/>"
                }
            } else {
                line += ">"
                for child in node.children {
                    line += pretty ? "\n" : ""
                    line += render(child, depth: depth + 1)
                }
                line += pretty ? "\n\(indent)</\(node.name)>" : "</\(node.name)>"
            }
            return line
        }
        return render(self, depth: 0)
    }
}

// MARK: - JsonObject / JsonDict(transients 与 JSON 数据支撑,D8:NSDictionary 桥接)

@objcMembers public class JsonObject: NSObject {
    var storage: [String: Any] = [:]

    @objc public func containsKey(_ key: String) -> Bool {
        storage[key] != nil
    }

    @objc public func removeKey(_ key: String) -> Bool {
        storage.removeValue(forKey: key) != nil
    }

    @objc public func clear() {
        storage.removeAll()
    }

    @objc public var size: Int {
        storage.count
    }

    @objc public var isEmpty: Bool {
        storage.isEmpty
    }
}

@objcMembers public final class JsonDict: JsonObject {
    @objc public func set(_ obj: Any, forKey key: String) {
        storage[key] = obj
    }

    // 对齐 Acrobits:find 是两个仅返回类型不同的 Swift-only 重载(共享 ObjC
    // selector 无法表达,故 @nonobjc);App 侧 `transients?.find(key) as String?`
    // 靠返回类型上下文消歧
    @nonobjc public func find(_ key: String) -> String? {
        storage[key] as? String
    }

    @nonobjc public func find(_ key: String) -> JsonDict? {
        storage[key] as? JsonDict
    }

    @objc public func findString(_ key: String) -> String? {
        storage[key] as? String
    }

    @objc public func findDict(_ key: String) -> JsonDict? {
        storage[key] as? JsonDict
    }

    @objc public func toString(_ pretty: Bool) -> String? {
        guard JSONSerialization.isValidJSONObject(storage),
              let data = try? JSONSerialization.data(withJSONObject: storage) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

@objcMembers public final class JsonArray: NSObject {
    var items: [Any] = []

    @objc public func add(_ obj: Any) {
        items.append(obj)
    }

    @objc public var size: Int {
        items.count
    }

    @objc public var isEmpty: Bool {
        items.isEmpty
    }
}

// MARK: - SoftphoneTransients(transients 键名常量容器)

@objcMembers public final class SoftphoneTransients: NSObject {
    @objc public static let callRate = "callRate"
    @objc public static let codecs = "codecs"
    @objc public static let networkInterfaceName = "networkInterfaceName"
    @objc public static let desiredMedia = "desiredMedia"
    @objc public static let security = "security"
}

// MARK: - SoftphoneRemoteUser

@objcMembers public final class SoftphoneRemoteUser: NSObject {
    @objc public var genericUri: String?
    @objc public var displayName: String?

    @objc public init(genericUri: String?, displayName: String?) {
        self.genericUri = genericUri
        self.displayName = displayName
        super.init()
    }
}

// MARK: - SoftphoneEvent / SoftphoneCallEvent

@objcMembers public class SoftphoneEvent: NSObject {
    @objc public var direction: EventDirectionType = .Unspecified
    @objc public var timestamp: Double = 0
    @objc public var sender: String?
    @objc public let eventId: UInt
    @objc public private(set) var streamKey: String?
    @objc public internal(set) var accountId: String?
    @objc public internal(set) var accountName: String?
    @objc public var transients: JsonDict?
    @objc public internal(set) var remoteUsers: [SoftphoneRemoteUser] = []
    private weak var stream: SoftphoneEventStream?

    /// 事件 ID 单调递增,与 Acrobits 一样作为通话对象的稳定标识
    private static var nextEventId: UInt = 1
    private static let idLock = NSLock()

    override public init() {
        SoftphoneEvent.idLock.lock()
        eventId = SoftphoneEvent.nextEventId
        SoftphoneEvent.nextEventId += 1
        SoftphoneEvent.idLock.unlock()
        super.init()
        // Acrobits 语义:transients 惰性非 nil——App 的 get→mutate→写回
        // 模式(NovoEngine.call 的 if let call.transients)依赖恒真。
        // 缺省 nil 时呼出 requestId/dialAction 恒丢,INVITE 无 X-REQUEST-ID
        // (call out 无 X-Request-ID 段、wire INVITE 无该头;来电正常
        // ——事件对象由 compat 构造,物化时已建)
        transients = JsonDict()
    }

    @objc public func setStream(_ stream: SoftphoneEventStream) {
        self.stream = stream
        self.streamKey = stream.streamIdentifier
    }

    @objc public func getStream() -> SoftphoneEventStream? {
        stream
    }

    @objc public func isCall() -> Bool {
        self is SoftphoneCallEvent
    }

    @objc public func isMessage() -> Bool {
        false
    }

    @objc public func asCall() -> SoftphoneCallEvent? {
        self as? SoftphoneCallEvent
    }

    @objc public func getRemoteUser(index: Int32) -> SoftphoneRemoteUser? {
        let idx = Int(index)
        guard idx >= 0, idx < remoteUsers.count else { return nil }
        return remoteUsers[idx]
    }

    @objc public var remoteUserCount: Int32 {
        Int32(remoteUsers.count)
    }

    @objc public var timestampDate: Date? {
        timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

}

@objcMembers public final class SoftphoneCallEvent: SoftphoneEvent {
    @objc public private(set) var timeEstablished: Double = 0
    @objc public private(set) var duration: Double = 0
    @objc public var callResult: CallResultType = .Unknown
    @objc public var customHeaders: JsonDict?
    /// compat 内部:呼出目标 uri(create(withAccountId:uri:) 传入)或来电原始 uri
    @objc public var uri: String?

    override public init() {
        super.init()
    }

    @objc public static func create() -> SoftphoneCallEvent {
        SoftphoneCallEvent()
    }

    @objc public static func create(withRemoteUser user: SoftphoneRemoteUser) -> SoftphoneCallEvent {
        let event = SoftphoneCallEvent()
        event.remoteUsers = [user]
        return event
    }

    @objc public static func create(withAccountId accountId: String, uri: String) -> SoftphoneCallEvent {
        let event = SoftphoneCallEvent()
        event.accountId = accountId
        event.uri = uri
        event.direction = .Outgoing
        event.remoteUsers = [SoftphoneRemoteUser(genericUri: uri, displayName: nil)]
        return event
    }

    /// 通话建立时间(引擎侧接通后由 Adapter 写入)
    func markEstablished(at time: Double) {
        timeEstablished = time
    }

    /// 接通时刻 Date(timeEstablished 为毫秒,对齐 Acrobits/Android 契约)
    @objc public var timeEstablishedDate: Date? {
        timeEstablished > 0 ? Date(timeIntervalSince1970: timeEstablished / 1000) : nil
    }

    @objc public func setCustomHeader(name: String, value: String) {
        if customHeaders == nil {
            customHeaders = JsonDict()
        }
        customHeaders?.set(value, forKey: name)
    }

    @objc public func findCustomHeader(name: String) -> String? {
        customHeaders?.findString(name)
    }
}

// MARK: - SoftphoneEventStream / SoftphoneStreamQuery

@objcMembers public final class SoftphoneEventStream: NSObject {
    @objc public let streamIdentifier: String
    /// App 侧不需要流成员管理,compat 仅保留标识与注册表

    private init(identifier: String) {
        self.streamIdentifier = identifier
        super.init()
    }

    private static let registryLock = NSLock()
    private static var registry: [String: SoftphoneEventStream] = [:]
    private static let legacyKey = "legacy-call-history"

    @objc public static func generate() -> SoftphoneEventStream {
        SoftphoneEventStream.load(UUID().uuidString)!
    }

    /// 首次 load 创建并注册,后续返回同一实例(App 侧 load(legacyCallHistoryStreamKey()) 必须命中)
    @objc public static func load(_ key: String) -> SoftphoneEventStream? {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] {
            return existing
        }
        let stream = SoftphoneEventStream(identifier: key)
        registry[key] = stream
        return stream
    }

    @objc public func save() {}
}

@objcMembers public final class SoftphoneStreamQuery: NSObject {
    @objc public static func legacyCallHistoryStreamKey() -> String {
        "legacy-call-history"
    }
}

// MARK: - AccountXml

@objcMembers public final class AccountXml: NSObject {
    @objc public let xml: XmlTree
    @objc public var enabled: Bool = true
    @objc public internal(set) var typeId: String?

    @objc public init(xml: XmlTree) {
        self.xml = xml
        super.init()
    }

    @objc public func getString(_ key: String) -> String? {
        xml.getValueForNode(key)
    }
}
