#!/bin/bash
###############################################################################
#  Change MPTCP VPS IP and/or Password on Router
#  Usage:  sudo bash router-change-vps-ip.sh
#          sudo bash router-change-vps-ip.sh <NEW_IP>
#          sudo bash router-change-vps-ip.sh <NEW_IP> <NEW_PASSWORD>
#
#  Detects current VPS IP and password from sing-box config,
#  prompts for new ones, replaces everywhere, and restarts services.
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

SINGBOX_CONFIG="/etc/sing-box/config.json"
MPTCP_SCRIPT="/usr/local/bin/mptcp-setup.sh"

# ── Root check ──
if [[ $EUID -ne 0 ]]; then
    err "Run as root: sudo bash $0"
    exit 1
fi

# ── Detect current VPS IP from sing-box config ──
if [[ ! -f "$SINGBOX_CONFIG" ]]; then
    err "sing-box config not found at ${SINGBOX_CONFIG}"
    err "Has the router script been run yet?"
    exit 1
fi

# Extract the server IP from the shadowsocks outbound
OLD_IP=$(grep -A2 '"type": "shadowsocks"' "$SINGBOX_CONFIG" | grep '"server"' | head -1 | sed 's/.*"server": *"//;s/".*//')
OLD_PW=$(grep '"password"' "$SINGBOX_CONFIG" | head -1 | sed 's/.*"password": *"//;s/".*//')

if [[ -z "$OLD_IP" ]]; then
    err "Could not detect current VPS IP from ${SINGBOX_CONFIG}"
    exit 1
fi

echo -e "${BOLD}Current VPS IP:${NC}       ${CYAN}${OLD_IP}${NC}"
echo -e "${BOLD}Current Password:${NC}    ${CYAN}${OLD_PW:0:8}...${NC}"
echo ""

# ── Get new IP ──
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    NEW_IP="$1"
else
    echo -n -e "${BOLD}Enter new VPS IP:${NC} "
    read -r NEW_IP
fi

# Validate IP format
if ! [[ "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "Invalid IP format: ${NEW_IP}"
    exit 1
fi

# ── Get new password ──
if [[ $# -ge 2 && -n "${2:-}" ]]; then
    NEW_PW="$2"
else
    echo -n -e "${BOLD}Enter new password${NC} (Enter to keep current): "
    read -r NEW_PW
    if [[ -z "$NEW_PW" ]]; then
        NEW_PW="$OLD_PW"
    fi
fi

IP_CHANGED=false
PW_CHANGED=false
[[ "$NEW_IP" != "$OLD_IP" ]] && IP_CHANGED=true
[[ "$NEW_PW" != "$OLD_PW" ]] && PW_CHANGED=true

if [[ "$IP_CHANGED" == false && "$PW_CHANGED" == false ]]; then
    warn "Nothing changed. Exiting."
    exit 0
fi

echo ""
[[ "$IP_CHANGED" == true ]] && echo -e "${BOLD}Changing IP:${NC}       ${RED}${OLD_IP}${NC} → ${GREEN}${NEW_IP}${NC}"
[[ "$PW_CHANGED" == true ]] && echo -e "${BOLD}Changing Password:${NC} ${RED}${OLD_PW:0:8}...${NC} → ${GREEN}${NEW_PW:0:8}...${NC}"
echo ""

# ── 1. Update sing-box config ──
if [[ -f "$SINGBOX_CONFIG" ]]; then
    [[ "$IP_CHANGED" == true ]] && sed -i "s/${OLD_IP}/${NEW_IP}/g" "$SINGBOX_CONFIG"
    if [[ "$PW_CHANGED" == true ]]; then
        # Escape special chars in passwords for sed (/, &, \)
        OLD_PW_ESC=$(printf '%s\n' "$OLD_PW" | sed 's/[&/\\]/\\&/g')
        NEW_PW_ESC=$(printf '%s\n' "$NEW_PW" | sed 's/[&/\\]/\\&/g')
        sed -i "s|${OLD_PW_ESC}|${NEW_PW_ESC}|g" "$SINGBOX_CONFIG"
    fi
    log "Updated ${SINGBOX_CONFIG}"
else
    err "Missing ${SINGBOX_CONFIG}"
fi

# ── 2. Update mptcp-setup.sh ──
if [[ -f "$MPTCP_SCRIPT" ]]; then
    [[ "$IP_CHANGED" == true ]] && sed -i "s/${OLD_IP}/${NEW_IP}/g" "$MPTCP_SCRIPT"
    log "Updated ${MPTCP_SCRIPT}"
else
    warn "Missing ${MPTCP_SCRIPT} — skipped (will be regenerated on next full deploy)"
fi

# ── 3. Update routing: remove old VPS route, add new one ──
if [[ "$IP_CHANGED" == true ]]; then
    # Find which gateway/device the old route used
    PRIMARY_GW=$(ip route show "${OLD_IP}/32" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
    PRIMARY_DEV=$(ip route show "${OLD_IP}/32" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

    # Fallback: use default route info
    if [[ -z "$PRIMARY_GW" ]]; then
        PRIMARY_GW=$(ip route show default | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
        PRIMARY_DEV=$(ip route show default | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    fi

    ip route del "${OLD_IP}/32" 2>/dev/null || true
    ip route replace "${NEW_IP}/32" via "$PRIMARY_GW" dev "$PRIMARY_DEV"
    log "Route: ${NEW_IP}/32 via ${PRIMARY_GW} dev ${PRIMARY_DEV}"
fi

# ── 4. Restart sing-box ──
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    log "sing-box restarted ✓"
else
    err "sing-box failed to start!"
    journalctl -u sing-box -n 10 --no-pager
    exit 1
fi

# ── 5. Re-run MPTCP routing (updates TUN routing) ──
if [[ -f "$MPTCP_SCRIPT" ]]; then
    "$MPTCP_SCRIPT"
    log "MPTCP routing refreshed ✓"
fi

# ── Done ──
echo ""
echo -e "${BOLD}┌─────────────────────────────────────────────────────┐${NC}"
[[ "$IP_CHANGED" == true ]]  && echo -e "${BOLD}│${NC}  IP changed:  ${RED}${OLD_IP}${NC} → ${GREEN}${NEW_IP}${NC}"
[[ "$PW_CHANGED" == true ]]  && echo -e "${BOLD}│${NC}  Password changed ✓"
echo -e "${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  Verify: ${CYAN}ss -tiM${NC}"
echo -e "${BOLD}│${NC}          ${CYAN}curl ifconfig.me${NC}  (from LAN client)"
echo -e "${BOLD}└─────────────────────────────────────────────────────┘${NC}"
