/* AES-128-CBC encrypt + HMAC-SHA256 generate (chained xforms) on crypto_openssl.
 * Run: ./crypto_aes_cbc_sha --no-huge -m 256 --no-pci --file-prefix=ch08c --vdev=crypto_openssl0 */
#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_mbuf.h>
#include <rte_cryptodev.h>
#include <rte_crypto.h>

#define IV_OFF (sizeof(struct rte_crypto_op) + sizeof(struct rte_crypto_sym_op))
static uint8_t key[16] = "0123456789abcdef";
static uint8_t hkey[32] = "hmac-key-hmac-key-hmac-key-12345";
static uint8_t iv[16] = "IVIVIVIVIVIVIVIV";

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) rte_exit(1, "eal\n");
	int dev = rte_cryptodev_get_dev_id("crypto_openssl0");
	if (dev < 0) rte_exit(1, "no crypto_openssl0 vdev\n");
	struct rte_cryptodev_info info; rte_cryptodev_info_get(dev, &info);
	printf("dev %d driver=%s max_qp=%u ff=0x%" PRIx64 "\n", dev, info.driver_name,
	       info.max_nb_queue_pairs, info.feature_flags);

	struct rte_cryptodev_config cfg = { .socket_id = rte_socket_id(), .nb_queue_pairs = 1 };
	if (rte_cryptodev_configure(dev, &cfg)) rte_exit(1, "configure\n");
	unsigned sz = rte_cryptodev_sym_get_private_session_size(dev);
	struct rte_mempool *sess_mp = rte_cryptodev_sym_session_pool_create("sess", 16, sz, 0, 0, rte_socket_id());
	struct rte_cryptodev_qp_conf qp = { .nb_descriptors = 128, .mp_session = sess_mp };
	if (rte_cryptodev_queue_pair_setup(dev, 0, &qp, rte_socket_id())) rte_exit(1, "qp\n");
	if (rte_cryptodev_start(dev)) rte_exit(1, "start\n");

	struct rte_mempool *mb = rte_pktmbuf_pool_create("mb", 64, 0, 0, 2048, rte_socket_id());
	struct rte_mempool *opmp = rte_crypto_op_pool_create("ops", RTE_CRYPTO_OP_TYPE_SYMMETRIC,
		64, 0, 16 /* priv for IV */, rte_socket_id());

	/* chain: cipher -> auth */
	struct rte_crypto_sym_xform auth = { .type = RTE_CRYPTO_SYM_XFORM_AUTH,
		.auth = { .op = RTE_CRYPTO_AUTH_OP_GENERATE, .algo = RTE_CRYPTO_AUTH_SHA256_HMAC,
			  .key = { .data = hkey, .length = 32 }, .digest_length = 32 } };
	struct rte_crypto_sym_xform ciph = { .type = RTE_CRYPTO_SYM_XFORM_CIPHER, .next = &auth,
		.cipher = { .op = RTE_CRYPTO_CIPHER_OP_ENCRYPT, .algo = RTE_CRYPTO_CIPHER_AES_CBC,
			    .key = { .data = key, .length = 16 }, .iv = { .offset = IV_OFF, .length = 16 } } };
	void *sess = rte_cryptodev_sym_session_create(dev, &ciph, sess_mp);
	if (!sess) rte_exit(1, "session\n");

	struct rte_mbuf *m = rte_pktmbuf_alloc(mb);
	const char *msg = "DPDK cryptodev says hello!!!!!!!"; /* 32 bytes, multiple of 16 */
	char *p = rte_pktmbuf_append(m, 32 + 32);  /* payload + room for digest */
	memcpy(p, msg, 32);

	struct rte_crypto_op *op = rte_crypto_op_alloc(opmp, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
	memcpy(rte_crypto_op_ctod_offset(op, uint8_t *, IV_OFF), iv, 16);
	rte_crypto_op_attach_sym_session(op, sess);
	op->sym->m_src = m;
	op->sym->cipher.data.offset = 0; op->sym->cipher.data.length = 32;
	op->sym->auth.data.offset = 0;   op->sym->auth.data.length = 32; /* encrypt-then-MAC over ciphertext */
	op->sym->auth.digest.data = rte_pktmbuf_mtod_offset(m, uint8_t *, 32);
	op->sym->auth.digest.phys_addr = rte_pktmbuf_iova_offset(m, 32);

	uint16_t n = rte_cryptodev_enqueue_burst(dev, 0, &op, 1);
	struct rte_crypto_op *out = NULL; int spins = 0;
	while (rte_cryptodev_dequeue_burst(dev, 0, &out, 1) == 0) spins++;
	printf("enq=%u status=%d (0=SUCCESS) polls=%d\n", n, out->status, spins);
	uint8_t *d = rte_pktmbuf_mtod(m, uint8_t *);
	printf("ciphertext: "); for (int i = 0; i < 32; i++) printf("%02x", d[i]); printf("\n");
	printf("hmac:       "); for (int i = 32; i < 64; i++) printf("%02x", d[i]); printf("\n");

	struct rte_cryptodev_stats st; rte_cryptodev_stats_get(dev, &st);
	printf("stats enq=%" PRIu64 " deq=%" PRIu64 "\n", st.enqueued_count, st.dequeued_count);
	rte_crypto_op_free(out); rte_pktmbuf_free(m);
	rte_cryptodev_sym_session_free(dev, sess);
	rte_cryptodev_stop(dev); rte_cryptodev_close(dev);
	rte_eal_cleanup();
	return 0;
}
