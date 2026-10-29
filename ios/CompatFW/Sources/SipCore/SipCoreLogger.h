#ifndef SIP_CORE_LOGGER_H_
#define SIP_CORE_LOGGER_H_

/*
 * SipCoreLogger — SipCore 引擎统一日志（对齐安卓 SipCoreLogger 职责）。
 *
 * 双通道输出：
 *   1. os_log（unified logging，Console.app 可查，子系统/类别过滤）；
 *   2. 文件 Documents/logs/Sip/Sip.log（沿用 Acrobits 时代路径，
 *      业务侧日志查看习惯不变；超限滚动备份 Sip.log.old）。
 *
 * 前缀约定（对齐安卓）：[engine] / [ys] / [webrtc] / [pjsua]。
 * ys_log（pjsua 全量日志）经 pjsuaLog:message: 接入同一管道。
 *
 * 线程模型：所有方法线程安全（ys_log 来自 pjsua worker 线程）；
 * 文件写入收敛到内部串行队列。引擎层禁止 print/NSLog（novoone-app 规范）。
 */

#import <Foundation/Foundation.h>

/* 日志前缀常量（引擎/桥接层组行时使用，禁止裸拼字符串） */
FOUNDATION_EXPORT NSString * const SipLogPrefixEngine;
FOUNDATION_EXPORT NSString * const SipLogPrefixYs;
FOUNDATION_EXPORT NSString * const SipLogPrefixWebrtc;
FOUNDATION_EXPORT NSString * const SipLogPrefixPjsua;

/* 日志级别（对齐 pjsua：1=ERROR..5=TRACE，与 ys_log 回调同标度） */
typedef NS_ENUM(NSInteger, SipLogLevel) {
    SipLogLevelError = 1,
    SipLogLevelWarn  = 2,
    SipLogLevelInfo  = 3,
    SipLogLevelDebug = 4,
    SipLogLevelTrace = 5,
};

@interface SipCoreLogger : NSObject

/* 写一行已含前缀的日志（[engine]/[webrtc]/[ys] 行的通用入口） */
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/* 拼前缀后写一行（prefix 用 SipLogPrefix* 常量） */
+ (void)logWithPrefix:(NSString *)prefix
               format:(NSString *)format, ... NS_FORMAT_FUNCTION(2, 3);

/* 写一行已拼好的完整日志（Swift 专用——可变参 format 方法无法导入 Swift，
 * 桥接层传整行，前缀自行拼接 SipLogPrefix* 常量） */
+ (void)writeLine:(NSString *)line;

/* ys_log 回调专用：pjsua 原始日志行（自动补 [pjsua] 前缀） */
+ (void)pjsuaLog:(NSInteger)level message:(NSString *)msg;

@end

#endif /* SIP_CORE_LOGGER_H_ */
