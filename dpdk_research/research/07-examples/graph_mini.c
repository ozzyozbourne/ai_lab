/* graph_mini.c - smallest useful rte_graph: a source node emits "packets"
 * (here: integers cast to void*), a classifier routes them per object to
 * "even" or "odd" sinks. Prints stats and exports Graphviz dot.
 * run: ./graph_mini --no-huge -m 128 --no-pci --file-prefix=ch07gm  */
#include <stdio.h>
#include <rte_eal.h>
#include <rte_graph.h>
#include <rte_graph_worker.h>

static uint64_t counter;
static uint64_t seen[2];

static uint16_t gen_process(struct rte_graph *g, struct rte_node *node, void **objs, uint16_t n)
{
	(void)objs; (void)n;
	const uint16_t burst = 32;
	void **to = rte_node_next_stream_get(g, node, 0, burst);   /* edge 0 = classify */
	for (uint16_t i = 0; i < burst; i++)
		to[i] = (void *)(uintptr_t)(counter++);
	rte_node_next_stream_put(g, node, 0, burst);
	return burst;
}
static uint16_t cls_process(struct rte_graph *g, struct rte_node *node, void **objs, uint16_t n)
{
	for (uint16_t i = 0; i < n; i++)          /* per-object decision: edge 0=even, 1=odd */
		rte_node_enqueue_x1(g, node, ((uintptr_t)objs[i]) & 1, objs[i]);
	return n;
}
static uint16_t even_process(struct rte_graph *g, struct rte_node *node, void **o, uint16_t n)
{ (void)g; (void)node; (void)o; seen[0] += n; return n; }
static uint16_t odd_process(struct rte_graph *g, struct rte_node *node, void **o, uint16_t n)
{ (void)g; (void)node; (void)o; seen[1] += n; return n; }

static struct rte_node_register gen_node = { .name = "gen", .flags = RTE_NODE_SOURCE_F,
	.process = gen_process, .nb_edges = 1, .next_nodes = { "classify" } };
static struct rte_node_register cls_node = { .name = "classify", .process = cls_process,
	.nb_edges = 2, .next_nodes = { "even", "odd" } };
static struct rte_node_register even_node = { .name = "even", .process = even_process };
static struct rte_node_register odd_node = { .name = "odd", .process = odd_process };
RTE_NODE_REGISTER(gen_node);
RTE_NODE_REGISTER(cls_node);
RTE_NODE_REGISTER(even_node);
RTE_NODE_REGISTER(odd_node);

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) return 1;
	const char *patterns[] = { "gen", "classify", "even", "odd" };
	struct rte_graph_param prm = { .socket_id = SOCKET_ID_ANY,
		.nb_node_patterns = 4, .node_patterns = patterns };
	rte_graph_t id = rte_graph_create("mini", &prm);
	if (id == RTE_GRAPH_ID_INVALID) { printf("graph create failed\n"); return 1; }
	struct rte_graph *g = rte_graph_lookup("mini");
	for (int i = 0; i < 1000; i++)
		rte_graph_walk(g);                      /* one walk = visit pending nodes in topo order */
	printf("walks=1000 generated=%lu even=%lu odd=%lu\n", (unsigned long)counter,
	       (unsigned long)seen[0], (unsigned long)seen[1]);
	FILE *f = fopen("graph_mini.dot", "w");
	rte_graph_export("mini", f); fclose(f);
	const char *gp[] = { "mini" };
	struct rte_graph_cluster_stats_param sp = { .socket_id = SOCKET_ID_ANY, .fn = NULL,
		.f = stdout, .nb_graph_patterns = 1, .graph_patterns = gp };
	struct rte_graph_cluster_stats *st = rte_graph_cluster_stats_create(&sp);
	rte_graph_cluster_stats_get(st, 0);
	rte_graph_cluster_stats_destroy(st);
	rte_graph_destroy(id);
	rte_eal_cleanup();
	return 0;
}
