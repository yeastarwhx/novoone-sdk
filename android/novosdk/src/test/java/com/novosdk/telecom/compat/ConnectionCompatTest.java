package com.novosdk.telecom.compat;

import static org.junit.Assert.assertEquals;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;

import java.util.Arrays;
import java.util.Collection;

/**
 * pickLevel 分档边界表驱动（分档错配 = 低版本设备 NoSuchMethodError
 * 崩溃级风险，connectionfactory-sinkdown 下沉后的等价性验收）。
 *
 * 档位边界（Build.VERSION_CODES 常量编译期内联，纯 JVM 可测）：
 * - LEVEL_API23：< 26（模块 minSdk 26，此档为形状对齐保留）
 * - LEVEL_API26：[26, 34)
 * - LEVEL_API34：[34, 35)
 * - LEVEL_API35：>= 35
 */
@RunWith(Parameterized.class)
public class ConnectionCompatTest {

    private final int mSdkInt;
    private final int mExpectedLevel;

    public ConnectionCompatTest(int sdkInt, int expectedLevel) {
        mSdkInt = sdkInt;
        mExpectedLevel = expectedLevel;
    }

    @Parameterized.Parameters(name = "sdkInt={0} -> level {1}")
    public static Collection<Object[]> data() {
        return Arrays.asList(new Object[][]{
                // API 23 档（25 及以下；22 为防御性下界样本）
                {22, ConnectionCompat.LEVEL_API23},
                {23, ConnectionCompat.LEVEL_API23},
                {25, ConnectionCompat.LEVEL_API23},
                // API 26 档上下临界（含 26 本值，33 为上界内样本）
                {26, ConnectionCompat.LEVEL_API26},
                {27, ConnectionCompat.LEVEL_API26},
                {33, ConnectionCompat.LEVEL_API26},
                // API 34 档（含 34 本值，35 之前）
                {34, ConnectionCompat.LEVEL_API34},
                // API 35 档（含 35 本值，36+ 持续高档）
                {35, ConnectionCompat.LEVEL_API35},
                {36, ConnectionCompat.LEVEL_API35},
                {37, ConnectionCompat.LEVEL_API35},
        });
    }

    @Test
    public void pickLevel_matchesExpectedTier() {
        assertEquals(mExpectedLevel, ConnectionCompat.pickLevel(mSdkInt));
    }
}
