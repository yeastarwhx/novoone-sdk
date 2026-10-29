#import "SipNetworkMonitor.h"

#import <Network/Network.h>

#import <arpa/inet.h>
#import <ifaddrs.h>

/*
 * =====================================================================
 * 常量
 * =====================================================================
 */

/* 候选网络稳定窗（毫秒，安卓 STABLE_DELAY_MS）：窗口内无新 path 更新
 * 才判定，切换中间态/双网竞态合并为一次上报 */
static double const kStableDelayMs = 800.0;

/* networkKey 的类型段（安卓 TYPE_* 同值） */
static NSString * const kNetTypeWifi  = @"wifi";
static NSString * const kNetTypeCell  = @"cell";
static NSString * const kNetTypeOther = @"other";

@interface SipNetworkMonitor ()
/* 换网事件落点（主线程回调） */
@property (nonatomic, copy) void (^listener)(NSString *reason);
/* 数据源（nw_path_monitor C 接口——NWPathMonitor 为 Swift 专属类；
 * 队列 = 主队列，handler 主线程执行） */
@property (nonatomic, strong, nullable) nw_path_monitor_t monitor;
/* 是否已 start（start/stop 幂等） */
@property (nonatomic, assign) BOOL started;
/* 上次上报口径的网络标识 "type|ip"；nil = 从未有效（全断网/未启动） */
@property (nonatomic, copy, nullable) NSString *lastKey;
/* 最新 path 快照的 key（handler 内计算缓存——nw_path_t 仅回调期间有效，
 * 防抖判定时用它对比，与安卓 fire 时重查 getActiveNetwork 规格等效）；
 * nil = 无可用网络 */
@property (nonatomic, copy, nullable) NSString *currentKey;
/* 同一快照的活跃 IPv4（key 的 v4 分量；header 只读暴露，引擎候选过滤
 * 消费） */
@property (nonatomic, copy, nullable) NSString *activeIpv4;
/* start 后首个快照只建基线不判定（启动不误触发） */
@property (nonatomic, assign) BOOL awaitingBaseline;
/* checkNowOnForeground 重启数据源后的首个快照直接走判定（不经防抖） */
@property (nonatomic, assign) BOOL awaitingForegroundCheck;
/* 防抖计时（主队列 dispatch_after，dispatch_block_cancel 可撤） */
@property (nonatomic, copy, nullable) dispatch_block_t pendingCheck;
@end

@implementation SipNetworkMonitor

- (instancetype)initWithListener:(void (^)(NSString *))listener
{
    self = [super init];
    if (self) {
        _listener = [listener copy];
    }
    return self;
}

- (void)dealloc
{
    /* 兜底：引擎未 stop 即释放时注销数据源（正常链路 engineShutdown
     * 已 stop；直接 C 调用，dealloc 内不发消息） */
    if (_monitor != NULL) {
        nw_path_monitor_cancel(_monitor);
    }
}

#pragma mark - 生命周期

- (void)start
{
    if (_started) {
        return;
    }
    _started = YES;
    /* 以当前网络为基线：首个 path 快照只建基线（启动不误触发） */
    _awaitingBaseline = YES;
    [self startMonitor];
}

- (void)stop
{
    if (!_started) {
        return;
    }
    _started = NO;
    [self cancelPendingCheck];
    if (_monitor != NULL) {
        nw_path_monitor_cancel(_monitor);
        _monitor = nil;
    }
    _awaitingBaseline = NO;
    _awaitingForegroundCheck = NO;
    _currentKey = nil;
}

- (void)checkNowOnForeground
{
    if (!_started) {
        return;
    }
    if (_awaitingBaseline) {
        /* 基线未建立（start 的首个快照未达）：启动快照即建基线，无需补判 */
        return;
    }
    /* 挂起期主队列冻结，path 更新可能未送达（E13）：重启数据源强制取
     * 当前快照——nw_path_monitor 无同步查询入口，新 monitor 启动即上报
     * 当前 path；首个快照直接走 checkNow 判定（不走防抖窗，一次性补判
     * 无连发合并需求）。挂起期 pjsua 线程同样冻结（无 SIP 活动竞态），
     * 补触发时序安全 */
    [self cancelPendingCheck];
    if (_monitor != NULL) {
        nw_path_monitor_cancel(_monitor);
        _monitor = nil;
    }
    _awaitingForegroundCheck = YES;
    [self startMonitor];
}

#pragma mark - 数据源

/* 创建并启动数据源：monitor 启动即上报当前 path（NWPathMonitor 语义），
 * 首个快照由 awaitingBaseline / awaitingForegroundCheck 分流 */
- (void)startMonitor
{
    nw_path_monitor_t monitor = nw_path_monitor_create();
    if (monitor == NULL) {
        /* 创建失败（理论不可达）：无换网检测，恢复链只剩库内被动检测兜底
         * （对齐安卓 ROM 限制路径的处理） */
        return;
    }
    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    __weak SipNetworkMonitor *weakSelf = self;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        SipNetworkMonitor *strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf->_started) {
            return;
        }
        [strongSelf onPathUpdate:path];
    });
    nw_path_monitor_start(monitor);
    self.monitor = monitor;
}

/* path 更新（主线程）：快照 key 缓存 + 按上下文分流 */
- (void)onPathUpdate:(nw_path_t)path
{
    self.currentKey = [self.class networkKeyForPath:path];
    /* 活跃 IPv4 快照（key "type|ipv4" 的 v4 分量；"no-ip" 归一为 nil） */
    NSArray<NSString *> *parts =
        [_currentKey componentsSeparatedByString:@"|"];
    self.activeIpv4 = (parts.count == 2
                       && ![parts[1] isEqualToString:@"no-ip"])
        ? parts[1] : nil;
    if (_awaitingBaseline) {
        /* start 的首个快照：只建基线不判定（启动不误触发） */
        _awaitingBaseline = NO;
        _lastKey = _currentKey;
        return;
    }
    if (_awaitingForegroundCheck) {
        /* 回前台补判：直接走判定体（不经防抖窗） */
        _awaitingForegroundCheck = NO;
        [self checkNow];
        return;
    }
    [self scheduleStableCheck];
}

#pragma mark - 防抖与判定（主线程）

/* 候选事件进防抖窗（窗口内新事件刷新计时，静默后判定一次） */
- (void)scheduleStableCheck
{
    [self cancelPendingCheck];
    __weak SipNetworkMonitor *weakSelf = self;
    dispatch_block_t check = dispatch_block_create((dispatch_block_flags_t)0, ^{
        SipNetworkMonitor *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.pendingCheck = nil;
        [strongSelf checkNow];
    });
    self.pendingCheck = check;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kStableDelayMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), check);
}

- (void)cancelPendingCheck
{
    if (_pendingCheck != nil) {
        dispatch_block_cancel(_pendingCheck);
        _pendingCheck = nil;
    }
}

/* 防抖静默后的最终判定（主线程；回前台补判复用同一判定体） */
- (void)checkNow
{
    NSString *key = self.currentKey;
    if (key == nil) {
        /* 无可用网络：清基线（恢复时必触发），不上报。断网窗口 NAT/TCP
         * 连接已死，IP 不变也要恢复；无缝切换的旧网失联不清基线——由
         * 后续快照的 key 对比覆盖 */
        self.lastKey = nil;
        return;
    }
    if ([key isEqualToString:self.lastKey]) {
        return;
    }
    NSString *reason = (self.lastKey == nil)
        ? @"lost-recovered"
        : [self.class deriveReasonFromKey:self.lastKey toKey:key];
    self.lastKey = key;
    if (_listener != nil) {
        _listener(reason);
    }
}

#pragma mark - networkKey 构成

/* 当前活跃网络 "type|ipv4"（无网/信息缺失返回 nil） */
+ (nullable NSString *)networkKeyForPath:(nw_path_t)path
{
    if (path == NULL || nw_path_get_status(path) != nw_path_status_satisfied) {
        return nil;
    }
    NSString *type = nil;
    if (nw_path_uses_interface_type(path, nw_interface_type_wifi)) {
        type = kNetTypeWifi;
    } else if (nw_path_uses_interface_type(path, nw_interface_type_cellular)) {
        type = kNetTypeCell;
    } else {
        type = kNetTypeOther; /* VPN 等：类型变化同样触发（恢复幂等） */
    }
    /* 活跃接口名（WiFi=en0 族；蜂窝=pdp_ip0 族）——path 只含其使用的
     * 接口（WiFi 在联时不含蜂窝接口），取首个有 v4 地址的即本 path 的
     * 地址；接口名取不到时退 "no-ip"（key 仍可对比，type 变化可判） */
    NSMutableArray<NSString *> *ifNames = [NSMutableArray array];
    nw_path_enumerate_interfaces(path, ^ bool (nw_interface_t interface) {
        const char *name = nw_interface_get_name(interface);
        if (name != NULL && name[0] != '\0') {
            [ifNames addObject:[NSString stringWithUTF8String:name]];
        }
        return true;
    });
    NSString *ipv4 = [self ipv4OnInterfaces:ifNames];
    return [NSString stringWithFormat:@"%@|%@",
            type, ipv4.length > 0 ? ipv4 : @"no-ip"];
}

/* 活跃接口的 IPv4 本地地址（getifaddrs 按接口名取 v4，P2 定稿形态：
 * 接口名来自 path 快照、地址来自系统接口表；按 path 接口序取首个命中；
 * 无 v4 返回 nil） */
+ (nullable NSString *)ipv4OnInterfaces:(NSArray<NSString *> *)ifNames
{
    if (ifNames.count == 0) {
        return nil;
    }
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) {
        return nil;
    }
    NSString *result = nil;
    for (NSString *ifName in ifNames) {
        for (struct ifaddrs *cursor = addrs; cursor != NULL;
             cursor = cursor->ifa_next) {
            if (cursor->ifa_addr == NULL || cursor->ifa_addr->sa_family != AF_INET) {
                continue;
            }
            NSString *name = (cursor->ifa_name != NULL)
                ? [NSString stringWithUTF8String:cursor->ifa_name] : nil;
            if (name == nil || ![name isEqualToString:ifName]) {
                continue;
            }
            char buf[INET_ADDRSTRLEN];
            const char *ip = inet_ntop(AF_INET,
                                       &((struct sockaddr_in *)cursor->ifa_addr)->sin_addr,
                                       buf, sizeof(buf));
            if (ip != NULL) {
                result = [NSString stringWithUTF8String:ip];
            }
            break;
        }
        if (result != nil) {
            break;
        }
    }
    freeifaddrs(addrs);
    return result;
}

/* 从基线 key 与新 key 推导触发原因（三分支的后两支） */
+ (NSString *)deriveReasonFromKey:(NSString *)oldKey toKey:(NSString *)newKey
{
    NSRange oldBar = [oldKey rangeOfString:@"|"];
    NSRange newBar = [newKey rangeOfString:@"|"];
    NSString *oldType = (oldBar.location == NSNotFound)
        ? oldKey : [oldKey substringToIndex:oldBar.location];
    NSString *newType = (newBar.location == NSNotFound)
        ? newKey : [newKey substringToIndex:newBar.location];
    if (![oldType isEqualToString:newType]) {
        return [NSString stringWithFormat:@"type-switch:%@->%@", oldType, newType];
    }
    return @"ip-changed"; /* 同类型（WiFi->WiFi）IP 变化 */
}

@end
