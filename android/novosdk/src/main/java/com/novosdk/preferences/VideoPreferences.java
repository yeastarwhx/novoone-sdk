package com.novosdk.preferences;

import com.novosdk.Preferences;

/**
 * 视频偏好基类（NovoSDK softphone API 层）。
 *
 * App 的 NovoPreferences extends VideoPreferences 并覆盖 overrideDefaults。
 * 本引擎纯语音（WebRTC audio-only），无视频偏好成员。
 */
public class VideoPreferences extends Preferences {
}
