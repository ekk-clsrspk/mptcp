#!/bin/bash
###############################################################################
#  MPTCP Router Deployment Script (TEST — 2 WAN + 1 LAN)
#  Run on: Test Router (Ubuntu)
#  Usage:  sudo bash router-test.sh "<SHADOWSOCKS_PASSWORD>"
#
#  The password is printed at the end of vps.sh — copy-paste it here.
#
#  This script will:
#    1. Enable MPTCP in the kernel
#    2. Install sing-box
#    3. Create policy routing tables (1 per WAN)
#    4. Configure MPTCP endpoints on all WANs
#    5. Deploy sing-box client config (TUN + Shadowsocks MPTCP)
#    6. Route LAN traffic through the MPTCP tunnel
#    7. Configure NAT, firewall, systemd persistence
###############################################################################

set -euo pipefail

# ─────────────────────────── Configuration ──────────────────────────────────

# VPS details
VPS_IP="45.91.133.189"
SS_PORT=8388
SS_METHOD="2022-blake3-aes-256-gcm"

# WAN interfaces (TEST: 2 WAN)
# WAN1 = 192.168.150.112 on enp6s18, WAN2 = 172.30.0.5 on enp6s19
WAN_INTERFACES=("enp6s18" "enp6s19")
WAN_IPS=("192.168.150.112" "172.30.0.5")
WAN_GATEWAYS=("192.168.150.1" "172.30.0.4")
WAN_SUBNETS=("192.168.150.0/24" "172.30.0.0/30")

# Routing table IDs (one per WAN)
RT_TABLE_START=101   # wan1=101, wan2=102, ...
RT_TABLE_TUNNEL=200  # table for LAN → tunnel routing

# LAN (enp6s20)
LAN_SUBNET="192.168.189.0/24"
LAN_IP="192.168.189.1"

# TUN interface created by sing-box
TUN_NAME="tun-mptcp"
TUN_ADDR="172.19.0.1/30"

# sing-box multiplex (Brutal) — set to your aggregate capacity
BRUTAL_UP=2000       # 2 WAN aggregate upload
BRUTAL_DOWN=4000     # 2 WAN aggregate download
MUX_CONNECTIONS=4    # parallel mux streams

# Fallback sing-box version
SING_BOX_VERSION="1.11.0"

# ────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
banner() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }

WAN_COUNT=${#WAN_INTERFACES[@]}

# ── Argument: Shadowsocks password ─────────────────────────────────────────
if [[ $# -lt 1 || -z "${1:-}" ]]; then
    err "Usage: sudo bash router-test.sh \"<SHADOWSOCKS_PASSWORD>\""
    err "  The password is printed at the end of vps.sh"
    exit 1
fi
SS_PASSWORD="$1"

# ── Pre-flight checks ─────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo bash router.sh ...)"
    exit 1
fi

KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)
if (( KERNEL_MAJOR < 5 || (KERNEL_MAJOR == 5 && KERNEL_MINOR < 6) )); then
    err "Kernel $(uname -r) is too old. MPTCP requires Linux 5.6+."
    exit 1
fi

banner "MPTCP Router Deployment"
log "Kernel:     $(uname -r)"
log "VPS:        ${VPS_IP}:${SS_PORT}"
log "WAN count:  ${WAN_COUNT}"
log "LAN:        ${LAN_SUBNET} (${LAN_IP})"

# Detect LAN interface
LAN_IF=$(ip -4 addr show | grep "${LAN_IP}" | awk '{print $NF}' | head -1)
if [[ -z "$LAN_IF" ]]; then
    warn "Could not auto-detect LAN interface for ${LAN_IP}"
    warn "Will skip interface-specific firewall rules"
    LAN_IF="unknown"
else
    log "LAN iface:  ${LAN_IF}"
fi

###############################################################################
# 1. System packages
###############################################################################
banner "Step 1/7 — System Update & Packages"

apt-get update -qq
apt-get install -y -qq iproute2 curl wget jq iperf3 openssl iptables > /dev/null 2>&1
log "System packages installed"

###############################################################################
# 2. MPTCP + Kernel Tuning
###############################################################################
banner "Step 2/7 — MPTCP & Kernel Tuning"

cat > /etc/sysctl.d/90-mptcp.conf << 'EOF'
# MPTCP
net.mptcp.enabled=1

# IP Forwarding (router)
net.ipv4.ip_forward=1

# TCP buffer tuning
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.core.netdev_max_backlog=50000
net.ipv4.tcp_max_syn_backlog=30000
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
EOF

sysctl -p /etc/sysctl.d/90-mptcp.conf > /dev/null 2>&1
log "MPTCP enabled, IP forwarding on, BBR congestion control"

###############################################################################
# 3. Install sing-box
###############################################################################
banner "Step 3/7 — Install sing-box"

install_singbox_apt() {
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    echo "deb [signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" \
        > /etc/apt/sources.list.d/sagernet.list
    apt-get update -qq
    apt-get install -y -qq sing-box
}

install_singbox_binary() {
    warn "APT install failed, falling back to binary download..."
    local url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"
    local tmp="/tmp/sing-box-install"
    mkdir -p "$tmp"
    wget -q -O "$tmp/sing-box.tar.gz" "$url"
    tar xzf "$tmp/sing-box.tar.gz" -C "$tmp"
    cp "$tmp"/sing-box-*/sing-box /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf "$tmp"

    if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
        cat > /etc/systemd/system/sing-box.service << 'SVCEOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
SVCEOF
    fi
}

if ! command -v sing-box &>/dev/null; then
    install_singbox_apt 2>/dev/null || install_singbox_binary
fi

mkdir -p /etc/sing-box
log "sing-box installed: $(command -v sing-box) ($(sing-box version 2>/dev/null || echo 'unknown'))"

###############################################################################
# 4. Routing tables
###############################################################################
banner "Step 4/7 — Policy Routing Tables"

# Add routing table entries if not already present
for i in $(seq 1 "$WAN_COUNT"); do
    TABLE_ID=$((RT_TABLE_START + i - 1))
    TABLE_NAME="wan${i}"
    if ! grep -q "^${TABLE_ID}" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "${TABLE_ID} ${TABLE_NAME}" >> /etc/iproute2/rt_tables
        log "Added table: ${TABLE_ID} ${TABLE_NAME}"
    fi
done

if ! grep -q "^${RT_TABLE_TUNNEL}" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "${RT_TABLE_TUNNEL} tunnel" >> /etc/iproute2/rt_tables
    log "Added table: ${RT_TABLE_TUNNEL} tunnel"
fi

###############################################################################
# 5. sing-box client config
###############################################################################
banner "Step 5/7 — sing-box Client Config"

cat > /etc/sing-box/config.json << CFGEOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "remote-dns",
        "server": "1.1.1.1",
        "server_port": 443
      },
      {
        "type": "udp",
        "tag": "local-dns",
        "server": "1.0.0.1"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "${TUN_NAME}",
      "address": ["${TUN_ADDR}"],
      "auto_route": false,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "proxy",
      "server": "${VPS_IP}",
      "server_port": ${SS_PORT},
      "method": "${SS_METHOD}",
      "password": "${SS_PASSWORD}",
      "tcp_multi_path": true,
      "udp_over_tcp": true,
      "domain_resolver": "local-dns",
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": ${MUX_CONNECTIONS},
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": ${BRUTAL_UP},
          "down_mbps": ${BRUTAL_DOWN}
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "remote-dns"
  }
}
CFGEOF

if sing-box check -c /etc/sing-box/config.json 2>/dev/null; then
    log "sing-box config validated ✓"
else
    warn "sing-box config check returned non-zero (may still work)"
fi

###############################################################################
# 6. MPTCP routing script (runs at boot & on demand)
###############################################################################
banner "Step 6/7 — MPTCP Routing & Endpoints Script"

cat > /usr/local/bin/mptcp-setup.sh << 'ROUTEEOF'
#!/bin/bash
###############################################################################
# MPTCP endpoint + policy routing setup
# Auto-generated by router.sh — do not edit manually
###############################################################################
set -e

log()  { echo "[MPTCP] $*"; }

ROUTEEOF

# Inject variables into the routing script
cat >> /usr/local/bin/mptcp-setup.sh << EOF
WAN_INTERFACES=(${WAN_INTERFACES[@]})
WAN_IPS=(${WAN_IPS[@]})
WAN_GATEWAYS=(${WAN_GATEWAYS[@]})
WAN_SUBNETS=(${WAN_SUBNETS[@]})
WAN_COUNT=${WAN_COUNT}
RT_TABLE_START=${RT_TABLE_START}
RT_TABLE_TUNNEL=${RT_TABLE_TUNNEL}
VPS_IP="${VPS_IP}"
TUN_NAME="${TUN_NAME}"
LAN_SUBNET="${LAN_SUBNET}"
EOF

cat >> /usr/local/bin/mptcp-setup.sh << 'ROUTEEOF'

# ── Enable MPTCP ──
sysctl -w net.mptcp.enabled=1 > /dev/null 2>&1

# ── Flush & re-add MPTCP endpoints ──
ip mptcp endpoint flush
for i in $(seq 0 $((WAN_COUNT - 1))); do
    ip mptcp endpoint add "${WAN_IPS[$i]}" dev "${WAN_INTERFACES[$i]}" subflow
    log "Endpoint: ${WAN_IPS[$i]} dev ${WAN_INTERFACES[$i]}"
done
ip mptcp limits set subflow "$WAN_COUNT" add_addr_accepted "$WAN_COUNT"
log "Limits: subflow=${WAN_COUNT}, add_addr_accepted=${WAN_COUNT}"

# ── Per-WAN policy routing ──
for i in $(seq 0 $((WAN_COUNT - 1))); do
    TABLE=$((RT_TABLE_START + i))
    DEV="${WAN_INTERFACES[$i]}"
    IP="${WAN_IPS[$i]}"
    GW="${WAN_GATEWAYS[$i]}"
    SUBNET="${WAN_SUBNETS[$i]}"

    ip route replace "$SUBNET" dev "$DEV" scope link table "$TABLE" 2>/dev/null || true
    ip route replace default via "$GW" dev "$DEV" table "$TABLE" 2>/dev/null || true
    ip rule del from "$IP" table "$TABLE" 2>/dev/null || true
    ip rule add from "$IP" table "$TABLE" priority "$TABLE"
    log "Route table ${TABLE}: ${IP} → ${GW} dev ${DEV}"
done

# ── Default route (WAN1 for initial MPTCP handshake) ──
ip route replace default via "${WAN_GATEWAYS[0]}" dev "${WAN_INTERFACES[0]}" metric 100
log "Default route: ${WAN_GATEWAYS[0]} dev ${WAN_INTERFACES[0]}"

# ── VPS direct route (bypass tunnel) ──
ip route replace "${VPS_IP}/32" via "${WAN_GATEWAYS[0]}" dev "${WAN_INTERFACES[0]}"
log "VPS direct route: ${VPS_IP} via ${WAN_GATEWAYS[0]}"

# ── Wait for TUN interface ──
log "Waiting for ${TUN_NAME} interface..."
for attempt in $(seq 1 60); do
    if ip link show "$TUN_NAME" &>/dev/null; then
        log "${TUN_NAME} is up (waited ${attempt}s)"
        break
    fi
    sleep 1
done

if ! ip link show "$TUN_NAME" &>/dev/null; then
    log "ERROR: ${TUN_NAME} not found after 60s. sing-box may have failed."
    log "Check: journalctl -u sing-box -n 30"
    exit 1
fi

# ── LAN → Tunnel routing ──
ip route replace default dev "$TUN_NAME" table "$RT_TABLE_TUNNEL" 2>/dev/null || true

# Local subnets stay local (higher priority = checked first)
ip rule del to "$LAN_SUBNET" table main 2>/dev/null || true
ip rule add to "$LAN_SUBNET" table main priority 40

# Exclude each WAN subnet from tunnel routing
PRIO=41
for subnet in "${WAN_SUBNETS[@]}"; do
    ip rule del to "$subnet" table main 2>/dev/null || true
    ip rule add to "$subnet" table main priority "$PRIO"
    PRIO=$((PRIO + 1))
done

# TUN address itself
ip rule del to 172.19.0.0/30 table main 2>/dev/null || true
ip rule add to 172.19.0.0/30 table main priority 49

# LAN traffic → tunnel
ip rule del from "$LAN_SUBNET" table "$RT_TABLE_TUNNEL" 2>/dev/null || true
ip rule add from "$LAN_SUBNET" table "$RT_TABLE_TUNNEL" priority 50

log "LAN ${LAN_SUBNET} → ${TUN_NAME} → VPS"

# ── Summary ──
log "──────────────────────────────────────"
log "MPTCP endpoints:"
ip mptcp endpoint show 2>/dev/null | while read -r line; do log "  $line"; done
log "MPTCP limits:"
ip mptcp limits show 2>/dev/null | while read -r line; do log "  $line"; done
log "──────────────────────────────────────"
log "Setup complete at $(date)"
ROUTEEOF

chmod +x /usr/local/bin/mptcp-setup.sh
log "Created /usr/local/bin/mptcp-setup.sh"

###############################################################################
# 7. NAT, firewall, systemd, start everything
###############################################################################
banner "Step 7/7 — NAT, Firewall & Start Services"

# ── NAT ──
# Flush to avoid duplicates
iptables -t nat -F POSTROUTING 2>/dev/null || true

# LAN → tunnel NAT
iptables -t nat -A POSTROUTING -s "${LAN_SUBNET}" -o "${TUN_NAME}" -j MASQUERADE

# Allow forwarding
iptables -P FORWARD ACCEPT

if [[ "$LAN_IF" != "unknown" ]]; then
    # Explicit forward rules (optional, FORWARD ACCEPT already covers this)
    iptables -A FORWARD -i "${LAN_IF}" -o "${TUN_NAME}" -j ACCEPT
    iptables -A FORWARD -i "${TUN_NAME}" -o "${LAN_IF}" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# Persist
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save > /dev/null 2>&1
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent > /dev/null 2>&1
    netfilter-persistent save > /dev/null 2>&1
fi
log "NAT: ${LAN_SUBNET} → ${TUN_NAME} (MASQUERADE)"

# ── UFW ──
if command -v ufw &>/dev/null; then
    ufw allow ssh > /dev/null 2>&1
    if [[ "$LAN_IF" != "unknown" ]]; then
        ufw allow in on "${LAN_IF}" from "${LAN_SUBNET}" > /dev/null 2>&1
    fi
    ufw --force enable > /dev/null 2>&1
    log "UFW configured"
fi

# ── Systemd: MPTCP routing service ──
cat > /etc/systemd/system/mptcp-routing.service << EOF
[Unit]
Description=MPTCP Policy Routing & Endpoint Setup
After=network-online.target sing-box.service
Wants=network-online.target sing-box.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 3
ExecStart=/usr/local/bin/mptcp-setup.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box > /dev/null 2>&1
systemctl enable mptcp-routing > /dev/null 2>&1

# ── Start sing-box ──
log "Starting sing-box..."
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    log "sing-box is running ✓"
else
    err "sing-box failed to start!"
    journalctl -u sing-box -n 15 --no-pager
    exit 1
fi

# ── Run MPTCP routing setup ──
log "Running MPTCP routing setup..."
/usr/local/bin/mptcp-setup.sh

###############################################################################
# Verification
###############################################################################
banner "Verification"

echo -e "${BOLD}MPTCP Endpoints:${NC}"
ip mptcp endpoint show

echo ""
echo -e "${BOLD}MPTCP Limits:${NC}"
ip mptcp limits show

echo ""
echo -e "${BOLD}Routing Rules (top 15):${NC}"
ip rule show | head -15

echo ""
echo -e "${BOLD}MPTCP Connections:${NC}"
ss -M 2>/dev/null | head -10 || echo "  (no active MPTCP connections yet — generate traffic to see)"

echo ""
echo -e "${BOLD}WAN Source Routing Test:${NC}"
for i in $(seq 0 $((WAN_COUNT - 1))); do
    RESULT=$(ip route get "${VPS_IP}" from "${WAN_IPS[$i]}" 2>/dev/null | head -1)
    echo "  WAN$((i+1)): ${RESULT}"
done

###############################################################################
# Done
###############################################################################
banner "Router Deployment Complete ✅"

echo -e "${BOLD}┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│  Next Steps                                                  │${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}  1. From a LAN client, verify exit IP:                       ${NC}"
echo -e "${BOLD}│${NC}     ${CYAN}curl ifconfig.me${NC}  → should show VPS IP               "
echo -e "${BOLD}│${NC}                                                               "
echo -e "${BOLD}│${NC}  2. Bandwidth test (VPS side first):                          "
echo -e "${BOLD}│${NC}     VPS:    ${CYAN}iperf3 -s${NC}                                     "
echo -e "${BOLD}│${NC}     Router: ${CYAN}iperf3 -c ${VPS_IP} -P 10 -t 20${NC}               "
echo -e "${BOLD}│${NC}                                                               "
echo -e "${BOLD}│${NC}  3. Watch MPTCP subflows:                                     "
echo -e "${BOLD}│${NC}     ${CYAN}ss -tiM${NC}                                               "
echo -e "${BOLD}│${NC}     ${CYAN}ip mptcp monitor${NC}                                      "
echo -e "${BOLD}│${NC}                                                               "
echo -e "${BOLD}│${NC}  4. Monitor WAN interfaces:                                   "
echo -e "${BOLD}│${NC}     ${CYAN}bmon${NC}  or  ${CYAN}nload${NC}                                       "
echo -e "${BOLD}│${NC}                                                               "
echo -e "${BOLD}│${NC}  5. Re-run routing (if needed):                               "
echo -e "${BOLD}│${NC}     ${CYAN}sudo /usr/local/bin/mptcp-setup.sh${NC}                     "
echo -e "${BOLD}│${NC}                                                               "
echo -e "${BOLD}│${NC}  6. Emergency — disable tunnel routing:                       "
echo -e "${BOLD}│${NC}     ${CYAN}sudo ip rule del from ${LAN_SUBNET} table ${RT_TABLE_TUNNEL}${NC}  "
echo -e "${BOLD}└──────────────────────────────────────────────────────────────┘${NC}"
