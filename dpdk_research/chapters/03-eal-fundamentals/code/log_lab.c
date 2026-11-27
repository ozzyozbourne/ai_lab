/* SPDX-License-Identifier: BSD-3-Clause
 *
 * log_lab.c - Chapter 3: DPDK logging from the application's side.
 *
 *   ./log_lab -l 0 --no-pci --no-huge -m 64 --file-prefix=ch03-log
 *   ./log_lab -l 0 --no-pci --no-huge -m 64 --file-prefix=ch03-log \
 *             --log-level='user.ch03*:debug'
 *
 * Shows:
 *   - registering two dynamic logtypes with RTE_LOG_REGISTER_SUFFIX
 *     ("user.ch03app" and "user.ch03app.rx")
 *   - the RTE_LOGTYPE_<NAME> naming trick that RTE_LOG / RTE_LOG_LINE need
 *   - which levels pass by default and with --log-level patterns
 *   - changing levels at run time with rte_log_set_level_pattern()
 *   - rte_log_can_log() to skip expensive formatting
 *   - redirecting all DPDK logs to a FILE* with rte_openlog_stream()
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_log.h>

/*
 * RTE_LOG_REGISTER_SUFFIX(var, suffix, level) registers the name
 *     RTE_LOG_DEFAULT_LOGTYPE "." suffix
 * Inside DPDK the build system defines RTE_LOG_DEFAULT_LOGTYPE (lib.eal,
 * pmd.net.null, ...). An application must define it itself, before use.
 * Here the prefix is "user", so the names become user.ch03app and
 * user.ch03app.rx. The registration runs as a constructor, before main().
 */
#define RTE_LOG_DEFAULT_LOGTYPE user
RTE_LOG_REGISTER_SUFFIX(app_logtype, ch03app, INFO);
RTE_LOG_REGISTER_SUFFIX(rx_logtype, ch03app.rx, WARNING);

/* RTE_LOG(l, t, ...) pastes RTE_LOGTYPE_##t, so give each type a short name.
 * The short name is also the prefix printed on each line ("APP: ..."). */
#define RTE_LOGTYPE_APP app_logtype
#define RTE_LOGTYPE_RX  rx_logtype

/* The usual app-wide wrappers. RTE_LOG_LINE adds the '\n' for you and
 * refuses (at compile time) a format string that already ends in '\n'. */
#define APP_LOG(level, ...) RTE_LOG_LINE(level, APP, __VA_ARGS__)
#define RX_LOG(level, ...)  RTE_LOG_LINE(level, RX, __VA_ARGS__)

static void
emit_all(const char *tag)
{
	printf("--- %s\n", tag);
	fflush(stdout);
	APP_LOG(ERR,     "app ERR     (level 4)");
	APP_LOG(WARNING, "app WARNING (level 5)");
	APP_LOG(NOTICE,  "app NOTICE  (level 6)");
	APP_LOG(INFO,    "app INFO    (level 7)");
	APP_LOG(DEBUG,   "app DEBUG   (level 8)");
	RX_LOG(WARNING,  "rx  WARNING (level 5)");
	RX_LOG(INFO,     "rx  INFO    (level 7)");
	RX_LOG(DEBUG,    "rx  DEBUG   (level 8)");
	fflush(stderr);
}

static uint64_t
expensive_summary(void)
{
	uint64_t s = 0;
	for (uint64_t i = 0; i < 1000000; i++)
		s += i ^ (s >> 3);
	return s;
}

int
main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	FILE *f;
	char line[256];

	if (ret < 0) {
		fprintf(stderr, "rte_eal_init failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	/* DPDK logs go to stderr (unbuffered); make stdout line-buffered so the
	 * two streams stay in order when both are piped into one file. */
	setvbuf(stdout, NULL, _IOLBF, 0);

	printf("logtype ids: user.ch03app=%d user.ch03app.rx=%d (dynamic ids)\n",
	       app_logtype, rx_logtype);
	printf("current levels: app=%d rx=%d global=%d\n",
	       rte_log_get_level(app_logtype), rte_log_get_level(rx_logtype),
	       (int)rte_log_get_global_level());

	emit_all("1. as registered (or as set by --log-level)");

	/* Change levels at run time with a glob pattern. */
	rte_log_set_level_pattern("user.ch03app*", RTE_LOG_DEBUG);
	emit_all("2. after rte_log_set_level_pattern(\"user.ch03app*\", DEBUG)");

	rte_log_set_level(rx_logtype, RTE_LOG_ERR);
	emit_all("3. after rte_log_set_level(rx, ERR)");

	/* Guard expensive work: only compute if the message would be printed. */
	printf("--- 4. rte_log_can_log guard\n");
	if (rte_log_can_log(rx_logtype, RTE_LOG_DEBUG))
		RX_LOG(DEBUG, "summary=%" PRIu64, expensive_summary());
	else
		printf("rx DEBUG is off: skipped expensive_summary()\n");
	if (rte_log_can_log(app_logtype, RTE_LOG_DEBUG))
		APP_LOG(DEBUG, "summary=%" PRIu64, expensive_summary());

	/* Redirect: every DPDK log line (EAL's too) now goes to the file. */
	printf("--- 5. rte_openlog_stream(file)\n");
	f = tmpfile();
	if (f == NULL)
		return 1;
	rte_openlog_stream(f);
	APP_LOG(NOTICE, "this line goes to the file, not stderr");
	RTE_LOG(WARNING, EAL, "even EAL lines follow the stream\n");
	rte_openlog_stream(NULL);                /* back to the default */
	APP_LOG(NOTICE, "back on the default stream");
	fflush(stderr);
	rewind(f);
	while (fgets(line, sizeof(line), f) != NULL)
		printf("file: %s", line);
	fclose(f);

	/* rte_log_list_types(out, prefix) prints EVERY dynamic type; 'prefix'
	 * is only text put in front of each name. We filter ourselves. */
	printf("--- 6. rte_log_list_types: our types and a few library types\n");
	f = tmpfile();
	if (f != NULL) {
		rte_log_list_types(f, "  ");
		rewind(f);
		while (fgets(line, sizeof(line), f) != NULL)
			if (strstr(line, "user.ch03") || strstr(line, "lib.eal") ||
			    strstr(line, "pmd.net.null"))
				printf("%s", line);
		fclose(f);
	}

	rte_eal_cleanup();
	return 0;
}
