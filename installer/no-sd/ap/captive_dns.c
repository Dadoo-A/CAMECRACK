/*
 * CAMECRACK captive-portal DNS: answer EVERY A query with one IPv4 address (the camera
 * in AP mode), so phones resolve their connectivity-check hosts to us and pop up the
 * Wi-Fi setup page. Other query types get NOERROR/no-answer (forces IPv4).
 * The camera's busybox has no dnsd, hence this ~100-line static binary.
 *
 *   captive-dns [IP] [-d]      default IP 10.1.8.1; -d = daemonize
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void die(const char *m)
{
	write(2, m, strlen(m));
	write(2, "\n", 1);
	_exit(1);
}

int main(int argc, char **argv)
{
	struct in_addr ip;
	struct sockaddr_in sa;
	unsigned char b[512 + 16];
	int s, i, daemonize = 0;
	const char *ipstr = "10.1.8.1";

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-d"))
			daemonize = 1;
		else
			ipstr = argv[i];
	}
	if (!inet_aton(ipstr, &ip))
		die("captive-dns: bad IP");

	s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0)
		die("captive-dns: socket");
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons(53);
	sa.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(s, (struct sockaddr *) &sa, sizeof(sa)) < 0)
		die("captive-dns: bind :53");
	if (daemonize && daemon(0, 0) < 0)
		die("captive-dns: daemon");

	for (;;) {
		struct sockaddr_in c;
		socklen_t cl = sizeof(c);
		int n = recvfrom(s, b, 512, 0, (struct sockaddr *) &c, &cl);
		int p, qtype, qclass, opcode;

		if (n < 12 || (b[2] & 0x80))	/* too short, or a response */
			continue;
		if (b[4] != 0 || b[5] != 1)	/* exactly one question */
			continue;
		/* walk QNAME (plain labels only; compression never appears in a query) */
		for (p = 12; p < n && b[p]; p += b[p] + 1)
			if (b[p] & 0xc0)
				break;
		if (p >= n || b[p] != 0 || p + 5 > n)
			continue;
		p++;
		qtype = (b[p] << 8) | b[p + 1];
		qclass = (b[p + 2] << 8) | b[p + 3];
		p += 4;

		opcode = (b[2] >> 3) & 0x0f;
		b[2] = 0x80 | (b[2] & 0x79) | 0x04;	/* QR, keep opcode+RD, AA */
		b[3] = 0x80 | (opcode ? 4 : 0);		/* RA; NOTIMP for non-QUERY */
		b[6] = b[7] = 0;			/* ANCOUNT */
		b[8] = b[9] = b[10] = b[11] = 0;	/* NSCOUNT, ARCOUNT (drop EDNS) */
		n = p;					/* keep header + question only */

		if (!opcode && qtype == 1 && qclass == 1) {
			static const unsigned char rr[12] = {
				0xc0, 0x0c,		/* name: pointer to question */
				0x00, 0x01, 0x00, 0x01,	/* type A, class IN */
				0x00, 0x00, 0x00, 0x3c,	/* TTL 60 s */
				0x00, 0x04		/* RDLENGTH */
			};
			memcpy(b + n, rr, sizeof(rr));
			memcpy(b + n + sizeof(rr), &ip.s_addr, 4);
			n += sizeof(rr) + 4;
			b[7] = 1;
		}
		sendto(s, b, n, 0, (struct sockaddr *) &c, cl);
	}
}
