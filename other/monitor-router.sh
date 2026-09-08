#!/bin/bash
###############################################################################
#  MPTCP Traffic & CPU Monitor — Router
#  Usage: sudo bash monitor-router.sh
#  Run in tmux for persistent monitoring
###############################################################################

# ─── Config ─────────────────────────────────────────────────────────────────
INTERFACES=("enp6s18" "enp6s19" "enp6s20")
LABELS=("WAN1" "WAN2" "LAN")
SERVICE="sslocal"
INTERVAL=1
# ─────────────────────────────────────────────────────────────────────────────

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; D='\033[2m'; NC='\033[0m'

human_rate() {
    local bps=$1
    if (( bps >= 1000000000 )); then
        printf "%6.2f Gbps" "$(echo "scale=2; $bps/1000000000" | bc)"
    elif (( bps >= 1000000 )); then
        printf "%6.1f Mbps" "$(echo "scale=1; $bps/1000000" | bc)"
    elif (( bps >= 1000 )); then
        printf "%6.1f Kbps" "$(echo "scale=1; $bps/1000" | bc)"
    else
        printf "%6d  bps" "$bps"
    fi
}

bar() {
    local pct=$1 width=30 filled color
    filled=$((pct * width / 100))
    (( filled > width )) && filled=$width
    if (( pct > 80 )); then color="$R"
    elif (( pct > 50 )); then color="$Y"
    else color="$G"; fi
    printf "${color}"
    for ((i=0; i<filled; i++)); do printf "█"; done
    printf "${D}"
    for ((i=filled; i<width; i++)); do printf "░"; done
    printf "${NC} %3d%%" "$pct"
}

# Read initial counters
declare -A prev_rx prev_tx
for iface in "${INTERFACES[@]}"; do
    prev_rx[$iface]=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
    prev_tx[$iface]=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
done

sleep "$INTERVAL"

while true; do
    clear
    NOW=$(date '+%H:%M:%S')
    UPTIME=$(uptime -p 2>/dev/null | sed 's/up //')

    # ── Header ──
    printf "${C}${B}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${C}${B}║${NC}  ${B}MPTCP Router Monitor${NC}                         ${D}${NOW}  up ${UPTIME}${NC}  ${C}${B}║${NC}\n"
    printf "${C}${B}╚══════════════════════════════════════════════════════════════════╝${NC}\n"

    # ── Network Traffic ──
    printf "\n ${B}📡 Network Traffic${NC}\n"
    printf " ${D}%-6s  %-18s  %-18s  %-10s${NC}\n" "IFACE" "▼ DOWNLOAD" "▲ UPLOAD" "STATUS"
    printf " ${D}──────────────────────────────────────────────────────────────${NC}\n"

    total_rx_rate=0
    total_tx_rate=0

    for idx in "${!INTERFACES[@]}"; do
        iface="${INTERFACES[$idx]}"
        label="${LABELS[$idx]}"

        cur_rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        cur_tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)

        rx_rate=$(( (cur_rx - prev_rx[$iface]) * 8 / INTERVAL ))
        tx_rate=$(( (cur_tx - prev_tx[$iface]) * 8 / INTERVAL ))

        prev_rx[$iface]=$cur_rx
        prev_tx[$iface]=$cur_tx

        total_rx_rate=$((total_rx_rate + rx_rate))
        total_tx_rate=$((total_tx_rate + tx_rate))

        # Status indicator
        if (( rx_rate > 100000000 || tx_rate > 100000000 )); then
            status="${G}● ACTIVE${NC}"
        elif (( rx_rate > 1000000 || tx_rate > 1000000 )); then
            status="${Y}● BUSY${NC}"
        else
            status="${D}○ idle${NC}"
        fi

        rx_str=$(human_rate $rx_rate)
        tx_str=$(human_rate $tx_rate)
        printf " ${B}%-6s${NC} ${G}▼${NC} %-17s ${R}▲${NC} %-17s %b\n" \
            "$label" "$rx_str" "$tx_str" "$status"
    done

    printf " ${D}──────────────────────────────────────────────────────────────${NC}\n"
    printf " ${B}TOTAL${NC}  ${G}▼${NC} %-17s ${R}▲${NC} %-17s\n" \
        "$(human_rate $total_rx_rate)" "$(human_rate $total_tx_rate)"

    # ── MPTCP ──
    printf "\n ${B}🔗 MPTCP Subflows${NC}\n"
    mptcp_count=$(ss -M 2>/dev/null | grep -c ESTAB || echo 0)
    printf "  Active connections: ${B}${mptcp_count}${NC}\n"
    ip mptcp endpoint show 2>/dev/null | while read -r line; do
        printf "  ${D}%s${NC}\n" "$line"
    done

    # ── CPU & Services ──
    printf "\n ${B}⚙️  CPU & Services${NC}\n"

    # Overall CPU
    cpu_line=$(top -bn1 | grep '^%Cpu' | head -1)
    cpu_user=$(echo "$cpu_line" | awk '{print $2}')
    cpu_sys=$(echo "$cpu_line" | awk '{print $4}')
    cpu_idle=$(echo "$cpu_line" | awk '{print $8}')
    cpu_si=$(echo "$cpu_line" | awk '{print $14}' | tr -d ',')
    cpu_used=$(echo "100 - $cpu_idle" | bc 2>/dev/null || echo "0")
    cpu_pct=${cpu_used%.*}

    printf "  CPU: "
    bar "$cpu_pct"
    printf "\n"
    printf "  ${D}user:${NC} %s%%  ${D}sys:${NC} %s%%  ${D}softirq:${NC} %s%%  ${D}idle:${NC} %s%%\n" \
        "$cpu_user" "$cpu_sys" "$cpu_si" "$cpu_idle"

    # Memory
    mem_info=$(free -m | awk '/^Mem:/ {printf "%.0f", ($3/$2)*100}')
    mem_used=$(free -m | awk '/^Mem:/ {print $3}')
    mem_total=$(free -m | awk '/^Mem:/ {print $2}')
    printf "  RAM: "
    bar "$mem_info"
    printf "  ${D}(${mem_used}/${mem_total} MB)${NC}\n"

    # Service CPU
    printf "\n  ${D}%-20s %8s %8s${NC}\n" "SERVICE" "CPU%" "MEM(MB)"
    printf "  ${D}──────────────────────────────────────${NC}\n"

    if pgrep -x "$SERVICE" &>/dev/null; then
        svc_cpu=$(ps -C "$SERVICE" -o %cpu= | head -1 | tr -d ' ')
        svc_mem=$(ps -C "$SERVICE" -o rss= | head -1 | awk '{printf "%.1f", $1/1024}')
        printf "  ${G}●${NC} %-18s %7s%% %7s\n" "$SERVICE" "$svc_cpu" "$svc_mem"
    else
        printf "  ${R}●${NC} %-18s %8s %8s\n" "$SERVICE" "DOWN" "-"
    fi

    if pgrep -f "sing-box" &>/dev/null; then
        svc_cpu=$(ps -C "sing-box" -o %cpu= | head -1 | tr -d ' ')
        svc_mem=$(ps -C "sing-box" -o rss= | head -1 | awk '{printf "%.1f", $1/1024}')
        printf "  ${Y}●${NC} %-18s %7s%% %7s\n" "sing-box" "$svc_cpu" "$svc_mem"
    fi

    printf "\n ${D}Press Ctrl+C to exit${NC}\n"
    sleep "$INTERVAL"
done
