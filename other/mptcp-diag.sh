#!/bin/bash
###############################################################################
#  MPTCP Diagnostic Script
#  Run on: Router
#  Usage:  sudo bash mptcp-diag.sh [VPS_IP]
#
#  Tests each layer independently to find the bottleneck
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[✗]${NC} $*"; }
banner() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }
info()   { echo -e "    $*"; }

VPS_IP="${1:-$(grep -A2 '"type": "shadowsocks"' /etc/sing-box/config.json 2>/dev/null | grep '"server"' | head -1 | sed 's/.*"server": *"//;s/".*//')}"

if [[ -z "$VPS_IP" ]]; then
    err "Usage: sudo bash mptcp-diag.sh <VPS_IP>"
    exit 1
fi

banner "MPTCP Diagnostic — Router Side"
echo -e "${BOLD}VPS:${NC} ${VPS_IP}"
echo ""

###############################################################################
# 1. Kernel MPTCP status
###############################################################################
banner "1. Kernel MPTCP"

MPTCP_ENABLED=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "N/A")
echo -e "  MPTCP enabled:     ${BOLD}${MPTCP_ENABLED}${NC}"

MPTCP_SCHED=$(cat /proc/sys/net/mptcp/scheduler 2>/dev/null || sysctl -n net.mptcp.scheduler 2>/dev/null || echo "N/A")
echo -e "  Scheduler:         ${BOLD}${MPTCP_SCHED}${NC}"

echo -e "  ${BOLD}Endpoints:${NC}"
ip mptcp endpoint show 2>/dev/null | while read -r line; do echo "    $line"; done

echo -e "  ${BOLD}Limits:${NC}"
ip mptcp limits show 2>/dev/null | while read -r line; do echo "    $line"; done

echo -e "  ${BOLD}MPTCP stats:${NC}"
nstat -az 2>/dev/null | grep -i mptcp | grep -v " 0 " | head -10 | while read -r line; do echo "    $line"; done
echo ""

###############################################################################
# 2. Active MPTCP connections & subflows
###############################################################################
banner "2. Active MPTCP Connections"

MPTCP_CONNS=$(ss -M 2>/dev/null | grep -c ESTAB || echo "0")
echo -e "  MPTCP connections: ${BOLD}${MPTCP_CONNS}${NC}"

if [[ "$MPTCP_CONNS" -gt 0 ]]; then
    echo -e "  ${BOLD}Connection details:${NC}"
    ss -tiM 2>/dev/null | head -30 | while read -r line; do echo "    $line"; done
else
    warn "No active MPTCP connections. Generate traffic first (curl, speedtest, etc.)"
fi
echo ""

###############################################################################
# 3. Policy routing verification
###############################################################################
banner "3. Policy Routing"

echo -e "  ${BOLD}ip rule show (relevant):${NC}"
ip rule show | grep -E "priority (4[0-9]|5[0-9]|10[0-9]|20[0-9])" | while read -r line; do echo "    $line"; done

echo ""
echo -e "  ${BOLD}Route to VPS from each WAN IP:${NC}"
for ep in $(ip mptcp endpoint show 2>/dev/null | awk '{print $1}'); do
    RESULT=$(ip route get "$VPS_IP" from "$ep" 2>/dev/null | head -1)
    DEV=$(echo "$RESULT" | grep -oP 'dev \K\S+')
    VIA=$(echo "$RESULT" | grep -oP 'via \K\S+')
    if [[ -n "$DEV" ]]; then
        log "  ${ep} → via ${VIA} dev ${DEV}"
    else
        err "  ${ep} → NO ROUTE (broken!)"
    fi
done

echo ""
echo -e "  ${BOLD}Default routes in main table:${NC}"
ip route show default | while read -r line; do echo "    $line"; done

###############################################################################
# 4. Interface speed & duplex
###############################################################################
banner "4. Interface Link Speed"

for iface in $(ip mptcp endpoint show 2>/dev/null | grep -oP 'dev \K\S+'); do
    SPEED=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || echo "?")
    DUPLEX=$(cat "/sys/class/net/${iface}/duplex" 2>/dev/null || echo "?")
    CARRIER=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo "?")
    IP=$(ip -4 addr show "$iface" | grep -oP '(?<=inet )\S+' | head -1)
    echo -e "  ${BOLD}${iface}${NC} (${IP}): ${SPEED} Mbps, ${DUPLEX} duplex, carrier=${CARRIER}"
done

# Check TUN
TUN_MTU=$(cat /sys/class/net/tun-mptcp/mtu 2>/dev/null || echo "N/A")
echo -e "  ${BOLD}tun-mptcp${NC}: MTU=${TUN_MTU}"
echo ""

###############################################################################
# 5. sing-box process info
###############################################################################
banner "5. sing-box Process"

SINGBOX_PID=$(pidof sing-box 2>/dev/null || echo "")
if [[ -n "$SINGBOX_PID" ]]; then
    log "sing-box running (PID: ${SINGBOX_PID})"

    # Thread count
    THREADS=$(ls /proc/"$SINGBOX_PID"/task/ 2>/dev/null | wc -l)
    echo -e "  Threads: ${BOLD}${THREADS}${NC}"

    # Per-thread CPU usage
    echo -e "  ${BOLD}Top threads (by CPU):${NC}"
    ps -L -p "$SINGBOX_PID" -o tid,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -8 | while read -r line; do echo "    $line"; done
else
    err "sing-box is NOT running!"
fi
echo ""

###############################################################################
# 6. CPU & AES-NI check
###############################################################################
banner "6. CPU Capabilities"

CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | sed 's/.*: //')
CPU_CORES=$(nproc)
HAS_AES=$(grep -c "aes" /proc/cpuinfo | head -1)

echo -e "  CPU: ${BOLD}${CPU_MODEL}${NC}"
echo -e "  Cores: ${BOLD}${CPU_CORES}${NC}"
if [[ "$HAS_AES" -gt 0 ]]; then
    log "AES-NI: supported ✓"
else
    err "AES-NI: NOT supported — encryption will be very slow!"
fi

# Quick AES benchmark
if command -v openssl &>/dev/null; then
    echo -e "  ${BOLD}OpenSSL AES-256-GCM benchmark (1 core):${NC}"
    BENCH=$(openssl speed -evp aes-256-gcm 2>/dev/null | grep "aes-256-gcm" | tail -1)
    echo "    $BENCH"
fi
echo ""

###############################################################################
# 7. Per-interface traffic counters (snapshot)
###############################################################################
banner "7. Interface Traffic (snapshot — run a speed test, then run this again)"

for iface in $(ip mptcp endpoint show 2>/dev/null | grep -oP 'dev \K\S+'); do
    RX=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo "0")
    TX=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo "0")
    RX_MB=$((RX / 1048576))
    TX_MB=$((TX / 1048576))
    echo -e "  ${BOLD}${iface}${NC}: RX=${RX_MB} MB, TX=${TX_MB} MB"
done
echo ""

###############################################################################
# 8. Real-time bandwidth test (5 seconds)
###############################################################################
banner "8. Real-Time Interface Bandwidth (5 sec sample)"
echo "  Measuring... (generate traffic now if not already running)"

declare -A RX_START TX_START
for iface in $(ip mptcp endpoint show 2>/dev/null | grep -oP 'dev \K\S+'); do
    RX_START[$iface]=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo "0")
    TX_START[$iface]=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo "0")
done

sleep 5

TOTAL_RX=0
TOTAL_TX=0
for iface in $(ip mptcp endpoint show 2>/dev/null | grep -oP 'dev \K\S+'); do
    RX_END=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo "0")
    TX_END=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo "0")
    RX_DIFF=$(( (RX_END - ${RX_START[$iface]}) * 8 / 5 / 1000000 ))
    TX_DIFF=$(( (TX_END - ${TX_START[$iface]}) * 8 / 5 / 1000000 ))
    TOTAL_RX=$((TOTAL_RX + RX_DIFF))
    TOTAL_TX=$((TOTAL_TX + TX_DIFF))
    echo -e "  ${BOLD}${iface}${NC}: ↓ ${RX_DIFF} Mbps  ↑ ${TX_DIFF} Mbps"
done
echo -e "  ${BOLD}TOTAL${NC}:  ↓ ${TOTAL_RX} Mbps  ↑ ${TOTAL_TX} Mbps"
echo ""

###############################################################################
# 9. Recommendations
###############################################################################
banner "9. Recommendations"

echo -e "${BOLD}Run these tests in order to isolate the bottleneck:${NC}"
echo ""
echo -e "  ${CYAN}Test A — Raw TCP (no MPTCP, no tunnel):${NC}"
echo "    VPS:    iperf3 -s -p 9201"
echo "    Router: iperf3 -c ${VPS_IP} -p 9201 -P 4 -t 10"
echo "    → Shows: single-WAN speed to VPS"
echo ""
echo -e "  ${CYAN}Test B — Raw MPTCP (no tunnel):${NC}"
echo "    VPS:    mptcpize run iperf3 -s -p 9202"
echo "    Router: mptcpize run iperf3 -c ${VPS_IP} -p 9202 -P 4 -t 10"
echo "    → Shows: MPTCP aggregated speed WITHOUT sing-box overhead"
echo ""
echo -e "  ${CYAN}Test C — Through tunnel (current setup):${NC}"
echo "    From LAN client: speedtest or iperf3 to a public server"
echo "    → Shows: end-to-end with tunnel overhead"
echo ""
echo -e "  ${YELLOW}If A ≈ B:${NC}     MPTCP subflows not working, check endpoints/limits"
echo -e "  ${YELLOW}If B >> C:${NC}     sing-box tunnel is the bottleneck"
echo -e "  ${YELLOW}If B ≈ C:${NC}     tunnel overhead is minimal, check ISP shaping"
echo ""
echo -e "  ${CYAN}Install mptcpd if missing:${NC} sudo apt install mptcpd"
