/* Asymmetric cryptodev: modular exponentiation (the core of RSA/DH) on crypto_openssl.
 * Computes base^exp mod n with big-endian byte arrays; check with python3 -c 'print(hex(pow(b,e,n)))'.
 * Run: ./crypto_asym_modexp --no-huge -m 256 --no-pci --file-prefix=ch08x --vdev=crypto_openssl0 */
#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_cryptodev.h>
#include <rte_crypto_asym.h>

/* NOTE rte_crypto_uint is {data, iova, length}: always use designated initialisers! */
static uint8_t mod[] = { 0xC3, 0x51, 0x7F, 0x11, 0x9A, 0x2B, 0x44, 0xE5, 0x01, 0x6D, 0x8E, 0x3F, 0x77, 0x90, 0xAB, 0xCD }; /* odd modulus */
static uint8_t exp_[] = { 0x01, 0x00, 0x01 }; /* 65537 */
static uint8_t base[] = { 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) rte_exit(1, "eal\n");
	int dev = rte_cryptodev_get_dev_id("crypto_openssl0");
	struct rte_cryptodev_info info; rte_cryptodev_info_get(dev, &info);
	if (!(info.feature_flags & RTE_CRYPTODEV_FF_ASYMMETRIC_CRYPTO)) rte_exit(1, "no asym\n");
	const struct rte_cryptodev_asymmetric_xform_capability *cap =
		rte_cryptodev_asym_capability_get(dev, &(struct rte_cryptodev_asym_capability_idx){ .type = RTE_CRYPTO_ASYM_XFORM_MODEX });
	printf("MODEX capability: %s, modlen %u..%u\n", cap ? "yes" : "no", cap ? cap->modlen.min : 0, cap ? cap->modlen.max : 0);

	struct rte_cryptodev_config cfg = { .socket_id = rte_socket_id(), .nb_queue_pairs = 1 };
	rte_cryptodev_configure(dev, &cfg);
	struct rte_cryptodev_qp_conf qp = { .nb_descriptors = 64 };
	rte_cryptodev_queue_pair_setup(dev, 0, &qp, rte_socket_id());
	rte_cryptodev_start(dev);

	struct rte_mempool *smp = rte_cryptodev_asym_session_pool_create("asess", 4, 0, 0, rte_socket_id());
	struct rte_mempool *opmp = rte_crypto_op_pool_create("aops", RTE_CRYPTO_OP_TYPE_ASYMMETRIC, 16, 0, 0, rte_socket_id());
	struct rte_crypto_asym_xform x = { .xform_type = RTE_CRYPTO_ASYM_XFORM_MODEX,
		.modex = { .modulus = { .data = mod, .length = sizeof(mod) }, .exponent = { .data = exp_, .length = sizeof(exp_) } } };
	void *sess = NULL;
	if (rte_cryptodev_asym_session_create(dev, &x, smp, &sess)) rte_exit(1, "asym session\n");

	uint8_t result[sizeof(mod)] = {0};
	struct rte_crypto_op *op = rte_crypto_op_alloc(opmp, RTE_CRYPTO_OP_TYPE_ASYMMETRIC), *out;
	rte_crypto_op_attach_asym_session(op, sess);
	op->asym->modex.base = (rte_crypto_uint){ .data = base, .length = sizeof(base) };
	op->asym->modex.result = (rte_crypto_uint){ .data = result, .length = sizeof(result) };
	rte_cryptodev_enqueue_burst(dev, 0, &op, 1);
	while (!rte_cryptodev_dequeue_burst(dev, 0, &out, 1));
	printf("status=%d result(len %zu)=0x", out->status, out->asym->modex.result.length);
	for (size_t i = 0; i < out->asym->modex.result.length; i++) printf("%02x", out->asym->modex.result.data[i]);
	printf("\n");
	rte_crypto_op_free(out);
	rte_cryptodev_asym_session_free(dev, sess);
	rte_cryptodev_stop(dev); rte_cryptodev_close(dev); rte_eal_cleanup();
	return 0;
}
