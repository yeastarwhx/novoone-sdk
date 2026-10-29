#import "SipCallSessionRegistry.h"

/* 容量与滞留时长（对齐安卓 CallSessionRegistry 常量） */
static NSInteger const kSipMaxSessions    = 2;
static long long const kSipTerminalLinger = 1500;

@implementation SipCallSessionRegistry {
    /* 插入序保序（快照顺序稳定，UI 列表不跳动） */
    NSMutableDictionary<NSNumber *, SipCallSession *> *_sessions;
    long long _nextSessionId;
    /* 容器锁：写路径仅引擎主线程，快照契约要求任意线程可查 */
    id _lock;
}

+ (NSInteger)maxSessions
{
    return kSipMaxSessions;
}

+ (long long)terminalLingerMs
{
    return kSipTerminalLinger;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _sessions = [[NSMutableDictionary alloc] init];
        _nextSessionId = 1;
        _lock = [[NSObject alloc] init];
    }
    return self;
}

- (nullable SipCallSession *)createSessionWithDirection:(SipCallDirection)direction
{
    @synchronized (self->_lock) {
        if ([self activeCountLocked] >= SipCallSessionRegistry.maxSessions) {
            return nil;
        }
        /* callId 复用防御：pjsua 会回收 id，新会话顶掉同 callId 旧残留 */
        long long sessionId = self->_nextSessionId++;
        SipCallSession *session = [[SipCallSession alloc] initWithSessionId:sessionId direction:direction];
        session.createdAt = SipCurrentTimeMillis();
        self->_sessions[@(sessionId)] = session;
        return session;
    }
}

- (nullable SipCallSession *)sessionWithId:(long long)sessionId
{
    @synchronized (self->_lock) {
        return self->_sessions[@(sessionId)];
    }
}

- (nullable SipCallSession *)findByCallId:(NSInteger)callId
{
    if (callId < 0) {
        return nil;
    }
    @synchronized (self->_lock) {
        for (SipCallSession *session in self->_sessions.allValues) {
            if (session.callId == callId) {
                return session;
            }
        }
        return nil;
    }
}

- (nullable SipCallSession *)findByGroupId:(NSString *)groupId
{
    if (groupId.length == 0) {
        return nil;
    }
    @synchronized (self->_lock) {
        for (SipCallSession *session in self->_sessions.allValues) {
            if ([session.groupId isEqualToString:groupId]) {
                return session;
            }
        }
        return nil;
    }
}

- (nullable SipCallSession *)removeSessionWithId:(long long)sessionId
{
    @synchronized (self->_lock) {
        SipCallSession *session = self->_sessions[@(sessionId)];
        [self->_sessions removeObjectForKey:@(sessionId)];
        return session;
    }
}

- (NSArray<SipCallSession *> *)snapshot
{
    @synchronized (self->_lock) {
        /* 字典 allValues 无序：按 sessionId 排序还原插入序（id 自增单调） */
        return [self->_sessions.allValues sortedArrayUsingComparator:
                ^NSComparisonResult(SipCallSession *a, SipCallSession *b) {
            if (a.sessionId < b.sessionId) {
                return NSOrderedAscending;
            }
            if (a.sessionId > b.sessionId) {
                return NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
    }
}

- (NSInteger)count
{
    @synchronized (self->_lock) {
        return self->_sessions.count;
    }
}

- (NSInteger)activeCount
{
    @synchronized (self->_lock) {
        return [self activeCountLocked];
    }
}

- (void)clear
{
    @synchronized (self->_lock) {
        [self->_sessions removeAllObjects];
    }
}

- (void)purgeExpiredNow
{
    long long now = SipCurrentTimeMillis();
    @synchronized (self->_lock) {
        NSMutableArray<NSNumber *> *expired = nil;
        for (SipCallSession *session in self->_sessions.allValues) {
            if (session.finalizeRemoveAt > 0 && now >= session.finalizeRemoveAt) {
                if (!expired) {
                    expired = [[NSMutableArray alloc] init];
                }
                [expired addObject:@(session.sessionId)];
            }
        }
        for (NSNumber *key in expired) {
            [self->_sessions removeObjectForKey:key];
        }
    }
}

#pragma mark - 持锁内部工具

- (NSInteger)activeCountLocked
{
    NSInteger n = 0;
    for (SipCallSession *session in self->_sessions.allValues) {
        if (![session isTerminal]) {
            n++;
        }
    }
    return n;
}

@end
