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

# Busy polling — reduce context switches for high-throughput
net.core.busy_read=50
net.core.busy_poll=50

# ── TCP Buffer Tuning ──
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 1048576 134217728
net.ipv4.tcp_wmem=4096 1048576 134217728
net.ipv4.tcp_mem=786432 1048576 1572864

# ── Backlog ──
net.core.netdev_max_backlog=50000
net.ipv4.tcp_max_syn_backlog=30000

# ── BBR congestion control ──
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq

# ── Conntrack tuning (reduce per-packet NAT lookup cost) ──
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=600

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

###############################################################################
# 4. Verify & show AFTER stats
###############################################################################
banner "Step 4/4 — Verification"

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
echo -e "${BOLD}│${NC}  1. ${GREEN}RPS/RFS${NC}     — softirq spread across ${NUM_CPUS} cores (was on 1)        ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  2. ${GREEN}GRO/GSO/TSO${NC} — packet coalescing (fewer interrupts)           ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  3. ${GREEN}netdev_budget${NC} 600 — 2× packets per softirq cycle             ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  4. ${GREEN}busy_poll${NC}   — skip interrupt wait on hot sockets              ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  5. ${GREEN}conntrack${NC}   — larger table, shorter timeouts                  ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  6. ${GREEN}timestamps${NC}  — disabled (saves 12 bytes/pkt CPU)              ${BOLD}│${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}                                                                  ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  ${YELLOW}Test with:${NC}                                                      ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}    ${CYAN}mpstat -P ALL 1 5${NC}   — check softirq is spread evenly           ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}    ${CYAN}iperf3 / speedtest${NC}  — compare throughput before/after           ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}                                                                  ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  ${YELLOW}Note:${NC} RPS/RFS resets on reboot. Add to rc.local or re-run this. ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  To persist: ${CYAN}crontab -e${NC} → ${CYAN}@reboot bash /path/to/vps-ss-optimize.sh${NC}${BOLD}│${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────────────────────┘${NC}"
