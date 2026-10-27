# pjsip_jni - ys_pjsua_app (C) <-> Java 桥模块（novoone-app :sip-core）
#
# 静态链入 Makefile.copy 交付的 17 个 pjsip arm64 静态库
# （WebRTC 集成模式，宏开），与本模块的 JNI 入口 + ys_pjsua_app.cpp
# 信令封装打包成单个 libpjsip_jni.so。不链 pjsua2 / audiodev /
# videodev / pjsdp（未被引用的对象由链接器自动裁剪）。
#
# 移植自 novoone-sip-demo/app/src/main/cpp/CMakeLists.txt，差异：
#   - 交付目录相对路径由 demo 根（4 级）改为 sip-core 模块根（3 级）
#   - 其余（依赖序 / 编译宏 / 链接库）保持一致

cmake_minimum_required(VERSION 3.22)
project(pjsip_jni LANGUAGES C CXX)

# ------------------------------------------------------------------ #
# 交付目录（Makefile.copy 产物）：cpp -> main -> src -> sip-core 根
# ------------------------------------------------------------------ #
get_filename_component(MODULE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(PJSIP_DIR "${MODULE_ROOT}/pjsip-android")
set(PJSIP_LIB_DIR "${PJSIP_DIR}/lib")
set(PJSIP_INC_DIR "${PJSIP_DIR}/include")

if(NOT EXISTS "${PJSIP_LIB_DIR}/libpjsua-aarch64-unknown-linux-android.a")
    message(FATAL_ERROR
        "pjsip 交付库缺失：${PJSIP_LIB_DIR}。请先在 novoone-app-sip 仓库根执行 "
        "make -f Makefile.copy copy-all DEST_DIR=${PJSIP_DIR} "
        "ANDROID_ABI=aarch64-unknown-linux-android")
endif()

# ------------------------------------------------------------------ #
# 17 个 IMPORTED 静态库（严格依赖序：被依赖者排后）
# ------------------------------------------------------------------ #
# AGP 传入的 ANDROID_ABI=arm64-v8a 对应 pjproject 目标三元组后缀
if("${ANDROID_ABI}" STREQUAL "arm64-v8a")
    set(PJ_TRIPLET "aarch64-unknown-linux-android")
else()
    message(FATAL_ERROR "不支持的 ABI：${ANDROID_ABI}（仅 arm64-v8a）")
endif()

set(PJ_STATIC_LIBS
    pjsua
    pjsip-ua
    pjsip-simple
    pjsip
    pjmedia-codec
    pjmedia
    pjnath
    pjlib-util
    pj
    g7221codec
    gsmcodec
    ilbccodec
    resample
    speex
    srtp
    webrtc
    yuv
)

foreach(_lib ${PJ_STATIC_LIBS})
    add_library(pjsip_${_lib} STATIC IMPORTED)
    set_target_properties(pjsip_${_lib} PROPERTIES
        IMPORTED_LOCATION
        "${PJSIP_LIB_DIR}/lib${_lib}-${PJ_TRIPLET}.a")
    list(APPEND PJ_LINK_LIBS pjsip_${_lib})
endforeach()

# OpenSSL（TLS 信令传输）：交付于 pjsip-android/openssl/，链接序在 pjsip
# 各库之后（pjlib ssl_sock / pjsip tls transport 引用其符号）
set(OPENSSL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../pjsip-android/openssl")
add_library(openssl_ssl STATIC IMPORTED)
set_target_properties(openssl_ssl PROPERTIES
    IMPORTED_LOCATION "${OPENSSL_DIR}/lib/libssl.a")
add_library(openssl_crypto STATIC IMPORTED)
set_target_properties(openssl_crypto PROPERTIES
    IMPORTED_LOCATION "${OPENSSL_DIR}/lib/libcrypto.a")

# ------------------------------------------------------------------ #
# JNI 桥模块（C 桥 + ys_pjsua_app.cpp 信令封装）
# ------------------------------------------------------------------ #
add_library(pjsip_jni SHARED
    pjsip_jni.c
    ys_pjsua_app.cpp
)

target_include_directories(pjsip_jni PRIVATE
    ${PJSIP_INC_DIR}/pjlib
    ${PJSIP_INC_DIR}/pjlib-util
    ${PJSIP_INC_DIR}/pjnath
    ${PJSIP_INC_DIR}/pjmedia
    ${PJSIP_INC_DIR}/pjsip
)

# 与库构建（configure-android）完全一致的编译配置：
#   PJ_AUTOCONF               -> 走交付的 pj/compat/os_auto.h（Android 配置），
#                                保证头文件侧宏与库一致（结构体布局）
#   PJ_HAS_SSL_SOCK=0 等      -> NDK 无 OpenSSL，库已禁 SSL（DTLS/SRTP 由
#                                WebRTC aar 承担），App 侧必须同值
target_compile_definitions(pjsip_jni PRIVATE
    PJ_AUTOCONF=1
    # TLS 信令传输（批次 C）：与静态库交付的宏配置一致（--with-ssl 编译），
    # ys_set_sip_transport(2) 与 TLS transport 分支依赖
    PJ_HAS_SSL_SOCK=1
    PJSIP_HAS_TLS_TRANSPORT=1
)

# mediandk：libpjmedia-codec 的 Android MediaCodec 视频编解码对象引用
# AMediaCodec_*（API 21+，minSdk 26 满足；WebRTC 模式下该对象未被调用，
# 仅为满足静态库符号解析）
target_link_libraries(pjsip_jni
    ${PJ_LINK_LIBS}
    openssl_ssl
    openssl_crypto
    log
    m
    mediandk
)

# 16KB 页对齐（Android 15+ 16KB 内核设备 / Play targetSdk 36 强制合规）：
# NDK r27 的 lld 默认 max-page-size 仍为 4096，需显式指定 16384。
# p_align 是链接期属性——pjsip/OpenSSL 静态库（.a 无 LOAD 段）无需重编，
# 仅本 so 链接时生效。NDK 升 r28+ 后此行可移除（r28 默认 16384）。
target_link_options(pjsip_jni PRIVATE "-Wl,-z,max-page-size=16384")
