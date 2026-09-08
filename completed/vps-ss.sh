#!/bin/bash
###############################################################################
#  MPTCP VPS Deployment — shadowsocks-rust
#  Run on: VPS (Debian 12 / Ubuntu 22.04+)
#  Usage:  sudo bash vps-ss.sh
#
#  This script will:
#    1. Enable MPTCP + kernel tuning (large buffers)
#    2. Install shadowsocks-rust (ssserver)
#    3. Generate Shadowsocks 2022 password
#    4. Configure ssserver with MPTCP
#    5. NAT + firewall
#    6. Systemd persistence
###############################################################################

set -euo pipefail

# ─────────────────────────── Configuration ──────────────────────────────────
SS_PORT=8389                          # Different port from sing-box (8388)
SS_METHOD="2022-blake3-aes-128-gcm"
VPS_INTERFACE="enX0"
MPTCP_SUBFLOW_LIMIT=24
# ────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[✗]${NC} $*" >&2; }
banner() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }

if [[ $EUID -ne 0 ]]; then err "Run as root: sudo bash vps-ss.sh"; exit 1; fi

KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)
if (( KERNEL_MAJOR < 5 || (KERNEL_MAJOR == 5 && KERNEL_MINOR < 6) )); then
    err "Kernel $(uname -r) too old. MPTCP requires Linux 5.6+."; exit 1
fi

banner "MPTCP VPS Deployment (shadowsocks-rust)"
log "Kernel: $(uname -r)"
log "Interface: ${VPS_INTERFACE}"
log "Port: ${SS_PORT}"

###############################################################################
# 1. System packages
###############################################################################
banner "Step 1/6 — System Update & Packages"
#apt-get update -qq
#apt-get install -y -qq iproute2 curl wget jq iperf3 openssl iptables xz-utils > /dev/null 2>&1
log "System packages installed"

###############################################################################
# 2. MPTCP + Kernel Tuning
###############################################################################
banner "Step 2/6 — MPTCP & Kernel Tuning"

cat > /etc/sysctl.d/90-mptcp.conf << 'EOF'
net.mptcp.enabled=1
net.ipv4.ip_forward=1

# ── TCP Buffers (MPTCP aggregation) ──
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 1048576 134217728
net.ipv4.tcp_wmem=4096 1048576 134217728
net.ipv4.tcp_mem=786432 1048576 1572864

# ── Backlog & Connection Handling ──
net.core.netdev_max_backlog=50000
net.ipv4.tcp_max_syn_backlog=30000
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq

# ── Reduce softirq overhead ──
# Process more packets per softirq cycle (default 300 → 600)
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000

# Busy polling — reduce context switches for high-throughput
net.core.busy_read=50
net.core.busy_poll=50

# ── Tolerate MPTCP reordering ──
net.ipv4.tcp_reordering=127

# ── Timestamps off = less per-packet CPU work ──
net.ipv4.tcp_timestamps=0
EOF

sysctl -p /etc/sysctl.d/90-mptcp.conf > /dev/null 2>&1
ip mptcp limits set subflow ${MPTCP_SUBFLOW_LIMIT} add_addr_accepted ${MPTCP_SUBFLOW_LIMIT}
log "MPTCP enabled, large buffers, BBR, reordering tolerance"

# ── NIC offloads & RPS/RFS (spread softirq across all cores) ──
NUM_CPUS=$(nproc)
CPU_MASK=$(printf '%x' $(( (1 << NUM_CPUS) - 1 )))

# Enable all hardware offloads on the NIC
ethtool -K "${VPS_INTERFACE}" gro on gso on tso on rx-gro-list off 2>/dev/null || true
log "NIC offloads enabled (GRO/GSO/TSO)"

# RPS: Distribute received packets across ALL cores (reduces softirq hotspot)
for rxq in /sys/class/net/${VPS_INTERFACE}/queues/rx-*/rps_cpus; do
    echo "$CPU_MASK" > "$rxq" 2>/dev/null || true
done

# RFS: Flow-based steering (keeps a flow on the same core = cache-friendly)
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
for rxq in /sys/class/net/${VPS_INTERFACE}/queues/rx-*/rps_flow_cnt; do
    echo $((32768 / $(ls -d /sys/class/net/${VPS_INTERFACE}/queues/rx-* | wc -l) )) > "$rxq" 2>/dev/null || true
done
log "RPS/RFS configured: distributing softirq across ${NUM_CPUS} cores (mask 0x${CPU_MASK})"

###############################################################################
# 3. Install shadowsocks-rust
###############################################################################
banner "Step 3/6 — Install shadowsocks-rust"

install_ssrust() {
    local VERSION TMP="/tmp/ssrust-install"

    VERSION=$(curl -sL "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"v\(.*\)".*/\1/') || true
    if [[ -z "$VERSION" ]]; then
        VERSION="1.21.2"
        warn "GitHub API failed, using fallback version ${VERSION}"
    fi

    log "Downloading shadowsocks-rust v${VERSION}..."
    local URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${VERSION}/shadowsocks-v${VERSION}.x86_64-unknown-linux-gnu.tar.xz"

    rm -rf "$TMP" && mkdir -p "$TMP"
    if ! wget -q --show-progress -O "$TMP/ss.tar.xz" "$URL"; then
        err "Download failed: ${URL}"
        err "Try manually: wget -O /tmp/ss.tar.xz '${URL}'"
        exit 1
    fi

    if ! tar xJf "$TMP/ss.tar.xz" -C "$TMP" 2>&1; then
        err "tar extraction failed — file may be corrupt"
        exit 1
    fi

    # Handle both flat and nested archive layouts
    local SSSERVER=""
    SSSERVER=$(find "$TMP" -name "ssserver" -type f | head -1)
    if [[ -z "$SSSERVER" ]]; then
        err "ssserver binary not found in archive. Contents:"
        find "$TMP" -type f | head -20 >&2
        exit 1
    fi

    cp "$SSSERVER" /usr/local/bin/ssserver
    chmod +x /usr/local/bin/ssserver

    local SSLOCAL
    SSLOCAL=$(find "$TMP" -name "sslocal" -type f | head -1)
    [[ -n "$SSLOCAL" ]] && cp "$SSLOCAL" /usr/local/bin/sslocal && chmod +x /usr/local/bin/sslocal

    rm -rf "$TMP"

    if ! /usr/local/bin/ssserver --version &>/dev/null; then
        err "ssserver installed but won't run — wrong architecture?"
        exit 1
    fi
    log "Installed: $(ssserver --version 2>/dev/null)"
}

if ! command -v ssserver &>/dev/null; then
    install_ssrust
else
    log "ssserver already installed: $(ssserver --version 2>/dev/null)"
fi

###############################################################################
# 4. Generate password & config
###############################################################################
banner "Step 4/6 — Generate Password & Config"

SS_PASSWORD=$(openssl rand -base64 16)
log "Generated Shadowsocks password"

mkdir -p /etc/shadowsocks-rust
cat > /etc/shadowsocks-rust/config.json << EOF
{
    "server": "::",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "mptcp": true,
    "no_delay": true,
    "tcp_keep_alive": 15,
    "mode": "tcp_and_udp"
}
EOF

log "Config written to /etc/shadowsocks-rust/config.json"

###############################################################################
# 5. NAT & Firewall
###############################################################################
banner "Step 5/6 — NAT & Firewall"

iptables -t nat -C POSTROUTING -o "${VPS_INTERFACE}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "${VPS_INTERFACE}" -j MASQUERADE
iptables -P FORWARD ACCEPT

if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save > /dev/null 2>&1
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent > /dev/null 2>&1
    netfilter-persistent save > /dev/null 2>&1
fi
log "NAT: MASQUERADE on ${VPS_INTERFACE}"

if command -v ufw &>/dev/null; then
    ufw allow ssh > /dev/null 2>&1
    ufw allow "${SS_PORT}/tcp" > /dev/null 2>&1
    ufw allow "${SS_PORT}/udp" > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    log "UFW: allowed SSH + ${SS_PORT}"
fi

###############################################################################
# 6. Systemd service
###############################################################################
banner "Step 6/6 — Systemd Service"

# Stop sing-box if running on same port
if systemctl is-active --quiet sing-box 2>/dev/null; then
    warn "sing-box is running — keeping it (different port ${SS_PORT})"
fi

cat > /etc/systemd/system/ssserver-mptcp.service << 'EOF'
[Unit]
Description=Shadowsocks-Rust Server (MPTCP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ssserver-mptcp > /dev/null 2>&1
systemctl restart ssserver-mptcp
sleep 2

if systemctl is-active --quiet ssserver-mptcp; then
    log "ssserver-mptcp is running ✓"
else
    err "ssserver-mptcp failed to start!"
    journalctl -u ssserver-mptcp -n 15 --no-pager
    exit 1
fi

###############################################################################
# Done
###############################################################################
banner "VPS Deployment Complete ✅"

echo -e "${BOLD}┌────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│${NC}  Shadowsocks-Rust Server (MPTCP)                          ${BOLD}│${NC}"
echo -e "${BOLD}├────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}  Port:     ${CYAN}${SS_PORT}${NC}                                           ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  Method:   ${CYAN}${SS_METHOD}${NC}        ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  Password: ${CYAN}${SS_PASSWORD}${NC}  ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}                                                            ${BOLD}│${NC}"
echo -e "${BOLD}│${NC}  ${YELLOW}Copy the password above to use in router-ss.sh${NC}             ${BOLD}│${NC}"
echo -e "${BOLD}└────────────────────────────────────────────────────────────┘${NC}"
