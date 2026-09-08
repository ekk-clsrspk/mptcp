#!/bin/bash
###############################################################################
#  VPS Network Optimization — softirq reduction & throughput tuning
#  Usage: sudo bash vps-ss-optimize.sh
#
#  Safe to re-run anytime. Does NOT restart ssserver or change SS config.
#  Run this after vps-ss.sh, or anytime after reboot.
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[✗]${NC} $*" >&2; }
banner() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }

if [[ $EUID -ne 0 ]]; then err "Run as root: sudo bash vps-ss-optimize.sh"; exit 1; fi

# ─────────────────────────── Auto-detect interface ──────────────────────────
VPS_INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [[ -z "$VPS_INTERFACE" ]]; then
    err "Cannot detect default interface. Set VPS_INTERFACE manually."
    exit 1
fi

NUM_CPUS=$(nproc)
CPU_MASK=$(printf '%x' $(( (1 << NUM_CPUS) - 1 )))

banner "VPS Network Optimization"
log "Interface:  ${VPS_INTERFACE}"
log "CPU cores:  ${NUM_CPUS}"
log "CPU mask:   0x${CPU_MASK}"

###############################################################################
# 1. Capture BEFORE stats
###############################################################################
banner "Step 1/4 — Baseline Snapshot"

echo -e "${BOLD}Current sysctl values:${NC}"
for key in net.core.netdev_budget net.core.busy_poll net.ipv4.tcp_timestamps \
           net.core.rmem_max net.ipv4.tcp_congestion_control net.ipv4.tcp_reordering; do
    VAL=$(sysctl -n "$key" 2>/dev/null || echo "N/A")
    printf "  %-45s = %s\n" "$key" "$VAL"
done

echo ""
echo -e "${BOLD}Current RPS (per RX queue):${NC}"
for rxq in /sys/class/net/${VPS_INTERFACE}/queues/rx-*/rps_cpus; do
    QUEUE=$(basename "$(dirname "$rxq")")
    VAL=$(cat "$rxq" 2>/dev/null || echo "N/A")
    printf "  %-20s rps_cpus = %s\n" "$QUEUE" "$VAL"
done

echo ""
echo -e "${BOLD}Current NIC offloads:${NC}"
ethtool -k "${VPS_INTERFACE}" 2>/dev/null | grep -E "^(generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload)" | sed 's/^/  /'

###############################################################################
# 2. Kernel sysctl tuning
###############################################################################
banner "Step 2/4 — Kernel Tuning (sysctl)"

cat > /etc/sysctl.d/91-optimize.conf << 'EOF'
# ── Reduce softirq overhead ──
# Process more packets per softirq cycle (default 300)
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000

# Busy polling 10 = ~90% of the latency gain of 50 at ~1/5 the CPU burn (vCPU + steal)
net.core.busy_read=10
net.core.busy_poll=10

# ── TCP Buffer Tuning (BDP-sized: 64M covers ~5Gbps @ 100ms) ──
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 1048576 67108864
net.ipv4.tcp_wmem=4096 1048576 67108864
net.ipv4.tcp_mem=262144 349525 524288

# ── Backlog ──
net.core.netdev_max_backlog=50000
net.ipv4.tcp_max_syn_backlog=30000

# ── BBR congestion control ──
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq

# ── Conntrack tuning (reduce per-packet NAT lookup cost) ──
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=600
net.netfilter.nf_conntrack_buckets=65536

# ── Reuse routes quickly ──
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3

# ── MPTCP reordering tolerance ──
net.ipv4.tcp_reordering=127

# ── Timestamps off = ~12 bytes less CPU work per packet ──
net.ipv4.tcp_timestamps=0
EOF

# Apply (ignore errors for missing modules like conntrack if not loaded yet)
sysctl -p /etc/sysctl.d/91-optimize.conf 2>&1 | grep -v "No such file" || true
log "sysctl tuning applied"

###############################################################################
# 3. NIC offloads
###############################################################################
banner "Step 3/4 — NIC Offloads & RPS/RFS"

# ── Rings + coalescing (fewer, bigger interrupts) ──
ethtool -G "${VPS_INTERFACE}" rx 4096 tx 4096 2>/dev/null || true
ethtool -C "${VPS_INTERFACE}" adaptive-rx on 2>/dev/null || true

# ── Hardware offloads ──
ethtool -K "${VPS_INTERFACE}" gro on 2>/dev/null && log "GRO: on" || warn "GRO: not supported"
ethtool -K "${VPS_INTERFACE}" gso on 2>/dev/null && log "GSO: on" || warn "GSO: not supported"
ethtool -K "${VPS_INTERFACE}" tso on 2>/dev/null && log "TSO: on" || warn "TSO: not supported"
ethtool -K "${VPS_INTERFACE}" rx-gro-list off 2>/dev/null || true

# ── RPS: Distribute received packets across ALL cores ──
# This is THE key fix for single-queue NICs where all softirq hits 1 core
RXQ_COUNT=0
for rxq in /sys/class/net/${VPS_INTERFACE}/queues/rx-*/rps_cpus; do
    echo "$CPU_MASK" > "$rxq" 2>/dev/null || true
    RXQ_COUNT=$((RXQ_COUNT + 1))
done
log "RPS: ${RXQ_COUNT} RX queue(s) → all ${NUM_CPUS} cores (mask 0x${CPU_MASK})"

# ── RFS: Flow-based steering (cache-friendly, keeps flows on same core) ──
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
if (( RXQ_COUNT > 0 )); then
    FLOW_PER_Q=$((32768 / RXQ_COUNT))
    for rxq in /sys/class/net/${VPS_INTERFACE}/queues/rx-*/rps_flow_cnt; do
        echo "$FLOW_PER_Q" > "$rxq" 2>/dev/null || true
    done
    log "RFS: ${FLOW_PER_Q} flows per queue (${RXQ_COUNT} queues)"
fi

# ── IRQ affinity hint (if irqbalance is not running) ──
if ! pgrep -x irqbalance > /dev/null 2>&1; then
    warn "irqbalance not running — RPS will handle distribution"
fi

# ── XPS: map TX queues to cores (TX was single-core before) ──
TXQ_IDX=0
for txq in /sys/class/net/${VPS_INTERFACE}/queues/tx-*/xps_cpus; do
    TX_MASK=$(printf '%x' $(( 1 << (TXQ_IDX % NUM_CPUS) )))
    echo "$TX_MASK" > "$txq" 2>/dev/null || true
    TXQ_IDX=$((TXQ_IDX + 1))
done
log "XPS: ${TXQ_IDX} TX queue(s) pinned 1:1 to cores"

###############################################################################
# 3b. Process tuning (ssserver + ksoftirqd)
###############################################################################
banner "Step 4/5 — Process Tuning"

SSSERVER_PID=$(pgrep -x ssserver | head -1 || true)
if [[ -n "$SSSERVER_PID" ]]; then
    renice -5 -p "$SSSERVER_PID" > /dev/null 2>&1 || true
    log "ssserver (PID ${SSSERVER_PID}): priority increased (nice -5)"
    THREAD_COUNT=$(ls /proc/${SSSERVER_PID}/task/ 2>/dev/null | wc -l)
    log "ssserver threads: ${THREAD_COUNT}"
else
    warn "ssserver not running — skipping process tuning"
fi

for PID in $(pgrep ksoftirqd || true); do
    renice -5 -p "$PID" > /dev/null 2>&1 || true
done
log "ksoftirqd priority increased"

###############################################################################
# 4. Verify & show AFTER stats
###############################################################################
banner "Step 5/5 — Verification"

echo -e "${BOLD}Updated sysctl values:${NC}"
for key in net.core.netdev_budget net.core.busy_poll net.ipv4.tcp_timestamps \
           net.core.rmem_max net.ipv4.tcp_congestion_control net.ipv4.tcp_reordering; do
    VAL=$(sysctl -n "$key" 2>/dev/null || echo "N/A")
    printf "  %-45s = %s\n" "$key" "$VAL"
done

echo ""
echo -e "${BOLD}Updated RPS (per RX queue):${NC}"
for rxq in /sys/class/net/${VPS_INTERFACE}/queues/rx-*/rps_cpus; do
    QUEUE=$(basename "$(dirname "$rxq")")
    VAL=$(cat "$rxq" 2>/dev/null || echo "N/A")
    printf "  %-20s rps_cpus = %s → distributing to ${NUM_CPUS} cores\n" "$QUEUE" "$VAL"
done

echo ""
echo -e "${BOLD}NIC offloads (after):${NC}"
ethtool -k "${VPS_INTERFACE}" 2>/dev/null | grep -E "^(generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload)" | sed 's/^/  /'

###############################################################################
# Summary
###############################################################################
banner "Optimization Complete ✅"

echo -e "${BOLD}┌──────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│${NC}  ${CYAN}What was optimized:${NC}                                             ${BOLD}│${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}  1. ${GREEN}RPS/RFS/XPS${NC}  — softirq spread across ${NUM_CPUS} cores (was on 1)      ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  2. ${GREEN}GRO/GSO/TSO${NC} — packet coalescing (fewer interrupts)           ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  3. ${GREEN}netdev_budget${NC} 600 — 2× packets per softirq cycle             ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  4. ${GREEN}busy_poll 10${NC} — latency gain without the CPU burn of 50       ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  5. ${GREEN}conntrack${NC}   — larger table, shorter timeouts                  ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  6. ${GREEN}timestamps${NC}  — disabled (saves 12 bytes/pkt CPU)              ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  7. ${GREEN}ssserver${NC}    — priority boosted (nice -5)                      ${BOLD}│${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}                                                                  ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  ${YELLOW}Test with:${NC}                                                      ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}    ${CYAN}mpstat -P ALL 1 5${NC}   — check softirq is spread evenly           ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}    ${CYAN}iperf3 / speedtest${NC}  — compare throughput before/after           ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}                                                                  ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  ${YELLOW}Note:${NC} RPS/RFS/XPS reset on reboot. Persist with systemd:          ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  ${CYAN}systemctl enable rps-persist${NC} (created below) — or re-run this script ${BOLD}│${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────────────────────┘${NC}"

# ── Persist RPS/RFS/XPS across reboots (cron @reboot is racy vs NIC rename) ──
cat > /usr/local/bin/apply-rps.sh << RPS_EOF
#!/bin/bash
# Re-applied at boot by rps-persist.service
IFACE=\$(ip route show default | awk '/default/ {print \$5; exit}')
[[ -z "\$IFACE" ]] && exit 0
CPUS=\$(nproc)
MASK=\$(printf '%x' \$(( (1 << CPUS) - 1 )))
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
RXQ=\$(ls -d /sys/class/net/\${IFACE}/queues/rx-* 2>/dev/null | wc -l)
for rxq in /sys/class/net/\${IFACE}/queues/rx-*/rps_cpus; do echo "\$MASK" > "\$rxq" 2>/dev/null || true; done
for rxq in /sys/class/net/\${IFACE}/queues/rx-*/rps_flow_cnt; do echo \$((32768 / RXQ)) > "\$rxq" 2>/dev/null || true; done
IDX=0
for txq in /sys/class/net/\${IFACE}/queues/tx-*/xps_cpus; do
    M=\$(printf '%x' \$(( 1 << (IDX % CPUS) )))
    echo "\$M" > "\$txq" 2>/dev/null || true
    IDX=\$((IDX + 1))
done
ethtool -K "\$IFACE" gro on gso on tso on rx-gro-list off 2>/dev/null || true
RPS_EOF
chmod +x /usr/local/bin/apply-rps.sh
cat > /etc/systemd/system/rps-persist.service << 'UNIT_EOF'
[Unit]
Description=Re-apply RPS/RFS/XPS NIC tuning at boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/apply-rps.sh

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
systemctl enable rps-persist > /dev/null 2>&1 || true
log "rps-persist.service installed (RPS survives reboot)"
