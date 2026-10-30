# :compat 消费方混淆规则——Acrobits libSoftPhone SDK 兼容门面
#
# 宿主 App release 混淆时必须保留：
# 1. App 代码按 FQCN 反射访问的成员（ConnectionService.extractWaitingCall /
#    hasMaximumSelfManagedConnections / updateState、ConnectionServiceNative$State）
# 2. App 同包扩展的包私有类（telecom.compat.ConnectionImplApiXX）
# 3. 引擎 JNI native 方法（JniBridge）与 Acrobits 门面全量 API 面

-keep class cz.acrobits.** { *; }
-keep class com.yeastar.sipcore.** { *; }
-dontwarn cz.acrobits.**
