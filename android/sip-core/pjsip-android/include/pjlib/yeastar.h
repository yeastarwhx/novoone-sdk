#ifndef  _YEASTAR_H
#define _YEASTAR_H

/**
 * @file yeastar.h
 * @brief Yeastar/Linkus specific feature macros for PJSIP
 *
 * This file contains macro definitions for enabling Yeastar/Linkus specific
 * features in PJSIP library. These macros provide compile-time control over
 * custom functionality and optimizations.
 *
 * Usage:
 *   - Define macros before compiling PJSIP to enable specific features
 *   - All macros are disabled by default for backward compatibility
 *   - Use #ifndef/#define pattern to allow external override
 *
 * This file is included unconditionally by pjsua.h (and pjsua_internal.h),
 * so the macro is automatically propagated to any compilation unit that
 * includes the PJSUA API headers.
 */

/* ========================================================================
 * WebRTC Integration Features
 * ========================================================================
 * These macros control the WebRTC integration mode for mobile applications.
 * When enabled, PJSIP acts as a SIP signaling layer only, with media
 * handled by external WebRTC SDK (e.g., libwebrtc).
 */

#ifndef PJ_ENABLE_WEBRTC_INTEGRATION
/**
 * Enable WebRTC integration mode.
 *
 * When defined as 1:
 *   - Disables PJMEDIA subsystem initialization (audio devices, codecs,
 *     conference bridge)
 *   - Enables SDP black-box passthrough (no semantic validation)
 *   - Provides application-layer WebRTC API
 *     (pjsua_call_make_call_with_sdp_str, etc.)
 *
 * When defined as 0 or undefined:
 *   - Standard PJSIP mode with full PJMEDIA support
 *   - All WebRTC-specific code is excluded from compilation
 *
 * Target platforms: iOS 13.0+, Android 7.0+, Linux
 * Tested with: PJSIP 2.17
 *
 * Example:
 *   // Enable WebRTC mode (default)
 *   #define PJ_ENABLE_WEBRTC_INTEGRATION 1
 *
 *   // Disable WebRTC mode (standard PJSIP)
 *   #define PJ_ENABLE_WEBRTC_INTEGRATION 0
 *
 * To override this default, define PJ_ENABLE_WEBRTC_INTEGRATION in your
 * build flags BEFORE including this header:
 *   CFLAGS="-DPJ_ENABLE_WEBRTC_INTEGRATION=0"  # Disable WebRTC mode
 *   CFLAGS="-DPJ_ENABLE_WEBRTC_INTEGRATION=1"  # Enable WebRTC mode
 */
#define PJ_ENABLE_WEBRTC_INTEGRATION 1
#endif

/* ========================================================================
 * Macro Validation and Warnings
 * ========================================================================
 */

#if defined(PJ_ENABLE_WEBRTC_INTEGRATION) && PJ_ENABLE_WEBRTC_INTEGRATION != 0
    /* WebRTC integration mode enabled */
    #pragma message("Compiling PJSIP in WebRTC integration mode")
    #pragma message("  - PJMEDIA subsystem will be disabled")
    #pragma message("  - SDP passthrough mode enabled")
    #pragma message("  - Application layer WebRTC APIs enabled")

    /* Validate incompatible features */
    #if defined(PJMEDIA_HAS_VIDEO) && PJMEDIA_HAS_VIDEO != 0
        #pragma message("WARNING: PJMEDIA_HAS_VIDEO should be disabled in WebRTC mode")
        #pragma message("WARNING: Media (audio/video) is handled by external WebRTC SDK")
    #endif
#else
    /* Standard PJSIP mode */
    #pragma message("Compiling PJSIP in standard mode (full PJMEDIA support)")
#endif

/* ========================================================================
 * Version Information
 * ========================================================================
 */

/**
 * YEASTAR_H version information
 * Format: Major.Minor.Patch
 */
#define YEASTAR_H_VERSION_MAJOR    1
#define YEASTAR_H_VERSION_MINOR    1
#define YEASTAR_H_VERSION_PATCH    0

/**
 * Last update date (YYYYMMDD format)
 */
#define YEASTAR_H_LAST_UPDATE      20260828

/**
 * Feature set identifier
 *   1 = WebRTC integration only
 *   (后续如移植旧工程更多特性，在此扩展取值)
 */
#define YEASTAR_H_FEATURE_SET      1

#endif /* _YEASTAR_H */
