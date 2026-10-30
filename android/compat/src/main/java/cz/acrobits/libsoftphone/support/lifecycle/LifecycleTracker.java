package cz.acrobits.libsoftphone.support.lifecycle;

import android.app.Activity;
import android.app.Application;

import java.util.ArrayList;

/**
 * Activity 生命周期追踪（Acrobits libSoftPhone SDK 兼容门面）。
 *
 * App 使用面：LifecycleTracker.getInstance().activityList.isAnyActive()
 * （来电展示仲裁：前台弹屏 / 后台横条二选一）。
 *
 * Instance.init 时经 Application.registerActivityLifecycleCallbacks 装配。
 */
public final class LifecycleTracker {

    /** Activity 列表（isAnyActive = 存在未 finishing 的 Activity） */
    public static final class ActivityList extends ArrayList<Activity> {

        public boolean isAnyActive() {
            for (int i = size() - 1; i >= 0; i--) {
                Activity a = get(i);
                if (a != null && !a.isFinishing()) {
                    return true;
                }
            }
            return false;
        }
    }

    private static volatile LifecycleTracker sInstance;

    private final ActivityList mActivityList = new ActivityList();

    private LifecycleTracker() {
    }

    public static LifecycleTracker getInstance() {
        if (sInstance == null) {
            synchronized (LifecycleTracker.class) {
                if (sInstance == null) {
                    sInstance = new LifecycleTracker();
                }
            }
        }
        return sInstance;
    }

    public ActivityList getActivityList() {
        return mActivityList;
    }

    /** Application.onCreate 装配（Instance.init 调用；重复调用幂等） */
    public static void install(Application app) {
        if (app == null) {
            return;
        }
        final LifecycleTracker tracker = getInstance();
        app.registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
            @Override
            public void onActivityStarted(Activity activity) {
                synchronized (tracker.mActivityList) {
                    if (!tracker.mActivityList.contains(activity)) {
                        tracker.mActivityList.add(activity);
                    }
                }
            }

            @Override
            public void onActivityStopped(Activity activity) {
            }

            @Override
            public void onActivityResumed(Activity activity) {
            }

            @Override
            public void onActivityPaused(Activity activity) {
            }

            @Override
            public void onActivityCreated(Activity activity, android.os.Bundle savedInstanceState) {
                synchronized (tracker.mActivityList) {
                    if (!tracker.mActivityList.contains(activity)) {
                        tracker.mActivityList.add(activity);
                    }
                }
            }

            @Override
            public void onActivityDestroyed(Activity activity) {
                synchronized (tracker.mActivityList) {
                    tracker.mActivityList.remove(activity);
                }
            }

            @Override
            public void onActivitySaveInstanceState(Activity activity, android.os.Bundle outState) {
            }
        });
    }
}
