#ifndef SIP_RINGTONE_HELPER_H_
#define SIP_RINGTONE_HELPER_H_

/*
 * SipRingtoneHelper — 来电铃声 / 回铃音播放（对齐安卓 RingtoneHelper 职责）。
 *
 * - playRingtone：来电振铃提示（合成铃声音频循环 + 振动脉冲）。无铃声
 *   资源文件，采用程序合成方案：440+480Hz 双音（北美标准电话铃），
 *   2s 鸣 / 3s 止循环，首次调用时合成 WAV 缓存 Caches 目录复用。
 * - playBackTone：回铃音（呼出 Ringing 期，安卓 ToneGenerator
 *   TONE_SUP_RINGTONE 等价）：440+480Hz，1s 鸣 / 3s 止循环。
 *
 * 播放走 AVAudioPlayer + 当前 AVAudioSession（引擎已配置
 * playAndRecord/voiceChat）；播放失败降级为仅振动/静默（绝不崩溃）。
 *
 * 线程模型：仅主线程调用（内部状态无锁）；全部方法可重入
 * （重复 play 先停旧的再播新的，stop 无铃声时为 no-op）。
 */

#import <Foundation/Foundation.h>

@interface SipRingtoneHelper : NSObject

/* 播放来电铃声（合成铃声循环 + 振动脉冲） */
+ (void)playRingtone;

/* 停止来电铃声与振动（无铃声时 no-op） */
+ (void)stopRingtone;

/* 播放回铃音（呼出 Ringing 期，440+480Hz 标准节奏循环） */
+ (void)playBackTone;

/* 停止回铃音（无回铃音时 no-op） */
+ (void)stopBackTone;

/* 全停（引擎 shutdown 用） */
+ (void)stopAll;

@end

#endif /* SIP_RINGTONE_HELPER_H_ */
