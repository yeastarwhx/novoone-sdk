/*
 * config_site.h
 *
 * Yeastar/Linkus platform configuration for PJSIP 2.17 (WebRTC integration).
 *
 * NOTE: The PJSIP build system picks up <pj/config_site.h> from
 * pjlib/include/pj/config_site.h. This git-tracked copy is the canonical
 * source; keep pjlib/include/pj/config_site.h in sync (that path is
 * gitignored by upstream).
 */

/* Platform common */
#define PJ_HAS_TCP 1
/* SSL/TLS enabled by default (desktop builds find OpenSSL system-wide;
 * iOS builds use the OpenSSL cross-compiled by ios-build-openssl.sh and
 * linked via ios-build.sh --with-ssl, enabling SIP over TLS).
 * DTLS/SRTP is handled by the external WebRTC SDK in integration mode. */
#ifndef PJ_HAS_SSL_SOCK
#define PJ_HAS_SSL_SOCK 1
#endif
#ifndef PJSIP_HAS_TLS_TRANSPORT
#define PJSIP_HAS_TLS_TRANSPORT 1
#endif
#define PJ_HAS_IPV6 1

#if defined(PJ_CONFIG_IPHONE)
  /* iOS (PJ_CONFIG_IPHONE is injected via cross-compile CFLAGS) */
  #define PJ_QOS_IMPLEMENTATION PJ_QOS_BSD
  #define PJ_IPHONE_OS_HAS_MULTITASKING_SUPPORT 1
  #define PJ_ACTIVESOCK_TCP_IPHONE_OS_BG 0
#elif defined(PJ_ANDROID)
  /* Android specific (kept minimal, extend as needed) */
#else /* Linux / other desktop */
  /* Desktop verification environment: no platform specific items */
#endif

/* WebRTC mode does not use pjmedia media capability, disable video to
 * avoid the yeastar.h incompatibility warning. Video is handled by the
 * external WebRTC SDK.
 */
#define PJMEDIA_HAS_VIDEO 0
