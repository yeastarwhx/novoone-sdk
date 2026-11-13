package com.novosdk.support.lifecycle;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;

/**
 * 启动期 ContentProvider（形状面保留：由宿主 App Manifest 经
 * manifestPlaceholders 声明（自研形态 authorities
 * "${applicationId}.novosdk.lifecycle"），本 SDK 模块 manifest 不声明。
 * 生命周期跟踪实际经 Instance.init → LifecycleTracker.install 装配，
 * 本类 onCreate 为空实现，仅类名是宿主 Manifest 的编译契约，不可删。
 */
public class LifecycleTrackerInitializer extends ContentProvider {
    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection,
                        String[] selectionArgs, String sortOrder) {
        return null;
    }

    @Override
    public String getType(Uri uri) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection,
                      String[] selectionArgs) {
        return 0;
    }
}
