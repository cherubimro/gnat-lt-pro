/*  lt_dpdk_shim.c -- non-inline C wrappers over DPDK's static-inline data path.
 *
 *  WHY THIS FILE MUST EXIST
 *  ------------------------
 *  DPDK's packet loop -- rte_eth_rx_burst(), rte_eth_tx_burst() and the whole
 *  rte_pktmbuf_* family -- is `static inline` in the headers.  DPDK inlines it
 *  deliberately; that is where its performance comes from.  The consequence is
 *  that those functions export NO symbols (`nm` confirms: zero), so Ada's
 *  `Import, Convention => C` cannot reach them: there is nothing to link
 *  against.  The *setup* calls (rte_eal_init, rte_eth_dev_configure,
 *  rte_eth_*_queue_setup, rte_eth_dev_start) ARE real symbols and could be
 *  bound directly -- but the data path cannot.  Hence this translation unit:
 *  it turns the inline API into real symbols that Ada imports exactly as it
 *  already imports recvmmsg().
 *
 *  ASSURANCE (docs/ASSURANCE.md §5.1)
 *  ----------------------------------
 *  This file is inside the TCB and on the data path.  It is kept deliberately
 *  small and total so it can be reviewed line by line:
 *
 *    - mbuf lifetime NEVER escapes this file.  RX copies whole LT packets out
 *      into the caller's buffer and frees every mbuf it was handed; TX
 *      allocates, fills, transmits and frees on failure.  Ada therefore never
 *      holds a DPDK pointer and cannot leak, double-free or use-after-free one.
 *    - RX is bounded: it writes at most `max_pkts` * LT_PKT_LEN bytes, and
 *      max_pkts is clamped to LT_BURST here regardless of what the caller says.
 *    - Frames that are not ours (wrong EtherType, too short) are dropped here,
 *      so Ada receives only full-length candidate packets -- the same contract
 *      the recvmmsg path enforces with its `Len = Max_Buf_Len` check.
 *
 *  WIRE FORMAT
 *  -----------
 *      | rte_ether_hdr (14) | LT packet (1472, verbatim Lt_Wire.Packet_Buffer) |
 *                                                     total 1486 <= 1500 MTU
 *  EtherType 0x88B6 is the second IEEE "local experimental" value (0x88B5 is
 *  taken by the dpdk-chat demo, so the two can share a lab segment).  The LT
 *  packet rides raw: no IP, no UDP, no headers of our own -- the fountain code
 *  needs no addressing beyond "everyone on this segment".
 */

#include <stdint.h>
#include <string.h>
#include <stdio.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ether.h>

#define LT_PKT_LEN    1472                              /* Lt_Wire.Max_Buf_Len  */
#define LT_ETHERTYPE  0x88B6                            /* IEEE local exp. #2   */
#define LT_FRAME_LEN  (RTE_ETHER_HDR_LEN + LT_PKT_LEN)  /* 1486                 */
#define LT_BURST      64                                /* = Lt_Dpdk.Batch      */

static struct rte_mempool   *lt_pool;
static uint16_t              lt_port;
static int                   lt_ready;
static struct rte_ether_addr lt_src;
static struct rte_ether_addr lt_dst = {                 /* default: broadcast   */
    .addr_bytes = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }
};

/* Canonical ethdev bring-up: configure -> adjust -> queues -> start. */
static int lt_port_init(uint16_t port)
{
    struct rte_eth_conf conf;
    uint16_t nrx = 1024, ntx = 1024;

    memset(&conf, 0, sizeof conf);

    if (rte_eth_dev_configure(port, 1, 1, &conf) != 0)              return -1;
    if (rte_eth_dev_adjust_nb_rx_tx_desc(port, &nrx, &ntx) != 0)    return -1;
    if (rte_eth_rx_queue_setup(port, 0, nrx,
            rte_eth_dev_socket_id(port), NULL, lt_pool) < 0)        return -1;
    if (rte_eth_tx_queue_setup(port, 0, ntx,
            rte_eth_dev_socket_id(port), NULL) < 0)                 return -1;
    if (rte_eth_dev_start(port) < 0)                                return -1;

    rte_eth_promiscuous_enable(port);                   /* we filter, not the NIC */
    if (rte_eth_macaddr_get(port, &lt_src) != 0)                    return -1;
    return 0;
}

/* Give the link a bounded chance to come up.  1 = up, 0 = still down.
 *
 * Only the SENDER needs this: memif/af_packet peers connect asynchronously and
 * frames blasted at a down link are simply dropped.  A receiver must NOT call
 * it -- as the memif server it has no peer until the sender arrives, so it
 * would just stall for the full timeout before it ever starts polling.
 *
 * A down link is not fatal even for the sender: TX drops, and on a
 * fountain-coded diode a drop is indistinguishable from ordinary loss. */
int lt_dpdk_wait_link(int timeout_ms)
{
    struct rte_eth_link link;
    int waited = 0;

    if (!lt_ready)
        return 0;

    while (waited < timeout_ms) {
        memset(&link, 0, sizeof link);
        if (rte_eth_link_get_nowait(lt_port, &link) == 0 &&
            link.link_status == RTE_ETH_LINK_UP)
            return 1;
        rte_delay_ms(50);
        waited += 50;
    }
    return 0;
}

/* EAL init + first available port.  0 = ok, -1 = failed. */
int lt_dpdk_init(int argc, char **argv)
{
    uint16_t p;

    if (lt_ready)
        return 0;

    if (rte_eal_init(argc, argv) < 0) {
        fprintf(stderr, "[dpdk] rte_eal_init: %s\n", rte_strerror(rte_errno));
        return -1;
    }
    if (rte_eth_dev_count_avail() == 0) {
        fprintf(stderr, "[dpdk] no ethdev port available "
                        "(did you pass --vdev=... or bind a NIC?)\n");
        return -1;
    }

    lt_pool = rte_pktmbuf_pool_create("LT_MBUF", 8191, 256, 0,
                                      RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
    if (lt_pool == NULL) {
        fprintf(stderr, "[dpdk] mbuf pool: %s\n", rte_strerror(rte_errno));
        return -1;
    }

    lt_port = 0;
    RTE_ETH_FOREACH_DEV(p) { lt_port = p; break; }

    if (lt_port_init(lt_port) != 0) {
        fprintf(stderr, "[dpdk] port %u init failed\n", (unsigned) lt_port);
        return -1;
    }

    lt_ready = 1;
    return 0;
}

/* "aa:bb:cc:dd:ee:ff" -> destination MAC.  0 = ok, -1 = unparseable. */
int lt_dpdk_set_dst(const char *mac)
{
    struct rte_ether_addr a;

    if (mac == NULL || rte_ether_unformat_addr(mac, &a) != 0)
        return -1;
    lt_dst = a;
    return 0;
}

/* Poll one burst.  Copies up to max_pkts whole LT packets, back to back, into
   `out` (which must hold max_pkts * LT_PKT_LEN bytes).  Returns the count. */
int lt_dpdk_rx_burst(unsigned char *out, int max_pkts)
{
    struct rte_mbuf *m[LT_BURST];
    uint16_t n, i;
    int k = 0;

    if (!lt_ready || out == NULL || max_pkts <= 0)
        return 0;
    if (max_pkts > LT_BURST)              /* clamp: never trust the caller's n */
        max_pkts = LT_BURST;

    n = rte_eth_rx_burst(lt_port, 0, m, (uint16_t) max_pkts);

    for (i = 0; i < n; i++) {
        const struct rte_ether_hdr *eh =
            rte_pktmbuf_mtod(m[i], const struct rte_ether_hdr *);

        if (rte_pktmbuf_data_len(m[i]) >= LT_FRAME_LEN &&
            eh->ether_type == rte_cpu_to_be_16(LT_ETHERTYPE)) {
            memcpy(out + (size_t) k * LT_PKT_LEN,
                   (const unsigned char *) eh + RTE_ETHER_HDR_LEN,
                   LT_PKT_LEN);
            k++;
        }
        rte_pktmbuf_free(m[i]);           /* every mbuf freed, on every path */
    }
    return k;
}

/* Transmit one LT packet.  1 = handed to the driver, 0 = dropped. */
int lt_dpdk_tx(const unsigned char *pkt)
{
    struct rte_mbuf *m;
    struct rte_ether_hdr *eh;
    char *p;

    if (!lt_ready || pkt == NULL)
        return 0;

    m = rte_pktmbuf_alloc(lt_pool);
    if (m == NULL)
        return 0;

    p = rte_pktmbuf_append(m, LT_FRAME_LEN);
    if (p == NULL) {
        rte_pktmbuf_free(m);
        return 0;
    }

    eh = (struct rte_ether_hdr *) p;
    rte_ether_addr_copy(&lt_dst, &eh->dst_addr);
    rte_ether_addr_copy(&lt_src, &eh->src_addr);
    eh->ether_type = rte_cpu_to_be_16(LT_ETHERTYPE);
    memcpy(p + RTE_ETHER_HDR_LEN, pkt, LT_PKT_LEN);

    if (rte_eth_tx_burst(lt_port, 0, &m, 1) == 0) {
        rte_pktmbuf_free(m);              /* driver refused it: still ours */
        return 0;
    }
    return 1;
}

void lt_dpdk_fini(void)
{
    if (!lt_ready)
        return;
    rte_eth_dev_stop(lt_port);
    rte_eth_dev_close(lt_port);
    rte_eal_cleanup();
    lt_ready = 0;
}
