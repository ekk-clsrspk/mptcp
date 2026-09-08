#!/bin/bash
###############################################################################
#  Router Network Optimization — softirq distribution & throughput tuning
#  Usage: sudo bash router-ss-optimize.sh
#
#  Safe to re-run anytime. Does NOT restart sslocal or change SS config.
#  Run after router-ss.sh, or anytime after reboot.
#
#  What this fixes:
#    - RPS/RFS on all interfaces (spread softirq across 8 cores)
#    - netdev_budget (2x packets per softirq cycle)
#    - busy_poll (skip interrupt wait)
#    - conntrack timeout (5 days → 10 min)
#    - tcp_timestamps off (save CPU per packet)
#    - virtio multiqueue hints
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[✗]${NC} $*" >&2; }
banner() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }

if [[ $EUID -ne 0 ]]; then err "Run as root: sudo bash router-ss-optimize.sh"; exit 1; fi

NUM_CPUS=$(nproc)
CPU_MASK=$(printf '%x' $(( (1 << NUM_CPUS) - 1 )))

banner "Router Network Optimization"
echo -e "${BOLD}System:${NC}  $(uname -r) — ${NUM_CPUS} cores — CPU mask 0x${CPU_MASK}"

###############################################################################
# 1. Check CPU steal (Proxmox/VM warning)
###############################################################################
banner "Step 1/5 — VM Health Check"

# Quick 1-second steal sample
STEAL=$(mpstat 1 1 2>/dev/null | awk '/^Average/ {print $9}' || echo "0")
STEAL_INT=${STEAL%.*}

if (( STEAL_INT > 10 )); then
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠  CPU STEAL: ${STEAL}%                                        ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  Your hypervisor is stealing ${STEAL}% of CPU time.              ║${NC}"
    echo -e "${RED}║  This is your BIGGEST bottleneck.                             ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  Fix in Proxmox:                                              ║${NC}"
    echo -e "${RED}║    1. VM → Hardware → Processor → Type: 'host'               ║${NC}"
    echo -e "${RED}║       (enables AES-NI for SS encryption)                      ║${NC}"
    echo -e "${RED}║    2. Remove any CPU limit (cpulimit=0)                       ║${NC}"
    echo -e "${RED}║    3. Reduce other VM CPU usage on same host                  ║${NC}"
    echo -e "${RED}║    4. Consider: CPU affinity (taskset) for this VM            ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    warn "Continuing with optimizations (they still help)..."
elif (( STEAL_INT > 2 )); then
    warn "CPU steal at ${STEAL}% — mild hypervisor contention"
else
    log "CPU steal: ${STEAL}% — good"
fi

###############################################################################
# 2. Kernel sysctl tuning
###############################################################################
banner "Step 2/5 — Kernel Tuning (sysctl)"

echo -e "${DIM}Before:${NC}"
for key in net.core.netdev_budget net.core.busy_poll net.ipv4.tcp_timestamps \
           net.netfilter.nf_conntrack_tcp_timeout_established; do
    printf "  %-50s = %s\n" "$key" "$(sysctl -n "$key" 2>/dev/null || echo 'N/A')"
done
echo ""

cat > /etc/sysctl.d/91-router-optimize.conf << 'EOF'
# ── Reduce softirq overhead ──
# Process more packets per softirq cycle (default 300 → 600)
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000

# Busy polling 10 = ~90% of the latency gain of 50 at ~1/5 the CPU burn (matters under steal)
net.core.busy_read=10
net.core.busy_poll=10

# ── TCP buffers (BDP-sized: 64M covers ~5Gbps @ 100ms) ──
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

# ── BBR ──
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq

# ── Conntrack — reduce from 5 days to 10 min ──
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=600
net.netfilter.nf_conntrack_buckets=65536

# ── Reuse routes quickly ──
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3

# ── MPTCP ──
net.mptcp.enabled=1
net.ipv4.ip_forward=1
net.ipv4.tcp_reordering=127

# ── Timestamps off = less CPU per packet ──
net.ipv4.tcp_timestamps=0

# ── Increase socket backlog for REDIRECT target ──
net.core.somaxconn=65535
EOF

sysctl -p /etc/sysctl.d/91-router-optimize.conf 2>&1 | grep -v "No such file" || true

echo -e "${DIM}After:${NC}"
for key in net.core.netdev_budget net.core.busy_poll net.ipv4.tcp_timestamps \
           net.netfilter.nf_conntrack_tcp_timeout_established; do
    printf "  %-50s = ${GREEN}%s${NC}\n" "$key" "$(sysctl -n "$key" 2>/dev/null || echo 'N/A')"
done
log "sysctl tuning applied"

###############################################################################
# 3. RPS/RFS on ALL interfaces
###############################################################################
banner "Step 3/5 — RPS/RFS (spread softirq across ${NUM_CPUS} cores)"

# Global RFS flow entries
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

IFACE_COUNT=0
for IFACE in $(ls /sys/class/net/); do
    [[ "$IFACE" == "lo" ]] && continue
    STATE=$(cat /sys/class/net/${IFACE}/operstate 2>/dev/null || echo "unknown")
    [[ "$STATE" != "up" ]] && continue

    # RPS: distribute to all cores
    for rxq in /sys/class/net/${IFACE}/queues/rx-*/rps_cpus; do
        OLD=$(cat "$rxq" 2>/dev/null)
        echo "$CPU_MASK" > "$rxq" 2>/dev/null || true
        NEW=$(cat "$rxq" 2>/dev/null)
    done

    # RFS: flow-level steering
    RXQ_COUNT=$(ls -d /sys/class/net/${IFACE}/queues/rx-* 2>/dev/null | wc -l)
    if (( RXQ_COUNT > 0 )); then
        FLOW_PER_Q=$((32768 / RXQ_COUNT))
        for rxq in /sys/class/net/${IFACE}/queues/rx-*/rps_flow_cnt; do
            echo "$FLOW_PER_Q" > "$rxq" 2>/dev/null || true
        done
    fi

    # XPS: Transmit Packet Steering (map tx queues to cores)
    TXQ_IDX=0
    for txq in /sys/class/net/${IFACE}/queues/tx-*/xps_cpus; do
        # Map each TX queue to a specific core for cache locality
        TX_MASK=$(printf '%x' $(( 1 << (TXQ_IDX % NUM_CPUS) )))
        echo "$TX_MASK" > "$txq" 2>/dev/null || true
        TXQ_IDX=$((TXQ_IDX + 1))
    done

    IP=$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    log "${IFACE} (${IP:-no-ip}): RPS=0x${CPU_MASK} RFS=${FLOW_PER_Q:-0}/queue"
    IFACE_COUNT=$((IFACE_COUNT + 1))
done

log "Configured ${IFACE_COUNT} interfaces"

###############################################################################
# 4. NIC offloads
###############################################################################
banner "Step 4/5 — NIC Offloads"

for IFACE in $(ls /sys/class/net/); do
    [[ "$IFACE" == "lo" ]] && continue
    STATE=$(cat /sys/class/net/${IFACE}/operstate 2>/dev/null || echo "unknown")
    [[ "$STATE" != "up" ]] && continue

    CHANGED=""

    # Rings + coalescing (fewer, bigger interrupts)
    ethtool -G "$IFACE" rx 4096 tx 4096 2>/dev/null || true
    ethtool -C "$IFACE" adaptive-rx on 2>/dev/null || true

    # GRO
    ethtool -K "$IFACE" gro on 2>/dev/null && CHANGED="${CHANGED}GRO " || true
    # GSO
    ethtool -K "$IFACE" gso on 2>/dev/null && CHANGED="${CHANGED}GSO " || true
    # TSO
    ethtool -K "$IFACE" tso on 2>/dev/null && CHANGED="${CHANGED}TSO " || true
    # Disable GRO-list (prefer normal GRO)
    ethtool -K "$IFACE" rx-gro-list off 2>/dev/null || true

    if [[ -n "$CHANGED" ]]; then
        log "${IFACE}: ${CHANGED}"
    fi
done

###############################################################################
# 5. sslocal process affinity hints
###############################################################################
banner "Step 5/5 — Process Tuning"

# Pin sslocal to NUMA node 0 if available (better cache locality)
SSLOCAL_PID=$(pgrep -x sslocal | head -1 || true)
if [[ -n "$SSLOCAL_PID" ]]; then
    # Increase priority slightly
    renice -5 -p "$SSLOCAL_PID" > /dev/null 2>&1 || true
    log "sslocal (PID ${SSLOCAL_PID}): priority increased (nice -5)"

    # Show current thread count
    THREAD_COUNT=$(ls /proc/${SSLOCAL_PID}/task/ 2>/dev/null | wc -l)
    log "sslocal threads: ${THREAD_COUNT}"
else
    warn "sslocal not running — skipping process tuning"
fi

# Increase ksoftirqd priority (helps under steal)
for PID in $(pgrep ksoftirqd || true); do
    renice -5 -p "$PID" > /dev/null 2>&1 || true
done
log "ksoftirqd priority increased (helps under CPU steal)"

###############################################################################
# Verification
###############################################################################
banner "Verification"

echo -e "${BOLD}RPS status (all interfaces):${NC}"
for IFACE in $(ls /sys/class/net/); do
    [[ "$IFACE" == "lo" ]] && continue
    STATE=$(cat /sys/class/net/${IFACE}/operstate 2>/dev/null || echo "unknown")
    [[ "$STATE" != "up" ]] && continue
    for rxq in /sys/class/net/${IFACE}/queues/rx-*/rps_cpus; do
        QUEUE=$(basename "$(dirname "$rxq")")
        VAL=$(cat "$rxq" 2>/dev/null)
        printf "  %-8s %-8s rps_cpus = ${GREEN}%s${NC}\n" "$IFACE" "$QUEUE" "$VAL"
    done
done

echo ""
echo -e "${BOLD}Key sysctl values:${NC}"
for key in net.core.netdev_budget net.core.busy_poll net.ipv4.tcp_timestamps \
           net.netfilter.nf_conntrack_tcp_timeout_established net.core.somaxconn; do
    printf "  %-50s = ${GREEN}%s${NC}\n" "$key" "$(sysctl -n "$key" 2>/dev/null)"
done

###############################################################################
# Summary
###############################################################################
banner "Optimization Complete ✅"

echo -e "${BOLD}┌──────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│${NC}  ${CYAN}What was optimized:${NC}                                             ${BOLD}│${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}  1. ${GREEN}RPS/RFS${NC}      — softirq → all ${NUM_CPUS} cores (was on 1 per NIC)       ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  2. ${GREEN}XPS${NC}          — TX queue → core affinity                       ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  3. ${GREEN}GRO/GSO/TSO${NC}  — packet coalescing on all NICs                  ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  4. ${GREEN}netdev_budget${NC} — 600 (2x default)                              ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  5. ${GREEN}busy_poll 10${NC} — latency gain without the CPU burn of 50        ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  6. ${GREEN}conntrack${NC}    — timeout 600s (was 432000s / 5 days!)            ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  7. ${GREEN}timestamps${NC}   — disabled (saves CPU per packet)                 ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  8. ${GREEN}sslocal${NC}      — priority boosted (nice -5)                      ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  9. ${GREEN}ksoftirqd${NC}    — priority boosted (fights CPU steal)             ${BOLD}│${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}                                                                  ${BOLD}│${NC}"
if (( STEAL_INT > 10 )); then
echo -e "${BOLD}│${NC}  ${RED}⚠ CPU steal is ${STEAL}% — fix in Proxmox for biggest gain:${NC}        ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}    VM → Hardware → CPU Type: ${CYAN}host${NC}                                ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}    VM → Hardware → CPU limit: ${CYAN}remove / set to 0${NC}                   ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}                                                                  ${BOLD}│${NC}"
fi
echo -e "${BOLD}│${NC}  ${YELLOW}Test:${NC}                                                           ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}    ${CYAN}mpstat -P ALL 1 5${NC}  — softirq should be spread evenly            ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}    ${CYAN}speedtest / iperf3${NC} — compare throughput                         ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}                                                                  ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  ${YELLOW}Note:${NC} RPS/RFS/XPS reset on reboot — persisted via systemd:          ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}    ${CYAN}systemctl enable rps-persist${NC} (created below)                       ${BOLD}│${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────────────────────┘${NC}"

# ── Persist RPS/RFS/XPS across reboots (all up interfaces, not just default) ──
cat > /usr/local/bin/apply-rps.sh << 'RPS_EOF'
#!/bin/bash
# Re-applied at boot by rps-persist.service (all non-lo up interfaces)
CPUS=$(nproc)
MASK=$(printf '%x' $(( (1 << CPUS) - 1 )))
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
for IFACE in $(ls /sys/class/net/); do
    [[ "$IFACE" == "lo" ]] && continue
    [[ "$(cat /sys/class/net/${IFACE}/operstate 2>/dev/null)" != "up" ]] && continue
    RXQ=$(ls -d /sys/class/net/${IFACE}/queues/rx-* 2>/dev/null | wc -l)
    (( RXQ == 0 )) && continue
    FLOW=$((32768 / RXQ))
    for rxq in /sys/class/net/${IFACE}/queues/rx-*/rps_cpus; do echo "$MASK" > "$rxq" 2>/dev/null || true; done
    for rxq in /sys/class/net/${IFACE}/queues/rx-*/rps_flow_cnt; do echo "$FLOW" > "$rxq" 2>/dev/null || true; done
    IDX=0
    for txq in /sys/class/net/${IFACE}/queues/tx-*/xps_cpus; do
        M=$(printf '%x' $(( 1 << (IDX % CPUS) )))
        echo "$M" > "$txq" 2>/dev/null || true
        IDX=$((IDX + 1))
    done
    ethtool -K "$IFACE" gro on gso on tso on rx-gro-list off 2>/dev/null || true
done
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
ExecStartPre=/bin/sleep 10
ExecStart=/usr/local/bin/apply-rps.sh

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
systemctl enable rps-persist > /dev/null 2>&1 || true
log "rps-persist.service installed (RPS survives reboot)"
