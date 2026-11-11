/*
 * CAMECRACK: minimal hostapd_config_read() for the "flash" (open-AP) build.
 * Replaces hostapd/config_file.c (~13 KB of code for ~300 options) with the handful
 * of keys ap_mode.sh actually writes. Semantics copied from hostapd 2.8's
 * hostapd_config_fill() for each key. Any other key is an ERROR (never ignored), so a
 * config written for full hostapd fails loudly instead of running half-applied.
 *
 * Supported: interface driver ssid channel hw_mode(a|b|g) wmm_enabled
 *            ignore_broadcast_ssid auth_algs macaddr_acl(0) driver_params beacon_int
 *            max_num_sta dtim_period ctrl_interface(ignored: no ctrl socket in this build)
 */
#include "utils/includes.h"
#include "utils/common.h"
#include "common/ieee802_11_defs.h"
#include "drivers/driver.h"
#include "ap/ap_config.h"
#include "config_file.h"

static int set_key(struct hostapd_config *conf, struct hostapd_bss_config *bss,
		   const char *k, const char *v, int line)
{
	if (os_strcmp(k, "interface") == 0) {
		os_strlcpy(bss->iface, v, sizeof(bss->iface));
	} else if (os_strcmp(k, "driver") == 0) {
		int j;
		for (j = 0; wpa_drivers[j]; j++)
			if (os_strcmp(v, wpa_drivers[j]->name) == 0) {
				conf->driver = wpa_drivers[j];
				return 0;
			}
		wpa_printf(MSG_ERROR, "Line %d: unknown driver '%s'", line, v);
		return 1;
	} else if (os_strcmp(k, "ssid") == 0) {
		size_t len = os_strlen(v);
		if (len < 1 || len > SSID_MAX_LEN) {
			wpa_printf(MSG_ERROR, "Line %d: invalid SSID", line);
			return 1;
		}
		os_memcpy(bss->ssid.ssid, v, len);
		bss->ssid.ssid_len = len;
		bss->ssid.ssid_set = 1;
	} else if (os_strcmp(k, "channel") == 0) {
		conf->channel = atoi(v);
		if (conf->channel < 1) {	/* no ACS in this build */
			wpa_printf(MSG_ERROR, "Line %d: channel must be >0", line);
			return 1;
		}
	} else if (os_strcmp(k, "hw_mode") == 0) {
		if (os_strcmp(v, "g") == 0)
			conf->hw_mode = HOSTAPD_MODE_IEEE80211G;
		else if (os_strcmp(v, "b") == 0)
			conf->hw_mode = HOSTAPD_MODE_IEEE80211B;
		else if (os_strcmp(v, "a") == 0)
			conf->hw_mode = HOSTAPD_MODE_IEEE80211A;
		else {
			wpa_printf(MSG_ERROR, "Line %d: unknown hw_mode", line);
			return 1;
		}
	} else if (os_strcmp(k, "wmm_enabled") == 0) {
		bss->wmm_enabled = atoi(v);
	} else if (os_strcmp(k, "ignore_broadcast_ssid") == 0) {
		bss->ignore_broadcast_ssid = atoi(v);
	} else if (os_strcmp(k, "auth_algs") == 0) {
		bss->auth_algs = atoi(v);
		if (bss->auth_algs == 0) {
			wpa_printf(MSG_ERROR, "Line %d: no auth_algs", line);
			return 1;
		}
	} else if (os_strcmp(k, "macaddr_acl") == 0) {
		if (atoi(v) != 0) {		/* ACL lists not supported */
			wpa_printf(MSG_ERROR, "Line %d: only macaddr_acl=0", line);
			return 1;
		}
		bss->macaddr_acl = ACCEPT_UNLESS_DENIED;
	} else if (os_strcmp(k, "driver_params") == 0) {
		os_free(conf->driver_params);
		conf->driver_params = os_strdup(v);
	} else if (os_strcmp(k, "beacon_int") == 0) {
		conf->beacon_int = atoi(v);
	} else if (os_strcmp(k, "dtim_period") == 0) {
		bss->dtim_period = atoi(v);
	} else if (os_strcmp(k, "max_num_sta") == 0) {
		bss->max_num_sta = atoi(v);
	} else if (os_strcmp(k, "ctrl_interface") == 0) {
		/* accepted for compatibility; this build has no control socket */
	} else {
		wpa_printf(MSG_ERROR, "Line %d: unsupported item '%s' (mini_config)",
			   line, k);
		return 1;
	}
	return 0;
}

struct hostapd_config * hostapd_config_read(const char *fname)
{
	struct hostapd_config *conf;
	FILE *f;
	char buf[256], *pos;
	int line = 0, errors = 0;
	size_t i;

	f = fopen(fname, "r");
	if (f == NULL) {
		wpa_printf(MSG_ERROR, "Could not open configuration file '%s'",
			   fname);
		return NULL;
	}
	conf = hostapd_config_defaults();
	if (conf == NULL) {
		fclose(f);
		return NULL;
	}
	conf->driver = wpa_drivers[0];
	conf->last_bss = conf->bss[0];

	while (fgets(buf, sizeof(buf), f)) {
		line++;
		pos = os_strchr(buf, '\n');
		if (pos)
			*pos = '\0';
		if (buf[0] == '#' || buf[0] == '\0')
			continue;
		pos = os_strchr(buf, '=');
		if (pos == NULL) {
			wpa_printf(MSG_ERROR, "Line %d: invalid line", line);
			errors++;
			continue;
		}
		*pos++ = '\0';
		errors += set_key(conf, conf->last_bss, buf, pos, line);
	}
	fclose(f);

	for (i = 0; i < conf->num_bss; i++)
		hostapd_set_security_params(conf->bss[i], 1);
	if (hostapd_config_check(conf, 1))
		errors++;
	if (errors) {
		wpa_printf(MSG_ERROR, "%d errors in '%s'", errors, fname);
		hostapd_config_free(conf);
		return NULL;
	}
	return conf;
}
