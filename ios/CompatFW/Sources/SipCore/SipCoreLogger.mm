#import "SipCoreLogger.h"

#import <os/log.h>

/*
 * 日志文件布局（沿用 Acrobits 时代路径）：
 *   Documents/logs/Sip/Sip.log       当前日志
 *   Documents/logs/Sip/Sip.log.old   超限滚动备份（单份）
 */

NSString * const SipLogPrefixEngine = @"[engine]";
NSString * const SipLogPrefixYs     = @"[ys]";
NSString * const SipLogPrefixWebrtc = @"[webrtc]";
NSString * const SipLogPrefixPjsua  = @"[pjsua]";

/* 单日志文件上限（字节）：超过即滚动，避免通话问题排查时文件无限膨胀 */
static const long kSipLogMaxFileSize = 2 * 1024 * 1024;

/* os_log 单条消息上限（字符）：实测 1024 处截断为 <...>（macOS 标定，
 * unified logging 同源），阈值与组桶同取 1000 留余量——未达限整条不分片 */
static const NSUInteger kSipOsLogMaxChars = 1000;

@interface SipCoreLogger ()
@property (nonatomic, strong) dispatch_queue_t fileQueue;
/* os_log 统一串行输出队列（顺序保证 + 防流控，见 writeLine 注释） */
@property (nonatomic, strong) dispatch_queue_t dripQueue;
@property (nonatomic, copy) NSString *logFilePath;
/* 落盘行计数（fileQueue 串行访问）：周期触发滚动复查 */
@property (nonatomic, assign) NSUInteger appendCount;
@end

@implementation SipCoreLogger

+ (os_log_t)osLog
{
    static os_log_t log = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.novoone.sipcore", "Sip");
    });
    return log;
}

+ (instancetype)sharedLogger
{
    static SipCoreLogger *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[SipCoreLogger alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _fileQueue = dispatch_queue_create("com.novoone.sipcore.logger", DISPATCH_QUEUE_SERIAL);
        /* os_log 统一串行输出队列（见 writeLine 注释） */
        _dripQueue = dispatch_queue_create("com.novoone.sipcore.drip", DISPATCH_QUEUE_SERIAL);
        _logFilePath = [self.class currentLogFilePath];
        [self prepareLogFile];
    }
    return self;
}

#pragma mark - 对外入口

+ (void)log:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [[self sharedLogger] writeLine:line];
}

+ (void)logWithPrefix:(NSString *)prefix format:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@", prefix, body];
    [[self sharedLogger] writeLine:line];
}

/* Swift 专用入口：可变参 format 方法无法导入 Swift（NS_FORMAT_FUNCTION +
 * va_list 形态），桥接层经此传已拼好的整行（prefix 自带） */
+ (void)writeLine:(NSString *)line
{
    [[self sharedLogger] writeLine:line];
}

+ (void)pjsuaLog:(NSInteger)level message:(NSString *)msg
{
    if (msg.length == 0) {
        return;
    }
    /* pjsua 原始行（含 SIP 报文 dump）补 [pjsua] 前缀后进同一管道 */
    NSString *line = [NSString stringWithFormat:@"%@%ld %@",
                      SipLogPrefixPjsua, (long)level, msg];
    [[self sharedLogger] writeLine:line];
}

#pragma mark - 内部（文件 + os_log）

- (void)writeLine:(NSString *)line
{
    if (line.length == 0) {
        return;
    }
    /* os_log：统一日志系统（Console.app 按 subsystem/category 过滤）。
     * 格式串必须为常量，消息经 %@ 传入避免百分号转义问题。
     * 限制：长报文 dump（4KB+ SIP 消息）单条超限被截为 <...>；多条拆段
     * 突发又触发系统流控（只留头尾丢中段）。
     * 方案：所有条目统一经 dripQueue 串行输出（提交序 = 显示序，杜绝
     * 长短消息交错乱序）；未达限（≤1000 字符）整条不分片；超长多行
     * 消息按原始行组 ≤1000 字符桶、整桶单条输出，桶间 usleep 20ms
     * 防流控；标签注入原行前缀 + [n/m]；文件写入整行原样 */
    NSString *prefix = @"";
    NSMutableArray<NSString *> *buckets = nil;
    if (line.length > kSipOsLogMaxChars) {
        NSArray<NSString *> *rows = [line componentsSeparatedByString:@"\n"];
        /* 行首前缀（如 [pjsua]）注入每个分片标签：分片内容（Via:/SDP 行）
         * 不含过滤关键词，无前缀会被终端按 pjsua/webrtc 检索整段滤掉 */
        NSRange br = [rows[0] rangeOfString:@"]"];
        if ([rows[0] hasPrefix:@"["] && br.location != NSNotFound && br.location < 16) {
            prefix = [rows[0] substringToIndex:br.location + 1];
        }
        /* 组桶：行保持完整，凑 ≤1000 字符一桶（实测上限 1024，留余量）；
         * 未达限整条不分片；4KB INVITE 约 5 桶，串行占用 ~0.1s */
        buckets = [NSMutableArray array];
        NSMutableString *cur = nil;
        for (NSString *row in rows) {
            if (cur == nil || cur.length + row.length + 1 > kSipOsLogMaxChars) {
                cur = [[NSMutableString alloc] init];
                [buckets addObject:cur];
            }
            if (cur.length > 0) {
                [cur appendString:@"\n"];
            }
            [cur appendString:row];
        }
    }
    dispatch_async(self.dripQueue, ^{
        if (buckets == nil) {
            os_log_with_type(self.class.osLog, OS_LOG_TYPE_DEFAULT, "%{public}@", line);
            return;
        }
        NSUInteger parts = buckets.count;
        [buckets enumerateObjectsUsingBlock:^(NSString *bucket, NSUInteger i, BOOL *stop) {
            NSString *tagged = [NSString stringWithFormat:@"%@ [%lu/%lu]\n%@",
                                prefix, (unsigned long)(i + 1), (unsigned long)parts, bucket];
            os_log_with_type(self.class.osLog, OS_LOG_TYPE_DEFAULT, "%{public}@", tagged);
            if (i + 1 < parts) {
                usleep(20000);
            }
        }];
    });

    NSString *timestamped = [NSString stringWithFormat:@"%@ %@\n",
                             [self.class timestamp], line];
    dispatch_async(self.fileQueue, ^{
        [self appendToFile:timestamped];
    });
}

- (void)appendToFile:(NSString *)line
{
    @try {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:self.logFilePath];
        if (!handle) {
            /* 文件被外部删除等情况：重建后重试一次 */
            [self.class createFileIfNeedAtPath:self.logFilePath];
            handle = [NSFileHandle fileHandleForWritingAtPath:self.logFilePath];
            if (!handle) {
                return;
            }
        }
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
        /* 常驻进程只启动时滚动不够（VoIP 进程数天不重启，SIP 报文全量
         * 落盘可涨至几十 MB）：周期复查滚动。fileQueue 串行，计数安全 */
        if (++self.appendCount % 512 == 0) {
            [self.class rollFileIfNeededAtPath:self.logFilePath];
        }
    } @catch (NSException *e) {
        /* 日志写失败不得影响通话链路 */
    }
}

- (void)prepareLogFile
{
    dispatch_async(self.fileQueue, ^{
        NSString *path = self.logFilePath;
        [self.class createFileIfNeedAtPath:path];
        [self.class rollFileIfNeededAtPath:path];
    });
}

#pragma mark - 路径 / 时间戳

/* 滚动：超过上限即把当前文件转存 .old（放弃更早的备份）。启动时
 * （prepareLogFile）与写入过程中（appendToFile 周期复查）共用 */
+ (void)rollFileIfNeededAtPath:(NSString *)path
{
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size > (unsigned long long)kSipLogMaxFileSize) {
        NSString *backup = [self backupLogFilePath];
        [[NSFileManager defaultManager] removeItemAtPath:backup error:nil];
        [[NSFileManager defaultManager] moveItemAtPath:path toPath:backup error:nil];
        [self createFileIfNeedAtPath:path];
    }
}

+ (NSString *)logDirectoryPath
{
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = dirs.firstObject ?: NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:@"logs/Sip"];
}

+ (NSString *)currentLogFilePath
{
    return [[self logDirectoryPath] stringByAppendingPathComponent:@"Sip.log"];
}

+ (NSString *)backupLogFilePath
{
    return [[self logDirectoryPath] stringByAppendingPathComponent:@"Sip.log.old"];
}

+ (void)createFileIfNeedAtPath:(NSString *)path
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (dir.length > 0 && ![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
}

+ (NSString *)timestamp
{
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [formatter stringFromDate:[NSDate date]];
}

@end
