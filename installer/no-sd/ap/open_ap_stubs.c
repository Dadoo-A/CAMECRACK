/*
 * CAMECRACK: no-op replacements for hostapd 2.8's security stack, used ONLY by the
 * "flash" build of an OPEN access point (no wpa=, no ieee8021x=, no WPS).
 *
 * Why: /etc/config on the camera is a 256 KB jffs2 with ~112 KB free. Dropping the WPA
 * authenticator, IEEE 802.1X/EAPOL, the EAP server and the internal crypto they pull in
 * is what makes hostapd fit there (xz-compressed).
 *
 * Why it is safe for an open AP (checked against the 2.8 sources):
 *  - hostapd_setup_wpa()/wpa_auth_* are only reached when conf->wpa != 0;
 *  - ieee802_1x_new_station() returns immediately when ieee8021x=0 and no WPS;
 *  - station authorization for an open BSS is done in hostapd_new_assoc_sta()
 *    (src/ap/hostapd.c: ap_sta_set_authorized) and the driver flags in
 *    ieee802_11.c — both are kept.
 * A config that enables wpa/802.1X would silently get NO security: build-hostapd.sh
 * therefore only links this file into the open-AP "flash" variant, and ap_mode.sh
 * never writes a wpa= line.
 */
#include "utils/includes.h"
#include "utils/common.h"
#include "common/defs.h"
#include "ap/hostapd.h"
#include "ap/sta_info.h"
#include "ap/ieee802_1x.h"
#include "ap/wpa_auth.h"
#include "ap/wpa_auth_glue.h"
#include "common/wpa_common.h"
#include "crypto/sha1.h"
#include "eap_server/eap_methods.h"

/* --- EAP server registry --- */
int eap_server_identity_register(void) { return 0; }
void eap_server_unregister_methods(void) { }

/* --- WPA glue (src/ap/wpa_auth_glue.c) --- */
int hostapd_setup_wpa(struct hostapd_data *hapd) { return 0; }
void hostapd_reconfig_wpa(struct hostapd_data *hapd) { }
void hostapd_deinit_wpa(struct hostapd_data *hapd) { }

/* --- IEEE 802.1X (src/ap/ieee802_1x.c) --- */
int ieee802_1x_init(struct hostapd_data *hapd) { return 0; }
void ieee802_1x_new_station(struct hostapd_data *hapd, struct sta_info *sta) { }
void ieee802_1x_free_station(struct hostapd_data *hapd, struct sta_info *sta) { }
void ieee802_1x_receive(struct hostapd_data *hapd, const u8 *sa, const u8 *buf,
			size_t len) { }
int ieee802_1x_tx_status(struct hostapd_data *hapd, struct sta_info *sta,
			 const u8 *buf, size_t len, int ack) { return 0; }
int ieee802_1x_eapol_tx_status(struct hostapd_data *hapd, struct sta_info *sta,
			       const u8 *data, int len, int ack) { return 0; }
void ieee802_1x_notify_port_enabled(struct eapol_state_machine *sm,
				    int enabled) { }
void ieee802_1x_notify_pre_auth(struct eapol_state_machine *sm, int pre_auth) { }

/* --- WPA authenticator (src/ap/wpa_auth.c, wpa_auth_ie.c) --- */
struct wpa_state_machine *
wpa_auth_sta_init(struct wpa_authenticator *wpa_auth, const u8 *addr,
		  const u8 *p2p_dev_addr) { return NULL; }
int wpa_auth_sta_associated(struct wpa_authenticator *wpa_auth,
			    struct wpa_state_machine *sm) { return 0; }
void wpa_auth_sta_no_wpa(struct wpa_state_machine *sm) { }
void wpa_auth_sta_deinit(struct wpa_state_machine *sm) { }
int wpa_auth_sm_event(struct wpa_state_machine *sm, enum wpa_event event)
{ return 0; }
void wpa_auth_set_auth_alg(struct wpa_state_machine *sm, u16 auth_alg) { }
int wpa_auth_get_pairwise(struct wpa_state_machine *sm) { return -1; }
const u8 * wpa_auth_get_pmk(struct wpa_state_machine *sm, int *len)
{ return NULL; }
const u8 * wpa_auth_get_wpa_ie(struct wpa_authenticator *wpa_auth, size_t *len)
{ *len = 0; return NULL; }
int wpa_auth_sta_ft_tk_already_set(struct wpa_state_machine *sm) { return 0; }
int wpa_auth_sta_fils_tk_already_set(struct wpa_state_machine *sm) { return 0; }
void wpa_auth_sta_local_mic_failure_report(struct wpa_state_machine *sm) { }
void wpa_auth_countermeasures_start(struct wpa_authenticator *wpa_auth) { }
void wpa_auth_reconfig_group_keys(struct wpa_authenticator *wpa_auth) { }
void wpa_remove_ptk(struct wpa_state_machine *sm) { }
void wpa_gtk_rekey(struct wpa_authenticator *wpa_auth) { }
int wpa_init_keys(struct wpa_authenticator *wpa_auth) { return 0; }
void wpa_deinit(struct wpa_authenticator *wpa_auth) { }
int wpa_validate_wpa_ie(struct wpa_authenticator *wpa_auth,
			struct wpa_state_machine *sm, int freq,
			const u8 *wpa_ie, size_t wpa_ie_len,
			const u8 *mdie, size_t mdie_len,
			const u8 *owe_dh, size_t owe_dh_len)
{ return WPA_INVALID_IE; }

/* --- src/common/wpa_common.c (config parsing helpers) --- */
int wpa_parse_cipher(const char *value) { return -1; }   /* "wpa_pairwise=" unsupported */
int wpa_select_ap_group_cipher(int wpa, int wpa_pairwise, int rsn_pairwise)
{ return WPA_CIPHER_NONE; }

/* --- src/crypto/sha1-pbkdf2.c ("wpa_passphrase=" unsupported) --- */
int pbkdf2_sha1(const char *passphrase, const u8 *ssid, size_t ssid_len,
		int iterations, u8 *buf, size_t buflen) { return -1; }
