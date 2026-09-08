#!/bin/bash
###############################################################################
#  Router Network Diagnostics — CPU, softirq, NIC, MPTCP baseline snapshot
#  Usage: sudo bash router-diag.sh
#
#  Shows current state WITHOUT changing anything. Run during a speed test
#  to capture the load profile, then use it to decide what to optimize.
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
banner() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

if [[ $EUID -ne 0 ]]; then echo -e "${RED}[✗]${NC} Run as root"; exit 1; fi

###############################################################################
# 1. System overview
###############################################################################
banner "Router Diagnostics — $(date '+%Y-%m-%d %H:%M:%S')"

echo -e "${BOLD}System:${NC}"
printf "  %-20s %s\n" "Kernel:" "$(uname -r)"
printf "  %-20s %s\n" "CPU:" "$(grep -c ^processor /proc/cpuinfo) cores — $(grep 'model name' /proc/cpuinfo | head -1 | sed 's/.*: //')"
printf "  %-20s %s\n" "Memory:" "$(free -h | awk '/^Mem:/ {printf "%s used / %s total", $3, $2}')"
printf "  %-20s %s\n" "Uptime:" "$(uptime -p)"

###############################################################################
# 2. CPU — per-core breakdown (5 second sample)
###############################################################################
banner "CPU Usage (5s sample, per core)"

echo -e "${DIM}Running mpstat -P ALL 1 5 ...${NC}"
echo ""

# Capture mpstat output
MPSTAT_OUT=$(mpstat -P ALL 1 5 2>/dev/null | tail -n $(($(nproc) + 2)))

if [[ -n "$MPSTAT_OUT" ]]; then
    echo "$MPSTAT_OUT" | head -1
    echo "$MPSTAT_OUT" | tail -n +2 | while IFS= read -r line; do
        # Color-code based on softirq percentage
        SOFT=$(echo "$line" | awk '{print $8}' 2>/dev/null)
        IDLE=$(echo "$line" | awk '{print $NF}' 2>/dev/null)
        if [[ -n "$SOFT" ]]; then
            SOFT_INT=${SOFT%.*}
            if (( SOFT_INT > 40 )); then
                echo -e "${RED}${line}${NC}  ← HIGH softirq"
            elif (( SOFT_INT > 20 )); then
                echo -e "${YELLOW}${line}${NC}"
            else
                echo -e "${GREEN}${line}${NC}"
            fi
        else
            echo "$line"
        fi
    done
else
    echo -e "${YELLOW}  mpstat not available. Install: apt-get install sysstat${NC}"
    echo ""
    echo -e "${BOLD}Fallback — /proc/stat snapshot:${NC}"
    head -$(($(nproc) + 1)) /proc/stat | while read -r line; do
        echo "  $line"
    done
fi

###############################################################################
# 3. softirq breakdown
###############################################################################
section "Softirq Breakdown (/proc/softirqs)"
echo -e "${DIM}(NET_RX and NET_TX are the network-related ones)${NC}"
echo ""

printf "  ${BOLD}%-12s" "IRQ Type"
for i in $(seq 0 $(($(nproc) - 1))); do
    printf "  %10s" "CPU${i}"
done
echo -e "${NC}"

for IRQ_TYPE in NET_RX NET_TX TIMER SCHED; do
    LINE=$(grep "^ *${IRQ_TYPE}:" /proc/softirqs 2>/dev/null)
    if [[ -n "$LINE" ]]; then
        printf "  %-12s" "$IRQ_TYPE"
        echo "$LINE" | awk '{for(i=2;i<=NF;i++) printf "  %10s", $i; print ""}'
    fi
done

###############################################################################
# 4. Interrupt distribution
###############################################################################
section "Top Interrupts (network-related)"

echo ""
printf "  ${BOLD}%-8s %-50s" "IRQ#" "Device"
for i in $(seq 0 $(($(nproc) - 1))); do
    printf "  %10s" "CPU${i}"
done
echo -e "${NC}"

# Show top interrupts by count
grep -E "eth|enp|virtio|xgbe" /proc/interrupts 2>/dev/null | head -10 | while IFS= read -r line; do
    IRQ=$(echo "$line" | awk '{print $1}' | tr -d ':')
    DEV=$(echo "$line" | awk '{print $NF}')
    printf "  %-8s %-50s" "$IRQ" "$DEV"
    echo "$line" | awk -v n=$(nproc) '{for(i=2;i<=n+1;i++) printf "  %10s", $i; print ""}'
done

###############################################################################
# 5. NIC offloads per interface
###############################################################################
banner "NIC Configuration"

# Find all relevant interfaces
ALL_IFACES=()
while IFS= read -r iface; do
    [[ "$iface" == "lo" ]] && continue
    ALL_IFACES+=("$iface")
done < <(ls /sys/class/net/)

for IFACE in "${ALL_IFACES[@]}"; do
    STATE=$(cat /sys/class/net/${IFACE}/operstate 2>/dev/null || echo "unknown")
    [[ "$STATE" == "down" ]] && continue

    SPEED=$(ethtool "${IFACE}" 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "?")
    DRIVER=$(ethtool -i "${IFACE}" 2>/dev/null | grep "driver:" | awk '{print $2}' || echo "?")

    echo -e "${BOLD}${IFACE}${NC} — ${SPEED} (${DRIVER}) [${STATE}]"

    # IP addresses
    ip -4 addr show dev "$IFACE" 2>/dev/null | grep inet | awk '{printf "  IP: %s\n", $2}'

    # Offloads
    if command -v ethtool &>/dev/null; then
        echo -e "  ${DIM}Offloads:${NC}"
        ethtool -k "$IFACE" 2>/dev/null | grep -E "^(generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload|rx-checksumming|tx-checksumming)" | sed 's/^/    /'
    fi

    # RPS status
    echo -e "  ${DIM}RPS:${NC}"
    for rxq in /sys/class/net/${IFACE}/queues/rx-*/rps_cpus; do
        if [[ -f "$rxq" ]]; then
            QUEUE=$(basename "$(dirname "$rxq")")
            VAL=$(cat "$rxq" 2>/dev/null)
            if [[ "$VAL" == "0" || "$VAL" == "00000000" || "$VAL" =~ ^0+$ ]]; then
                echo -e "    ${QUEUE}: ${RED}${VAL} (disabled — all softirq on 1 core!)${NC}"
            else
                echo -e "    ${QUEUE}: ${GREEN}${VAL} (distributed)${NC}"
            fi
        fi
    done

    # RX/TX queue count
    RXQ=$(ls -d /sys/class/net/${IFACE}/queues/rx-* 2>/dev/null | wc -l)
    TXQ=$(ls -d /sys/class/net/${IFACE}/queues/tx-* 2>/dev/null | wc -l)
    echo "  Queues: ${RXQ} RX / ${TXQ} TX"

    echo ""
done

###############################################################################
# 6. Current sysctl values
###############################################################################
banner "Kernel Tuning (sysctl)"

echo -e "${BOLD}Network Stack:${NC}"
for key in \
    net.core.netdev_budget \
    net.core.netdev_budget_usecs \
    net.core.netdev_max_backlog \
    net.core.busy_read \
    net.core.busy_poll \
    net.core.rmem_max \
    net.core.wmem_max \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.tcp_congestion_control \
    net.ipv4.tcp_timestamps \
    net.ipv4.tcp_reordering \
    net.ipv4.ip_forward; do
    VAL=$(sysctl -n "$key" 2>/dev/null || echo "N/A")
    # Highlight non-optimal defaults
    case "$key" in
        *netdev_budget)
            [[ "$VAL" -le 300 ]] && COLOR="$YELLOW" || COLOR="$GREEN" ;;
        *busy_poll|*busy_read)
            [[ "$VAL" -eq 0 ]] && COLOR="$YELLOW" || COLOR="$GREEN" ;;
        *tcp_timestamps)
            [[ "$VAL" -eq 1 ]] && COLOR="$YELLOW" || COLOR="$GREEN" ;;
        *tcp_congestion_control)
            [[ "$VAL" != "bbr" ]] && COLOR="$RED" || COLOR="$GREEN" ;;
        *) COLOR="$NC" ;;
    esac
    printf "  %-45s = ${COLOR}%s${NC}\n" "$key" "$VAL"
done

echo ""
echo -e "${BOLD}Conntrack:${NC}"
for key in \
    net.netfilter.nf_conntrack_max \
    net.netfilter.nf_conntrack_count \
    net.netfilter.nf_conntrack_tcp_timeout_established; do
    VAL=$(sysctl -n "$key" 2>/dev/null || echo "N/A")
    printf "  %-45s = %s\n" "$key" "$VAL"
done

###############################################################################
# 7. MPTCP status
###############################################################################
banner "MPTCP Status"

echo -e "${BOLD}MPTCP enabled:${NC} $(sysctl -n net.mptcp.enabled 2>/dev/null || echo 'N/A')"
echo ""

echo -e "${BOLD}Endpoints:${NC}"
ip mptcp endpoint show 2>/dev/null | while read -r line; do
    echo "  $line"
done

echo ""
echo -e "${BOLD}Limits:${NC}"
ip mptcp limits show 2>/dev/null | sed 's/^/  /'

echo ""
echo -e "${BOLD}Active MPTCP connections:${NC}"
MPTCP_CONNS=$(ss -tiM 2>/dev/null | grep -c "mptcp" || echo "0")
echo "  ${MPTCP_CONNS} connections"

###############################################################################
# 8. sslocal process info
###############################################################################
banner "sslocal Process"

if pgrep -x sslocal > /dev/null 2>&1; then
    echo -e "${GREEN}sslocal is running${NC}"
    echo ""
    # Show per-thread CPU
    echo -e "${BOLD}Thread CPU usage:${NC}"
    top -bn1 -H -p "$(pgrep -x sslocal | head -1)" 2>/dev/null | tail -n +8 | head -10
else
    echo -e "${RED}sslocal is NOT running${NC}"
fi

###############################################################################
# 9. iptables summary
###############################################################################
section "iptables PREROUTING (redirect rules)"
iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | head -15

section "iptables POSTROUTING (NAT)"
iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | head -10

###############################################################################
# 10. Recommendations
###############################################################################
banner "Recommendations"

ISSUES=0

# Check RPS
for IFACE in "${ALL_IFACES[@]}"; do
    STATE=$(cat /sys/class/net/${IFACE}/operstate 2>/dev/null || echo "unknown")
    [[ "$STATE" == "down" ]] && continue
    for rxq in /sys/class/net/${IFACE}/queues/rx-*/rps_cpus; do
        VAL=$(cat "$rxq" 2>/dev/null)
        if [[ "$VAL" == "0" || "$VAL" == "00000000" || "$VAL" =~ ^0+$ ]]; then
            echo -e "${YELLOW}⚠ ${IFACE}:${NC} RPS disabled — softirq stuck on 1 core"
            echo -e "  Fix: echo $(printf '%x' $(( (1 << $(nproc)) - 1 ))) > ${rxq}"
            ISSUES=$((ISSUES + 1))
        fi
    done
done

# Check netdev_budget
BUDGET=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo 0)
if (( BUDGET <= 300 )); then
    echo -e "${YELLOW}⚠ netdev_budget=${BUDGET}${NC} (default) — increase to 600 for less softirq overhead"
    ISSUES=$((ISSUES + 1))
fi

# Check busy_poll
BPOLL=$(sysctl -n net.core.busy_poll 2>/dev/null || echo 0)
if (( BPOLL == 0 )); then
    echo -e "${YELLOW}⚠ busy_poll=0${NC} — enable for lower latency on high-throughput"
    ISSUES=$((ISSUES + 1))
fi

# Check timestamps
TS=$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null || echo 1)
if (( TS == 1 )); then
    echo -e "${YELLOW}⚠ tcp_timestamps=1${NC} — disable to save ~12 bytes CPU work per packet"
    ISSUES=$((ISSUES + 1))
fi

# Check BBR
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
if [[ "$CC" != "bbr" ]]; then
    echo -e "${RED}✗ tcp_congestion_control=${CC}${NC} — should be bbr for MPTCP"
    ISSUES=$((ISSUES + 1))
fi

# Check conntrack
CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)
CT_CUR=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo 0)
if (( CT_MAX > 0 && CT_CUR * 100 / CT_MAX > 80 )); then
    echo -e "${RED}✗ conntrack ${CT_CUR}/${CT_MAX}${NC} (>80% full!) — increase nf_conntrack_max"
    ISSUES=$((ISSUES + 1))
fi

if (( ISSUES == 0 )); then
    echo -e "${GREEN}✓ All looks good — no obvious issues found${NC}"
else
    echo ""
    echo -e "${BOLD}Found ${ISSUES} optimization(s). Run router-ss-optimize.sh to fix.${NC}"
fi

echo ""
