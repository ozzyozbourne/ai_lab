#include <stdio.h>
#include <rte_eal.h>
#include <cmdline_rdline.h>
#include "cli.h"
static uint64_t counter;
void cmd_show_counter_parsed(void *r, struct cmdline *cl, void *d)
{ (void)r; (void)d; cmdline_printf(cl, "counter=%lu\n", counter); }
void cmd_add_parsed(void *r, struct cmdline *cl, void *d)
{ struct cmd_add_result *res = r; (void)d; counter += res->n; cmdline_printf(cl, "ok\n"); }
void cmd_set_mode_parsed(void *r, struct cmdline *cl, void *d)
{ struct cmd_set_mode_result *res = r; (void)d; cmdline_printf(cl, "mode=%s\n", res->m); }
void cmd_echo_parsed(void *r, struct cmdline *cl, void *d)
{ struct cmd_echo_result *res = r; (void)d; cmdline_printf(cl, "%s\n", res->msg); }
void cmd_quit_parsed(void *r, struct cmdline *cl, void *d)
{ (void)r; (void)d; cmdline_quit(cl); }
int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) return 1;
	struct cmdline *cl = cmdline_stdin_new(ctx, "demo> ");
	cmdline_interact(cl);
	cmdline_stdin_exit(cl);
	rte_eal_cleanup();
	return 0;
}
