#import "SipRingtoneHelper.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#import <math.h>

#import "SipCoreLogger.h"

/* 来电振动节奏：每拍一次振动脉冲（近似系统来电节奏；音频循环独立） */
static NSTimeInterval const kSipRingInterval = 2.0;

/* 合成参数：电话频段双音（北美标准 440+480Hz），8kHz/16bit 单声道足够 */
static double const kSipToneSampleRate = 8000.0;
static double const kSipToneFreqA      = 440.0;
static double const kSipToneFreqB      = 480.0;
static double const kSipToneAmplitude  = 0.5;   /* 双音各 0.5 合成后 0.5 峰值 */

/* 缓存文件名（Caches 目录，合成一次复用） */
static NSString * const kSipRingtoneFile = @"sipcore_ringtone.wav";  /* 2s 鸣 / 3s 止 */
static NSString * const kSipBackToneFile = @"sipcore_backtone.wav";  /* 1s 鸣 / 3s 止 */

/* WAV 小端写入辅助 */
static void sipWavAppendUInt32(NSMutableData *data, uint32_t value)
{
    uint8_t bytes[4] = {
        (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF), (uint8_t)((value >> 24) & 0xFF)
    };
    [data appendBytes:bytes length:4];
}

static void sipWavAppendUInt16(NSMutableData *data, uint16_t value)
{
    uint8_t bytes[2] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF) };
    [data appendBytes:bytes length:2];
}

/*
 * 合成「双音-间歇」循环 WAV 并写入 Caches（已存在直接复用路径）。
 * 返回文件路径；磁盘写入失败返回 nil（调用方降级为仅振动/静默）。
 */
static NSString *sipSynthesizeToneWav(NSString *fileName,
                                      double onSeconds,
                                      double offSeconds)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *cacheDir = [[fm URLsForDirectory:NSCachesDirectory
                                   inDomains:NSUserDomainMask] firstObject];
    if (cacheDir == nil) {
        return nil;
    }
    NSURL *fileUrl = [cacheDir URLByAppendingPathComponent:fileName];
    NSString *path = fileUrl.path;
    if ([fm fileExistsAtPath:path]) {
        return path;
    }

    long long onSamples = (long long)(onSeconds * kSipToneSampleRate);
    long long totalSamples = onSamples + (long long)(offSeconds * kSipToneSampleRate);
    long long fadeSamples = (long long)(0.02 * kSipToneSampleRate);  /* 20ms 淡入淡出防爆音 */

    NSMutableData *wav = [NSMutableData data];
    uint32_t dataSize = (uint32_t)(totalSamples * 2);
    /* RIFF 头（44 字节，PCM16 单声道） */
    [wav appendBytes:"RIFF" length:4];
    sipWavAppendUInt32(wav, 36 + dataSize);
    [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];
    sipWavAppendUInt32(wav, 16);
    sipWavAppendUInt16(wav, 1);  /* PCM */
    sipWavAppendUInt16(wav, 1);  /* mono */
    sipWavAppendUInt32(wav, (uint32_t)kSipToneSampleRate);
    sipWavAppendUInt32(wav, (uint32_t)(kSipToneSampleRate * 2));  /* byte rate */
    sipWavAppendUInt16(wav, 2);  /* block align */
    sipWavAppendUInt16(wav, 16); /* bits per sample */
    [wav appendBytes:"data" length:4];
    sipWavAppendUInt32(wav, dataSize);

    for (long long i = 0; i < totalSamples; i++) {
        double sample = 0.0;
        if (i < onSamples) {
            double t = (double)i / kSipToneSampleRate;
            double env = 1.0;
            if (i < fadeSamples) {
                env = (double)i / (double)fadeSamples;
            } else if (i > onSamples - fadeSamples) {
                env = (double)(onSamples - i) / (double)fadeSamples;
            }
            double tone = sin(2.0 * M_PI * kSipToneFreqA * t)
                        + sin(2.0 * M_PI * kSipToneFreqB * t);
            sample = tone * 0.5 * kSipToneAmplitude * env;
        }
        int16_t pcm = (int16_t)(sample * 32767.0);
        sipWavAppendUInt16(wav, (uint16_t)pcm);
    }

    if (![wav writeToFile:path options:NSDataWritingAtomic error:nil]) {
        return nil;
    }
    return path;
}

/* 循环播放合成音（失败返回 nil，调用方降级） */
static AVAudioPlayer *sipStartLoopPlayer(NSString *fileName,
                                         double onSeconds,
                                         double offSeconds)
{
    NSString *path = sipSynthesizeToneWav(fileName, onSeconds, offSeconds);
    if (path == nil) {
        [SipCoreLogger logWithPrefix:SipLogPrefixEngine
                             format:@"ringtone wav synth failed: %@", fileName];
        return nil;
    }
    NSError *error = nil;
    AVAudioPlayer *player =
        [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                error:&error];
    if (player == nil) {
        [SipCoreLogger logWithPrefix:SipLogPrefixEngine
                             format:@"ringtone player init failed: %@",
                                 error.localizedDescription ?: @"unknown"];
        return nil;
    }
    player.numberOfLoops = -1;  /* 循环直到 stop */
    player.volume = 1.0;
    if (![player play]) {
        [SipCoreLogger logWithPrefix:SipLogPrefixEngine
                             format:@"ringtone player play failed"];
        return nil;
    }
    return player;
}

@implementation SipRingtoneHelper

static NSTimer *s_ringTimer = nil;
static AVAudioPlayer *s_ringPlayer = nil;
static AVAudioPlayer *s_backPlayer = nil;

+ (void)playRingtone
{
    [self stopRingtone];
    s_ringPlayer = sipStartLoopPlayer(kSipRingtoneFile, 2.0, 3.0);
    s_ringTimer = [NSTimer timerWithTimeInterval:kSipRingInterval
                                            target:self
                                          selector:@selector(ringTick:)
                                          userInfo:nil
                                           repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:s_ringTimer forMode:NSDefaultRunLoopMode];
    /* 立即播第一拍（不等首个 interval） */
    [self ringTick:s_ringTimer];
    [SipCoreLogger logWithPrefix:SipLogPrefixEngine format:@"ringtone started%@",
        s_ringPlayer ? @" (tone+vibrate)" : @" (vibrate only - audio degraded)"];
}

+ (void)stopRingtone
{
    if (s_ringPlayer) {
        [s_ringPlayer stop];
        s_ringPlayer = nil;
    }
    if (s_ringTimer) {
        [s_ringTimer invalidate];
        s_ringTimer = nil;
        [SipCoreLogger logWithPrefix:SipLogPrefixEngine format:@"ringtone stopped"];
    }
}

+ (void)ringTick:(NSTimer *)timer
{
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

+ (void)playBackTone
{
    if (s_backPlayer != nil) {
        return;  /* 已在播（呼出 Ringing 事件可能重复触发） */
    }
    s_backPlayer = sipStartLoopPlayer(kSipBackToneFile, 1.0, 3.0);
    [SipCoreLogger logWithPrefix:SipLogPrefixEngine format:@"back tone started%@",
        s_backPlayer ? @"" : @" (degraded - no audio)"];
}

+ (void)stopBackTone
{
    if (s_backPlayer) {
        [s_backPlayer stop];
        s_backPlayer = nil;
        [SipCoreLogger logWithPrefix:SipLogPrefixEngine format:@"back tone stopped"];
    }
}

+ (void)stopAll
{
    [self stopRingtone];
    [self stopBackTone];
}

@end
