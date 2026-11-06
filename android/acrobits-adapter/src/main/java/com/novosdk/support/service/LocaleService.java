package com.novosdk.support.service;

import java.util.List;
import java.util.Locale;

/**
 * 语言环境服务（NovoSDK softphone API 层，Acrobits 后端）。
 *
 * App 使用面：appLocaleChanged(locales) 通知 SDK 切换界面/通知文案语言。
 * 真身 LocaleService 为 SDKServices 注册的服务接口（真身 SDK 内部实现，
 * 含 native translations 刷新链）——按调用转发；此前 no-op 导致 26 形态
 * 切语言后 SDK 侧通知文案不跟随（2026-11-05 审计修复）。
 */
public class LocaleService {

    /** App 语言变化通知（可带多个候选 locale，SDK 按序匹配）；真身未就绪时静默跳过 */
    public void appLocaleChanged(List<Locale> locales) {
        try {
            cz.acrobits.libsoftphone.support.service.LocaleService real =
                    cz.acrobits.libsoftphone.support.SDKServices.get(
                            cz.acrobits.libsoftphone.support.service.LocaleService.class);
            if (real != null) {
                real.appLocaleChanged(locales);
            }
        } catch (Throwable t) {
            android.util.Log.w("Novosdk.LocaleService", "appLocaleChanged forward failed: " + t);
        }
    }
}
