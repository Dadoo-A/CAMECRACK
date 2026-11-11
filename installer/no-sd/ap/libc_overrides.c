/*
 * CAMECRACK: lighter replacements for a few musl functions, linked into the "flash"
 * hostapd only. In a static link, defining these here keeps the (bigger) libc.a
 * members out of the binary.
 *  - syslog: hostapd only uses it with -s; ap_mode.sh never passes -s.
 *  - getgrnam: only for ctrl_interface_group; this build has no control socket.
 *  - localtime/mktime -> UTC versions: avoids musl's timezone database code
 *    (TZ/zoneinfo parsing). The camera runs in UTC anyway.
 */
#include <grp.h>
#include <stdarg.h>
#include <syslog.h>
#include <time.h>

void openlog(const char *ident, int option, int facility) { }
void closelog(void) { }
void syslog(int priority, const char *format, ...) { }
void vsyslog(int priority, const char *format, va_list ap) { }

struct group *getgrnam(const char *name) { return 0; }

struct tm *localtime_r(const time_t *t, struct tm *tm) { return gmtime_r(t, tm); }
struct tm *localtime(const time_t *t) { static struct tm tm; return gmtime_r(t, &tm); }
time_t mktime(struct tm *tm) { return timegm(tm); }
