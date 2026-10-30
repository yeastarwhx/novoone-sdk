package cz.acrobits.libsoftphone.support.service;

import java.util.List;
import java.util.Locale;

/**
 * 语言环境服务（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：appLocaleChanged(locales) 通知 SDK 界面/通知文案切换语言
 * （多语言注册通知等 SDK 内置文案跟随）。本引擎的注册通知由宿主 App
 * 构建与刷新（App 侧在同链路自行 refreshNotificationForLanguageChange），
 * SDK 侧无本地化文案资产——no-op。
 */
public class LocaleService {

    /** App 语言变化通知（可带多个候选 locale，SDK 按序匹配） */
    public void appLocaleChanged(List<Locale> locales) {
        /* no-op：本引擎无 SDK 侧本地化文案，语言刷新由宿主完成 */
    }
}
