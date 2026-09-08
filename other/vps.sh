#!/bin/bash
###############################################################################
#  MPTCP VPS Deployment Script
#  Run on: VPS (103.52.108.174)
#  Usage:  sudo bash vps.sh
#
#  This script will:
#    1. Enable MPTCP in the kernel
#    2. Install sing-box
#    3. Generate a Shadowsocks 2022 password
#    4. Deploy sing-box server config
#    5. Configure NAT / IP forwarding
#    6. Set up firewall (ufw)
#    7. Create systemd services for persistence
#
#  At the end it prints the password you need for router.sh
###############################################################################

set -euo pipefail

# ─────────────────────────── Configuration ──────────────────────────────────
VPS_INTERFACE="enp1s0"          # Public-facing interface on VPS
SS_PORT=8388                    # Shadowsocks listen port
SS_METHOD="2022-blake3-aes-256-gcm"
MPTCP_SUBFLOW_LIMIT=8
SING_BOX_VERSION="1.11.0"      # Fallback if apt repo fails

# Brutal multiplex bandwidth caps (Mbps) — set to your VPS NIC capacity
BRUTAL_UP=20000
BRUTAL_DOWN=20000
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

# ── Pre-flight checks ──────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo bash vps.sh)"
    exit 1
fi

KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)
if (( KERNEL_MAJOR < 5 || (KERNEL_MAJOR == 5 && KERNEL_MINOR < 6) )); then
    err "Kernel $(uname -r) is too old. MPTCP requires Linux 5.6+."
    err "Upgrade your kernel first:  sudo apt install linux-generic-hwe-$(lsb_release -rs)"
    exit 1
fi

banner "MPTCP VPS Deployment"
log "Kernel: $(uname -r)"
log "Interface: ${VPS_INTERFACE}"
log "Shadowsocks port: ${SS_PORT}"

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

# IP Forwarding (NAT for tunnel clients)
net.ipv4.ip_forward=1

# TCP buffer tuning for high throughput
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

# MPTCP limits
ip mptcp limits set subflow ${MPTCP_SUBFLOW_LIMIT} add_addr_accepted ${MPTCP_SUBFLOW_LIMIT}
log "MPTCP limits: subflow=${MPTCP_SUBFLOW_LIMIT}, add_addr_accepted=${MPTCP_SUBFLOW_LIMIT}"

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

    # Create systemd service if it doesn't exist
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
SING_BOX_PATH=$(command -v sing-box)
log "sing-box installed: ${SING_BOX_PATH} ($(sing-box version 2>/dev/null || echo 'unknown'))"

###############################################################################
# 4. Generate Shadowsocks password
###############################################################################
banner "Step 4/7 — Generate Credentials"

SS_PASSWORD_FILE="/etc/sing-box/.ss_password"

if [[ -f "$SS_PASSWORD_FILE" ]]; then
    SS_PASSWORD=$(cat "$SS_PASSWORD_FILE")
    warn "Reusing existing password from ${SS_PASSWORD_FILE}"
else
    SS_PASSWORD=$(openssl rand -base64 32)
    echo -n "$SS_PASSWORD" > "$SS_PASSWORD_FILE"
    chmod 600 "$SS_PASSWORD_FILE"
    log "Generated new Shadowsocks password"
fi

###############################################################################
# 5. Deploy sing-box config
###############################################################################
banner "Step 5/7 — sing-box Server Config"

cat > /etc/sing-box/config.json << CFGEOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${SS_PORT},
      "method": "${SS_METHOD}",
      "password": "${SS_PASSWORD}",
      "tcp_multi_path": true,
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": ${BRUTAL_UP},
          "down_mbps": ${BRUTAL_DOWN}
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
CFGEOF

# Validate config
if sing-box check -c /etc/sing-box/config.json 2>/dev/null; then
    log "sing-box config validated ✓"
else
    warn "sing-box config check returned non-zero (may still work on older versions)"
fi

###############################################################################
# 6. NAT / Firewall
###############################################################################
banner "Step 6/7 — NAT & Firewall"

# Flush existing NAT rules to avoid duplicates
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -t nat -A POSTROUTING -o "${VPS_INTERFACE}" -j MASQUERADE

# Allow forwarding
iptables -P FORWARD ACCEPT

# Persist iptables
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save > /dev/null 2>&1
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent > /dev/null 2>&1
    netfilter-persistent save > /dev/null 2>&1
fi
log "NAT masquerade on ${VPS_INTERFACE}"

# UFW (non-destructive — only add rules)
if command -v ufw &>/dev/null; then
    ufw allow ssh > /dev/null 2>&1
    ufw allow "${SS_PORT}/tcp" > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    log "UFW: SSH + port ${SS_PORT}/tcp allowed"
else
    warn "ufw not found, skipping firewall setup"
fi

###############################################################################
# 7. Systemd persistence
###############################################################################
banner "Step 7/7 — Systemd Services"

# MPTCP limits persistence service
cat > /etc/systemd/system/mptcp-limits.service << EOF
[Unit]
Description=MPTCP Limits Configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip mptcp limits set subflow ${MPTCP_SUBFLOW_LIMIT} add_addr_accepted ${MPTCP_SUBFLOW_LIMIT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mptcp-limits --now > /dev/null 2>&1
systemctl enable sing-box > /dev/null 2>&1
systemctl restart sing-box

# Verify sing-box is running
sleep 2
if systemctl is-active --quiet sing-box; then
    log "sing-box is running ✓"
else
    err "sing-box failed to start! Check: journalctl -u sing-box -n 30"
    journalctl -u sing-box -n 10 --no-pager
fi

log "mptcp-limits.service enabled ✓"

###############################################################################
# Done — Print summary
###############################################################################
VPS_IP=$(ip -4 addr show "${VPS_INTERFACE}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

banner "VPS Deployment Complete ✅"

echo -e "${BOLD}┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│  Connection Details (SAVE THESE for router.sh)              │${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}  VPS IP:      ${CYAN}${VPS_IP}${NC}"
echo -e "${BOLD}│${NC}  Port:        ${CYAN}${SS_PORT}${NC}"
echo -e "${BOLD}│${NC}  Method:      ${CYAN}${SS_METHOD}${NC}"
echo -e "${BOLD}│${NC}  Password:    ${CYAN}${SS_PASSWORD}${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}  ${YELLOW}Run on router:${NC}"
echo -e "${BOLD}│${NC}  ${GREEN}sudo bash router.sh \"${SS_PASSWORD}\"${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${YELLOW}Verify:${NC}"
echo "  ss -tlnp | grep ${SS_PORT}"
echo "  journalctl -u sing-box -f"
echo "  ip mptcp limits show"
