#!/bin/bash
###############################################################################
#  MPTCP Router Deployment — shadowsocks-rust
#  Run on: Router (Ubuntu)
#  Usage:  sudo bash router-ss.sh "<SHADOWSOCKS_PASSWORD>"
#
#  The password is printed at the end of vps-ss.sh — copy-paste it here.
#
#  This script will:
#    1. Enable MPTCP + kernel tuning (large buffers)
#    2. Install shadowsocks-rust (sslocal)
#    3. Create policy routing tables (1 per WAN)
#    4. Deploy sslocal config (TUN + MPTCP)
#    5. Configure MPTCP endpoints (fullmesh)
#    6. Route LAN traffic through tunnel
#    7. NAT, firewall, systemd persistence
###############################################################################

set -euo pipefail

# ─────────────────────────── Configuration ──────────────────────────────────

# VPS details
VPS_IP="103.52.108.174"
SS_PORT=8389
SS_METHOD="2022-blake3-aes-128-gcm"

WAN_INTERFACES=("eth3" "eth6" "eth4" "eth5" "eth7")
WAN_IPS=("192.168.1.4" "192.168.170.4" "192.168.150.4" "192.168.160.4" "192.168.180.4")
WAN_GATEWAYS=("192.168.1.1" "192.168.170.1" "192.168.150.1" "192.168.160.1" "192.168.180.1")
WAN_SUBNETS=("192.168.1.0/24" "192.168.170.0/24" "192.168.150.0/24" "192.168.160.0/24" "192.168.180.0/24")

# Routing table IDs
RT_TABLE_START=101
RT_TABLE_TUNNEL=200

# LAN
LAN_SUBNET="10.100.0.0/24"
LAN_IP="10.100.0.1"


# ────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[✗]${NC} $*" >&2; }
banner() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }

WAN_COUNT=${#WAN_INTERFACES[@]}

if [[ $# -lt 1 || -z "${1:-}" ]]; then
    err "Usage: sudo bash router-ss.sh \"<SHADOWSOCKS_PASSWORD>\""
    err "  The password is printed at the end of vps-ss.sh"
    exit 1
fi
SS_PASSWORD="$1"

if [[ $EUID -ne 0 ]]; then err "Run as root"; exit 1; fi

KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)
if (( KERNEL_MAJOR < 5 || (KERNEL_MAJOR == 5 && KERNEL_MINOR < 6) )); then
    err "Kernel $(uname -r) too old."; exit 1
fi

banner "MPTCP Router Deployment (shadowsocks-rust)"
log "Kernel:     $(uname -r)"
log "VPS:        ${VPS_IP}:${SS_PORT}"
log "WAN count:  ${WAN_COUNT}"
log "LAN:        ${LAN_SUBNET} (${LAN_IP})"

LAN_IF=$(ip -4 addr show | grep "${LAN_IP}" | awk '{print $NF}' | head -1)
[[ -z "$LAN_IF" ]] && LAN_IF="unknown" || log "LAN iface:  ${LAN_IF}"

###############################################################################
# 1. System packages
###############################################################################
banner "Step 1/7 — System Update & Packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 curl wget jq iperf3 openssl iptables xz-utils ethtool sysstat ipset > /dev/null 2>&1
log "System packages installed"

###############################################################################
# 2. MPTCP + Kernel Tuning
###############################################################################
banner "Step 2/7 — MPTCP & Kernel Tuning"

cat > /etc/sysctl.d/90-mptcp.conf << 'EOF'
net.mptcp.enabled=1
net.ipv4.ip_forward=1

# ── TCP Buffers (BDP-sized: 64M covers ~5Gbps @ 100ms) ──
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 1048576 67108864
net.ipv4.tcp_wmem=4096 1048576 67108864
net.ipv4.tcp_mem=262144 349525 524288

# ── Backlog & Connection Handling ──
net.core.netdev_max_backlog=50000
net.ipv4.tcp_max_syn_backlog=30000
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq

# ── Reduce softirq overhead ──
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000
net.core.busy_read=10
net.core.busy_poll=10

# ── Conntrack tuning ──
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=600
net.netfilter.nf_conntrack_buckets=65536

# ── Reuse routes quickly ──
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3

# ── Tolerate MPTCP reordering ──
net.ipv4.tcp_reordering=127

# ── Timestamps off = less per-packet CPU ──
net.ipv4.tcp_timestamps=0
EOF

sysctl -p /etc/sysctl.d/90-mptcp.conf > /dev/null 2>&1
log "MPTCP enabled, large buffers, BBR"

# ── NIC offloads & RPS/RFS for all WAN + LAN interfaces ──
NUM_CPUS=$(nproc)
CPU_MASK=$(printf '%x' $(( (1 << NUM_CPUS) - 1 )))

ALL_IFACES=("${WAN_INTERFACES[@]}")
[[ "$LAN_IF" != "unknown" ]] && ALL_IFACES+=("$LAN_IF")

for IFACE in "${ALL_IFACES[@]}"; do
    ethtool -G "$IFACE" rx 4096 tx 4096 2>/dev/null || true
    ethtool -C "$IFACE" adaptive-rx on 2>/dev/null || true
    ethtool -K "$IFACE" gro on gso on tso on rx-gro-list off 2>/dev/null || true
    for rxq in /sys/class/net/${IFACE}/queues/rx-*/rps_cpus; do
        echo "$CPU_MASK" > "$rxq" 2>/dev/null || true
    done
    RXQ_COUNT=$(ls -d /sys/class/net/${IFACE}/queues/rx-* 2>/dev/null | wc -l)
    if (( RXQ_COUNT > 0 )); then
        for rxq in /sys/class/net/${IFACE}/queues/rx-*/rps_flow_cnt; do
            echo $((32768 / RXQ_COUNT)) > "$rxq" 2>/dev/null || true
        done
    fi
    # XPS: TX was single-core before; map each TX queue to a core
    TXQ_IDX=0
    for txq in /sys/class/net/${IFACE}/queues/tx-*/xps_cpus; do
        TX_MASK=$(printf '%x' $(( 1 << (TXQ_IDX % NUM_CPUS) )))
        echo "$TX_MASK" > "$txq" 2>/dev/null || true
        TXQ_IDX=$((TXQ_IDX + 1))
    done
done
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
log "RPS/RFS/XPS + rings + NIC offloads on ${#ALL_IFACES[@]} interfaces (${NUM_CPUS} cores, mask 0x${CPU_MASK})"

###############################################################################
# 3. Install shadowsocks-rust
###############################################################################
banner "Step 3/7 — Install shadowsocks-rust"

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
    local SSLOCAL=""
    SSLOCAL=$(find "$TMP" -name "sslocal" -type f | head -1)
    if [[ -z "$SSLOCAL" ]]; then
        err "sslocal binary not found in archive. Contents:"
        find "$TMP" -type f | head -20 >&2
        exit 1
    fi

    cp "$SSLOCAL" /usr/local/bin/sslocal
    chmod +x /usr/local/bin/sslocal

    # Also grab ssserver if present
    local SSSERVER
    SSSERVER=$(find "$TMP" -name "ssserver" -type f | head -1)
    [[ -n "$SSSERVER" ]] && cp "$SSSERVER" /usr/local/bin/ssserver && chmod +x /usr/local/bin/ssserver

    rm -rf "$TMP"

    if ! /usr/local/bin/sslocal --version &>/dev/null; then
        err "sslocal installed but won't run — wrong architecture?"
        exit 1
    fi
    log "Installed: $(sslocal --version 2>/dev/null)"
}

if ! command -v sslocal &>/dev/null; then
    install_ssrust
else
    log "sslocal already installed: $(sslocal --version 2>/dev/null)"
fi

###############################################################################
# 4. Policy routing tables
###############################################################################
banner "Step 4/7 — Policy Routing Tables"

for i in $(seq 1 "$WAN_COUNT"); do
    TABLE_ID=$((RT_TABLE_START + i - 1))
    TABLE_NAME="wan${i}"
    if ! grep -q "^${TABLE_ID}" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "${TABLE_ID} ${TABLE_NAME}" >> /etc/iproute2/rt_tables
        log "Added table: ${TABLE_ID} ${TABLE_NAME}"
    fi
done

###############################################################################
# 5. sslocal config (REDIR mode + MPTCP — no TUN overhead)
###############################################################################
banner "Step 5/7 — sslocal Config"

REDIR_PORT=60080

mkdir -p /etc/shadowsocks-rust

cat > /etc/shadowsocks-rust/config.json << EOF
{
    "locals": [
        {
            "local_address": "0.0.0.0",
            "local_port": ${REDIR_PORT},
            "protocol": "redir",
            "tcp_redir": "redirect"
        }
    ],
    "server": "${VPS_IP}",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "mptcp": true,
    "no_delay": true,
    "tcp_keep_alive": 30
}
EOF

log "sslocal config: REDIR mode (port ${REDIR_PORT}) + MPTCP"

###############################################################################
# 6. MPTCP routing script
###############################################################################
banner "Step 6/7 — MPTCP Routing & Endpoints Script"

cat > /usr/local/bin/mptcp-setup.sh << 'ROUTEEOF'
#!/bin/bash
set -e
log() { echo "[MPTCP] $*"; }
ROUTEEOF

cat >> /usr/local/bin/mptcp-setup.sh << EOF
WAN_INTERFACES=(${WAN_INTERFACES[@]})
WAN_IPS=(${WAN_IPS[@]})
WAN_GATEWAYS=(${WAN_GATEWAYS[@]})
WAN_SUBNETS=(${WAN_SUBNETS[@]})
WAN_COUNT=${WAN_COUNT}
RT_TABLE_START=${RT_TABLE_START}
VPS_IP="${VPS_IP}"
SS_PORT=${SS_PORT}
LAN_SUBNET="${LAN_SUBNET}"
LAN_IF="${LAN_IF}"
REDIR_PORT=${REDIR_PORT}
EOF

cat >> /usr/local/bin/mptcp-setup.sh << 'ROUTEEOF'

sysctl -w net.mptcp.enabled=1 > /dev/null 2>&1

# ── MPTCP endpoints with fullmesh ──
ip mptcp endpoint flush
for i in $(seq 0 $((WAN_COUNT - 1))); do
    ip mptcp endpoint add "${WAN_IPS[$i]}" dev "${WAN_INTERFACES[$i]}" subflow fullmesh
    log "Endpoint: ${WAN_IPS[$i]} dev ${WAN_INTERFACES[$i]} (fullmesh)"
done
# Kernel 6.8 max is 8 (MPTCP_SUBFLOWS_MAX) — cap to avoid "limit greater than maximum"
MPTCP_LIMIT=$((WAN_COUNT * 2))
(( MPTCP_LIMIT > 8 )) && MPTCP_LIMIT=8
ip mptcp limits set subflow "$MPTCP_LIMIT" add_addr_accepted "$MPTCP_LIMIT"
log "Limits: subflow=${MPTCP_LIMIT}, add_addr_accepted=${MPTCP_LIMIT} (kernel max=8)"

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

# ── Default route (WAN1 primary) ──
ip route replace default via "${WAN_GATEWAYS[0]}" dev "${WAN_INTERFACES[0]}" metric 100
log "Default route: ${WAN_GATEWAYS[0]} dev ${WAN_INTERFACES[0]}"

# ── VPS direct route: WAN1 primary + WAN2 fallback (was WAN1-only: tunnel died with eth3) ──
ip route replace "${VPS_IP}/32" via "${WAN_GATEWAYS[0]}" dev "${WAN_INTERFACES[0]}" metric 100
log "VPS direct route: ${VPS_IP} via ${WAN_GATEWAYS[0]}"
if (( WAN_COUNT > 1 )); then
    ip route del "${VPS_IP}/32" via "${WAN_GATEWAYS[1]}" dev "${WAN_INTERFACES[1]}" metric 200 2>/dev/null || true
    ip route append "${VPS_IP}/32" via "${WAN_GATEWAYS[1]}" dev "${WAN_INTERFACES[1]}" metric 200 2>/dev/null || true
    log "VPS fallback route: ${VPS_IP} via ${WAN_GATEWAYS[1]} (metric 200)"
fi

# ── ipset bypass set: 1 hash lookup replaces 7 linear PREROUTING rules ──
if command -v ipset &>/dev/null; then
    ipset create ss-bypass hash:net -exist
    ipset flush ss-bypass
    ipset add ss-bypass "$LAN_SUBNET" -exist
    for subnet in "${WAN_SUBNETS[@]}"; do
        ipset add ss-bypass "$subnet" -exist
    done
    ipset add ss-bypass "$VPS_IP" -exist
    HAVE_IPSET=1
else
    HAVE_IPSET=0
fi

# ── iptables: transparent redirect for LAN TCP traffic ──
# Clean stale rules from old TUN-based setup
iptables -F FORWARD 2>/dev/null || true
iptables -t nat -D POSTROUTING -s "$LAN_SUBNET" -o tun-mptcp -j MASQUERADE 2>/dev/null || true

# Clean old PREROUTING rules
iptables -t nat -F PREROUTING 2>/dev/null || true

if (( HAVE_IPSET )); then
    iptables -t nat -A PREROUTING -s "$LAN_SUBNET" -m set --match-set ss-bypass dst -j RETURN
else
    # Fallback when ipset is unavailable
    iptables -t nat -A PREROUTING -s "$LAN_SUBNET" -d "$LAN_SUBNET" -j RETURN
    for subnet in "${WAN_SUBNETS[@]}"; do
        iptables -t nat -A PREROUTING -s "$LAN_SUBNET" -d "$subnet" -j RETURN
    done
    iptables -t nat -A PREROUTING -s "$LAN_SUBNET" -d "$VPS_IP" -j RETURN
fi

# Redirect all other LAN TCP to sslocal
iptables -t nat -A PREROUTING -s "$LAN_SUBNET" -p tcp -j REDIRECT --to-ports "$REDIR_PORT"
log "iptables: LAN TCP → REDIRECT :${REDIR_PORT}"

# ── MSS clamp: SS+MPTCP overhead fragments full-MTU segments without this ──
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
log "iptables: TCPMSS clamp on FORWARD"

# ── Skip conntrack for tunnel traffic itself (sslocal -> VPS) ──
iptables -t raw -D OUTPUT -p tcp -d "$VPS_IP" --dport "$SS_PORT" -j NOTRACK 2>/dev/null || true
iptables -t raw -A OUTPUT -p tcp -d "$VPS_IP" --dport "$SS_PORT" -j NOTRACK 2>/dev/null || true
iptables -t raw -D PREROUTING -p tcp -s "$VPS_IP" --sport "$SS_PORT" -j NOTRACK 2>/dev/null || true
iptables -t raw -A PREROUTING -p tcp -s "$VPS_IP" --sport "$SS_PORT" -j NOTRACK 2>/dev/null || true

# ── NAT for non-TCP (UDP/ICMP) traffic going direct via WAN ──
# SNAT to fixed WAN1 IP is cheaper than MASQUERADE (skips route lookup per packet)
iptables -t nat -D POSTROUTING -s "$LAN_SUBNET" -o "${WAN_INTERFACES[0]}" -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -s "$LAN_SUBNET" -o "${WAN_INTERFACES[0]}" -j SNAT --to-source "${WAN_IPS[0]}" 2>/dev/null || true
iptables -t nat -A POSTROUTING -s "$LAN_SUBNET" -o "${WAN_INTERFACES[0]}" -j SNAT --to-source "${WAN_IPS[0]}"
log "NAT: UDP/ICMP via ${WAN_INTERFACES[0]} (SNAT to ${WAN_IPS[0]})"

# ── Forwarding ──
iptables -P FORWARD ACCEPT

log "──────────────────────────────────────"
ip mptcp endpoint show 2>/dev/null | while read -r line; do log "  $line"; done
ip mptcp limits show 2>/dev/null | while read -r line; do log "  $line"; done
log "Setup complete at $(date)"
ROUTEEOF

chmod +x /usr/local/bin/mptcp-setup.sh
log "Created /usr/local/bin/mptcp-setup.sh"

###############################################################################
# 7. Firewall, systemd, start
###############################################################################
banner "Step 7/7 — Firewall & Start Services"

# Persist iptables (will be updated after mptcp-setup.sh runs)
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save > /dev/null 2>&1
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent > /dev/null 2>&1
    netfilter-persistent save > /dev/null 2>&1
fi

# UFW
if command -v ufw &>/dev/null; then
    ufw allow ssh > /dev/null 2>&1
    [[ "$LAN_IF" != "unknown" ]] && ufw allow in on "${LAN_IF}" from "${LAN_SUBNET}" > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    log "UFW configured"
fi

# Systemd: sslocal service
cat > /etc/systemd/system/sslocal-mptcp.service << EOF
[Unit]
Description=Shadowsocks-Rust Client REDIR (MPTCP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sslocal -c /etc/shadowsocks-rust/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
CPUAffinity=0-7
Nice=-5

[Install]
WantedBy=multi-user.target
EOF

# Systemd: MPTCP routing service
cat > /etc/systemd/system/mptcp-routing.service << EOF
[Unit]
Description=MPTCP Policy Routing & Endpoint Setup
After=network-online.target sslocal-mptcp.service
Wants=network-online.target sslocal-mptcp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 3
ExecStart=/usr/local/bin/mptcp-setup.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sslocal-mptcp > /dev/null 2>&1
systemctl enable mptcp-routing > /dev/null 2>&1

# Stop sing-box if running
if systemctl is-active --quiet sing-box 2>/dev/null; then
    warn "Stopping sing-box..."
    systemctl stop sing-box
    systemctl disable sing-box > /dev/null 2>&1
fi

# Clean up old TUN device if present
ip link del tun-mptcp 2>/dev/null || true

# Remove old TUN routing rules
ip rule del from "${LAN_SUBNET}" table 200 2>/dev/null || true

# Start
log "Starting sslocal-mptcp..."
systemctl restart sslocal-mptcp
sleep 2

if systemctl is-active --quiet sslocal-mptcp; then
    log "sslocal-mptcp is running ✓"
else
    err "sslocal-mptcp failed to start!"
    journalctl -u sslocal-mptcp -n 15 --no-pager
    exit 1
fi

# Run routing + iptables setup
log "Running MPTCP routing setup..."
/usr/local/bin/mptcp-setup.sh

# Save iptables after setup
netfilter-persistent save > /dev/null 2>&1

###############################################################################
# Verification
###############################################################################
banner "Verification"

echo -e "${BOLD}MPTCP Endpoints:${NC}"
ip mptcp endpoint show

echo ""
echo -e "${BOLD}Routing Rules (top 15):${NC}"
ip rule show | head -15

echo ""
echo -e "${BOLD}iptables PREROUTING:${NC}"
iptables -t nat -L PREROUTING -n --line-numbers

echo ""
echo -e "${BOLD}WAN Source Routing:${NC}"
for i in $(seq 0 $((WAN_COUNT - 1))); do
    RESULT=$(ip route get "${VPS_IP}" from "${WAN_IPS[$i]}" 2>/dev/null | head -1)
    echo "  WAN$((i+1)): ${RESULT}"
done

###############################################################################
# Done
###############################################################################
banner "Router Deployment Complete ✅"

echo -e "${BOLD}┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│  shadowsocks-rust REDIR mode + MPTCP (no TUN overhead)      │${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC}  TCP: redirected through tunnel via iptables                  "
echo -e "${BOLD}│${NC}  UDP/DNS: goes direct via WAN1 (not tunneled)                 "
echo -e "${BOLD}│${NC}                                                               "
echo -e "${BOLD}│${NC}  1. Verify from LAN client:                                   "
echo -e "${BOLD}│${NC}     ${CYAN}curl ifconfig.me${NC}  → should show VPS IP"
echo -e "${BOLD}│${NC}  2. Speed test from LAN client                                "
echo -e "${BOLD}│${NC}  3. Watch MPTCP subflows:                                     "
echo -e "${BOLD}│${NC}     ${CYAN}ss -tiM${NC}"
echo -e "${BOLD}│${NC}  4. Re-run routing:                                            "
echo -e "${BOLD}│${NC}     ${CYAN}sudo /usr/local/bin/mptcp-setup.sh${NC}"
echo -e "${BOLD}│${NC}  5. Emergency — remove redirect:                               "
echo -e "${BOLD}│${NC}     ${CYAN}sudo iptables -t nat -F PREROUTING${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────────────────┘${NC}"
