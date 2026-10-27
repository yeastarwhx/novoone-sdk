/*
 * Copyright (C) 2008-2011 Teluu Inc. (http://www.teluu.com)
 * Copyright (C) 2003-2008 Benny Prijono <benny@prijono.org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */
#ifndef __PJSUA_WEBRTC_H__
#define __PJSUA_WEBRTC_H__

/**
 * @file pjsua_webrtc.h
 * @brief PJSUA WebRTC Integration API
 */

#include <pjsua-lib/pjsua.h>

/* Defensive re-include of the feature macros (pjsua.h already pulls it in;
 * the header is guarded so multiple inclusion is safe).
 */
#include <yeastar.h>

#if defined(PJ_ENABLE_WEBRTC_INTEGRATION) && PJ_ENABLE_WEBRTC_INTEGRATION != 0

/**
 * @defgroup PJSUA_WEBRTC WebRTC Integration
 * @ingroup PJSUA_LIB
 * @brief WebRTC integration mode APIs for SDP passthrough
 * @{
 *
 * This module provides APIs for integrating PJSIP with external WebRTC media layer.
 * In this mode, PJSIP handles only SIP signaling, while media negotiation is delegated
 * to the application layer via SDP passthrough.
 *
 * Key features:
 * - SDP passthrough (black-box, no semantic validation)
 * - Outgoing calls with custom SDP
 * - Incoming call SDP extraction
 * - Call answering with custom SDP
 * - Callback notifications for SDP events
 *
 * Callback lifecycle contract (important):
 * - The \a remote_sdp string passed to the #on_incoming_call_sdp,
 *   #on_call_answer_sdp and #on_call_reinvite_sdp callbacks points to a
 *   temporary buffer (incoming rdata body or a stack buffer) that is ONLY
 *   valid for the duration of the callback. The application MUST copy the
 *   SDP (e.g. with pj_strdup() into its own pool) before returning if it
 *   needs to use it later.
 * - All callbacks are invoked on the PJSIP worker thread. Do not block.
 *
 * Architecture principle: Modular Design - PJSIP signaling layer
 * communicates with application/WebRTC media layer through SDP passthrough interface
 * and callback mechanisms, maintaining complete decoupling.
 */

PJ_BEGIN_DECL

/**
 * @defgroup PJSUA_WEBRTC_CALL Call Management with SDP Passthrough
 * @ingroup PJSUA_WEBRTC
 * @{
 */

/**
 * Make outgoing call with custom SDP offer.
 *
 * This function initiates a call using application-provided SDP instead of
 * PJSIP-generated SDP. The SDP is treated as an opaque string and passed
 * directly to the remote peer via SIP INVITE.
 *
 * @param acc_id        Account ID to use for the call.
 * @param dst_uri       Destination SIP URI (e.g., "sip:bob@example.com").
 * @param local_sdp     Application-generated SDP offer as null-terminated string.
 *                      MUST contain valid SDP with WebRTC media capabilities
 *                      (codecs, ICE candidates, DTLS fingerprints, etc.).
 *                      PJSIP does NOT validate or modify this content.
 * @param opt           Optional call settings (NULL for defaults).
 * @param user_data     Optional user data to be attached to the call.
 * @param msg_data      Optional custom headers/content for INVITE message.
 * @param p_call_id     Pointer to receive the call ID on success.
 *
 * @return              PJ_SUCCESS on success, or appropriate error code.
 *                      - PJ_EINVAL: Invalid parameters (NULL dst_uri or local_sdp)
 *                      - PJ_ETOOMANY: Maximum concurrent calls reached
 *                      - PJ_EINVALIDOP: Account is not valid, or pjsua has not
 *                        been initialized (call array not allocated yet)
 *
 * Example:
 * @code
 *   pjsua_call_id call_id;
 *   const char *sdp = "v=0\r\no=- 123456 2 IN IP4 192.168.1.100\r\n...";
 *   pj_str_t sdp_str = pj_str((char*)sdp);
 *   pj_status_t status = pjsua_call_make_call_with_sdp_str(
 *       acc_id,
 *       &dst_uri,
 *       &sdp_str,
 *       NULL, NULL, NULL,
 *       &call_id
 *   );
 * @endcode
 *
 * Threading: May be called from any thread. Callback on_call_state will be
 * triggered on PJSIP worker thread (application must transfer to main thread
 * for UI updates).
 */
PJ_DECL(pj_status_t) pjsua_call_make_call_with_sdp_str(pjsua_acc_id acc_id,
                                                        const pj_str_t *dst_uri,
                                                        const pj_str_t *local_sdp,
                                                        const pjsua_call_setting *opt,
                                                        void *user_data,
                                                        const pjsua_msg_data *msg_data,
                                                        pjsua_call_id *p_call_id);

/**
 * Answer incoming call with custom SDP.
 *
 * This function answers an incoming call using application-provided SDP answer
 * instead of PJSIP-generated SDP. The SDP is treated as an opaque string and
 * passed directly to the remote peer via 200 OK response.
 *
 * @param call_id       The call ID to answer.
 * @param code          Status code for the response (usually 200 for OK).
 * @param local_sdp     Application-generated SDP answer as null-terminated string.
 *                      MUST be a valid SDP answer matching the remote offer.
 * @param opt           Optional call settings (NULL for defaults).
 * @param msg_data      Optional custom headers for 200 OK response.
 *
 * @return              PJ_SUCCESS on success, or appropriate error code.
 *                      - PJ_EINVAL: Invalid call_id or NULL local_sdp
 *                      - PJ_EINVALIDOP: Call is already disconnected or the
 *                        invite session state does not allow answering
 *
 * Example:
 * @code
 *   const char *answer_sdp = "v=0\r\no=- 654321 2 IN IP4 192.168.1.200\r\n...";
 *   pj_str_t sdp_str = pj_str((char*)answer_sdp);
 *   pj_status_t status = pjsua_call_answer_with_sdp_str(
 *       call_id,
 *       200,
 *       &sdp_str,
 *       NULL,
 *       NULL
 *   );
 * @endcode
 *
 * Threading: May be called from any thread.
 */
PJ_DECL(pj_status_t) pjsua_call_answer_with_sdp_str(pjsua_call_id call_id,
                                                     unsigned code,
                                                     const pj_str_t *local_sdp,
                                                     const pjsua_call_setting *opt,
                                                     const pjsua_msg_data *msg_data);

/**
 * Send re-INVITE with custom SDP to renegotiate media.
 *
 * This function sends a re-INVITE request during an established call to
 * renegotiate media parameters. This is used when the WebRTC media layer
 * needs to change media configuration (e.g. add/remove video track,
 * update ICE candidates after network change, modify codec parameters).
 *
 * The function uses application-provided SDP as an opaque string without
 * validation or modification, following the same black-box SDP passthrough
 * principle as the initial INVITE.
 *
 * @param call_id       The call ID of the established call.
 * @param local_sdp     Application-generated SDP offer as null-terminated string.
 *                      MUST contain valid SDP with updated media capabilities.
 *                      PJSIP does NOT validate or modify this content.
 * @param opt           Optional call settings (NULL for defaults).
 * @param msg_data      Optional custom headers for re-INVITE message.
 *
 * @return              PJ_SUCCESS on success, or appropriate error code.
 *                      - PJ_EINVAL: Invalid call_id or NULL local_sdp
 *                      - PJ_EINVALIDOP: Call is not in CONFIRMED state
 *
 * Example:
 * @code
 *   // Renegotiate media after adding video track
 *   const char *updated_sdp = "v=0\r\no=- 123456 3 IN IP4 192.168.1.100\r\n...";
 *   pj_str_t sdp_str = pj_str((char*)updated_sdp);
 *   pj_status_t status = pjsua_call_reinvite_with_sdp_str(
 *       call_id,
 *       &sdp_str,
 *       NULL,
 *       NULL
 *   );
 *   if (status == PJ_SUCCESS) {
 *       // Wait for on_call_answer_sdp callback with remote answer
 *   }
 * @endcode
 *
 * Use cases:
 * - Add/remove video during audio-only call
 * - Update ICE candidates after IP address change
 * - Modify codec parameters or media direction (sendonly/recvonly/inactive)
 *
 * Threading: May be called from any thread. The on_call_answer_sdp callback
 * will be triggered on PJSIP worker thread when the remote answers.
 *
 * @see on_call_reinvite_sdp callback for receiving remote re-INVITE offers
 */
PJ_DECL(pj_status_t) pjsua_call_reinvite_with_sdp_str(pjsua_call_id call_id,
                                                       const pj_str_t *local_sdp,
                                                       const pjsua_call_setting *opt,
                                                       const pjsua_msg_data *msg_data);

/**
 * @}
 * PJSUA_WEBRTC_CALL
 */

/**
 * @defgroup PJSUA_WEBRTC_UTILS Utility Functions
 * @ingroup PJSUA_WEBRTC
 * @{
 */

/**
 * @}
 * PJSUA_WEBRTC_UTILS
 */

/**
 * @}
 * PJSUA_WEBRTC
 */

PJ_END_DECL

#endif /* PJ_ENABLE_WEBRTC_INTEGRATION */

#endif  /* __PJSUA_WEBRTC_H__ */
