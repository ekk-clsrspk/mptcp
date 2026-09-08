# MPTCP Bandwidth Aggregation Plan

## Network Topology

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                       │
│                                                                             │
│                         ┌──────────────────┐                                │
│                         │   VPS (Exit Node) │                                │
│                         │  103.52.108.174   │                                │
│                         │  enp1s0 (10Gbps)  │                                │
│                         │  Ubuntu + MPTCP   │                                │
│                         └────────┬─────────┘                                │
│                                  │                                           │
│                    MPTCP (5 subflows via tunnel)                             │
│                    ┌─────┬───┴───┬─────┐                                    │
│                    │     │       │     │                                     │
└────────────────────┼─────┼───────┼─────┼────────────────────────────────────┘
                     │     │       │     │
              ┌──────┴─────┴───────┴─────┴──────┐
              │        ISP Gateways (NAT)         │
              │  .1.1   .2.1   .3.1   .4.1   .5.1│
              └──────┬─────┬───────┬─────┬──────┘
                     │     │       │     │
┌────────────────────┼─────┼───────┼─────┼────────────────────────────────────┐
│  ROUTER (Ubuntu)   │     │       │     │                                     │
│                    │     │       │     │                                     │
│  enp6s18 ──────────┘     │       │     │    192.168.1.2/24  (WAN1 - 2G/1G)  │
│  enp6s19 ────────────────┘       │     │    192.168.2.2/24  (WAN2 - 2G/1G)  │
│  enp6s20 ────────────────────────┘     │    192.168.3.2/24  (WAN3 - 2G/1G)  │
│  enp6s21 ──────────────────────────────┘    192.168.4.2/24  (WAN4 - 2G/1G)  │
│  enp6s22 ───────────────────────────────    192.168.5.2/24  (WAN5 - 2G/1G)  │
│                                                                              │
│  LAN: 10.77.40.1/22 ──────── LAN Clients (10.77.40.0/22)                   │
│                              Combined: 10G Down / 5G Up                     │
└──────────────────────────────────────────────────────────────────────────────┘
```

> **GOAL**: All LAN traffic (10.77.40.0/22) exits through the VPS via an MPTCP-enabled tunnel that uses all 5 WAN interfaces simultaneously, achieving ~10 Gbps download / ~5 Gbps upload aggregate throughput.

---

## Architecture Decision

| Approach | Pros | Cons |
|----------|------|------|
| **OpenMPTCProuter** | Turnkey, well-tested | Requires OpenWrt on router side |
| **sing-box + MPTCP** ✅ | Native MPTCP support, lightweight, modern | Manual setup |
| **shadowsocks-rust + MPTCP** | Native `--mptcp` flag | Less feature-rich than sing-box |
| **WireGuard + mptcpize** | Encrypted tunnel | mptcpize unreliable with Go/static binaries |

**Chosen: `sing-box` with Shadowsocks protocol + kernel MPTCP**

- sing-box has native `tcp_multi_path: true` support
- Shadowsocks 2022 provides fast, encrypted transport
- Linux kernel handles MPTCP subflow management across all 5 interfaces
- No kernel patching needed (upstream MPTCP since Linux 5.6+)

---

## Phase 0 — Prerequisites

### Both machines (Router + VPS)

```bash
# Check kernel version (must be 5.6+, ideally 6.1+)
uname -r

# Check MPTCP support
sysctl net.mptcp.enabled
# If missing, your kernel may need MPTCP compiled in (Ubuntu 22.04+ has it)

# Install required packages
sudo apt update
sudo apt install -y iproute2 jq curl wget
```

### Install sing-box (both machines)

```bash
# Install sing-box (latest stable)
sudo bash -c 'cat > /etc/apt/sources.list.d/sagernet.list << EOF
deb https://deb.sagernet.org/ * *
EOF'
sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
sudo apt update
sudo apt install -y sing-box
```

Or via binary:
```bash
# Check latest version at https://github.com/SagerNet/sing-box/releases
SING_BOX_VERSION="1.11.0"
wget "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"
tar xzf "sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"
sudo cp "sing-box-${SING_BOX_VERSION}-linux-amd64/sing-box" /usr/local/bin/
sudo chmod +x /usr/local/bin/sing-box
```

---

## Phase 1 — Kernel MPTCP Configuration

### 1.1 Router — Enable MPTCP & Configure Endpoints

```bash
# Enable MPTCP
sudo sysctl -w net.mptcp.enabled=1

# Persist
echo "net.mptcp.enabled=1" | sudo tee /etc/sysctl.d/90-mptcp.conf
sudo sysctl -p /etc/sysctl.d/90-mptcp.conf
```

#### Configure MPTCP endpoints (one per WAN interface)

```bash
# Flush existing endpoints
sudo ip mptcp endpoint flush

# Add each WAN interface as a subflow endpoint
sudo ip mptcp endpoint add 192.168.1.2 dev enp6s18 subflow
sudo ip mptcp endpoint add 192.168.2.2 dev enp6s19 subflow
sudo ip mptcp endpoint add 192.168.3.2 dev enp6s20 subflow
sudo ip mptcp endpoint add 192.168.4.2 dev enp6s21 subflow
sudo ip mptcp endpoint add 192.168.5.2 dev enp6s22 subflow

# Set MPTCP limits: allow up to 5 subflows
sudo ip mptcp limits set subflow 5 add_addr_accepted 5

# Verify
ip mptcp endpoint show
ip mptcp limits show
```

### 1.2 VPS — Enable MPTCP

```bash
# Enable MPTCP
sudo sysctl -w net.mptcp.enabled=1
echo "net.mptcp.enabled=1" | sudo tee /etc/sysctl.d/90-mptcp.conf
sudo sysctl -p /etc/sysctl.d/90-mptcp.conf

# VPS only has 1 interface, so no endpoints needed
# But set limits to accept subflows from the router
sudo ip mptcp limits set subflow 8 add_addr_accepted 8

# Verify
ip mptcp limits show
```

---

## Phase 2 — Policy Routing on Router

> **CRITICAL**: Without policy routing, the kernel won't know how to route MPTCP subflows out of different interfaces.

Each WAN interface needs its own routing table so MPTCP subflows can use different paths.

### 2.1 Create routing tables

```bash
# Add named routing tables (check they don't already exist first)
echo "101 wan1" | sudo tee -a /etc/iproute2/rt_tables
echo "102 wan2" | sudo tee -a /etc/iproute2/rt_tables
echo "103 wan3" | sudo tee -a /etc/iproute2/rt_tables
echo "104 wan4" | sudo tee -a /etc/iproute2/rt_tables
echo "105 wan5" | sudo tee -a /etc/iproute2/rt_tables
```

### 2.2 Configure per-interface routes and rules

```bash
# WAN1 - enp6s18 - 192.168.1.2/24
sudo ip route add 192.168.1.0/24 dev enp6s18 scope link table wan1
sudo ip route add default via 192.168.1.1 dev enp6s18 table wan1
sudo ip rule add from 192.168.1.2 table wan1 priority 101

# WAN2 - enp6s19 - 192.168.2.2/24
sudo ip route add 192.168.2.0/24 dev enp6s19 scope link table wan2
sudo ip route add default via 192.168.2.1 dev enp6s19 table wan2
sudo ip rule add from 192.168.2.2 table wan2 priority 102

# WAN3 - enp6s20 - 192.168.3.2/24
sudo ip route add 192.168.3.0/24 dev enp6s20 scope link table wan3
sudo ip route add default via 192.168.3.1 dev enp6s20 table wan3
sudo ip rule add from 192.168.3.2 table wan3 priority 103

# WAN4 - enp6s21 - 192.168.4.2/24
sudo ip route add 192.168.4.0/24 dev enp6s21 scope link table wan4
sudo ip route add default via 192.168.4.1 dev enp6s21 table wan4
sudo ip rule add from 192.168.4.2 table wan4 priority 104

# WAN5 - enp6s22 - 192.168.5.2/24
sudo ip route add 192.168.5.0/24 dev enp6s22 scope link table wan5
sudo ip route add default via 192.168.5.1 dev enp6s22 table wan5
sudo ip rule add from 192.168.5.2 table wan5 priority 105
```

### 2.3 Default route (primary WAN for initial MPTCP handshake)

```bash
# Set WAN1 as the default route for initial connections
sudo ip route replace default via 192.168.1.1 dev enp6s18 metric 100
```

---

## Phase 3 — sing-box Tunnel Configuration

### 3.1 Generate Shadowsocks Password

```bash
# Generate a strong password for Shadowsocks 2022
openssl rand -base64 32
# Example output: kGqo3Y0X1b2hMF5Z8RJ3N7c9G+y6PwTk1aQ7VdU5mXo=
# Use this SAME password on both router and VPS
```

> **IMPORTANT**: Replace `YOUR_SS_PASSWORD_HERE` in both configs below with the generated password.

### 3.2 VPS — sing-box Server Config

Create `/etc/sing-box/config.json` on the VPS:

```json
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
      "listen_port": 8388,
      "method": "2022-blake3-aes-256-gcm",
      "password": "YOUR_SS_PASSWORD_HERE",
      "tcp_multi_path": true,
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": 10000,
          "down_mbps": 10000
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
```

> **NOTE**: `tcp_multi_path: true` tells sing-box to accept MPTCP connections on the server socket. `multiplex` with `brutal` mode enables aggressive bandwidth usage through the tunnel.

### 3.3 Router — sing-box Client Config

Create `/etc/sing-box/config.json` on the Router:

```json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "remote-dns",
        "address": "https://1.1.1.1/dns-query",
        "detour": "proxy"
      },
      {
        "tag": "local-dns",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "local-dns"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun-mptcp",
      "inet4_address": "172.19.0.1/30",
      "auto_route": false,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "proxy",
      "server": "103.52.108.174",
      "server_port": 8388,
      "method": "2022-blake3-aes-256-gcm",
      "password": "YOUR_SS_PASSWORD_HERE",
      "tcp_multi_path": true,
      "udp_over_tcp": true,
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": 8,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": 5000,
          "down_mbps": 10000
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "proxy"
      }
    ],
    "auto_detect_interface": true
  }
}
```

> **NOTE**: `auto_route: false` — We handle routing manually with `ip route` / `iptables` for full control. `tcp_multi_path: true` on the outbound tells sing-box to initiate MPTCP connections to the VPS. The kernel then creates subflows on each WAN interface automatically.

---

## Phase 4 — Routing & NAT

### 4.1 VPS — Enable IP Forwarding & NAT

```bash
# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.d/90-mptcp.conf

# NAT — masquerade all traffic going out enp1s0
sudo iptables -t nat -A POSTROUTING -o enp1s0 -j MASQUERADE

# Accept forwarded traffic
sudo iptables -A FORWARD -j ACCEPT

# Persist iptables rules
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

### 4.2 Router — Route LAN Traffic Through Tunnel

```bash
# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.d/90-mptcp.conf

# NAT LAN traffic going out through the tunnel
sudo iptables -t nat -A POSTROUTING -s 10.77.40.0/22 -o tun-mptcp -j MASQUERADE

# Route all LAN traffic through the sing-box TUN interface
# (Exclude the VPS IP and local subnets from tunnel routing)
sudo ip route add 103.52.108.174/32 via 192.168.1.1 dev enp6s18
sudo ip route add default dev tun-mptcp table 200
sudo ip rule add from 10.77.40.0/22 table 200 priority 50

# Ensure local traffic doesn't go through tunnel
sudo ip rule add to 10.77.40.0/22 table main priority 40
sudo ip rule add to 192.168.0.0/16 table main priority 41
```

> **KEY INSIGHT**: LAN traffic (10.77.40.0/22) → TUN interface → sing-box → MPTCP Shadowsocks → VPS → Internet. The MPTCP layer automatically spreads the single TCP connection across all 5 WAN interfaces.

---

## Phase 5 — Systemd Services & Persistence

### 5.1 sing-box Service (both machines)

```bash
# sing-box usually installs its own service, but verify:
sudo systemctl enable sing-box
sudo systemctl start sing-box
sudo systemctl status sing-box
```

### 5.2 Router — Network Persistence Script

Create `/etc/networkd-dispatcher/routable.d/mptcp-setup.sh`:

```bash
#!/bin/bash
# MPTCP endpoint and policy routing setup
# Runs when network interfaces come up

set -e

# Enable MPTCP
sysctl -w net.mptcp.enabled=1

# Flush existing MPTCP endpoints
ip mptcp endpoint flush

# Add endpoints
ip mptcp endpoint add 192.168.1.2 dev enp6s18 subflow
ip mptcp endpoint add 192.168.2.2 dev enp6s19 subflow
ip mptcp endpoint add 192.168.3.2 dev enp6s20 subflow
ip mptcp endpoint add 192.168.4.2 dev enp6s21 subflow
ip mptcp endpoint add 192.168.5.2 dev enp6s22 subflow

# MPTCP limits
ip mptcp limits set subflow 5 add_addr_accepted 5

# Policy routing tables
for i in 1 2 3 4 5; do
    TABLE_ID=$((100 + i))
    DEV="enp6s$((17 + i))"
    IP="192.168.${i}.2"
    GW="192.168.${i}.1"

    ip route replace 192.168.${i}.0/24 dev "$DEV" scope link table "$TABLE_ID" 2>/dev/null || true
    ip route replace default via "$GW" dev "$DEV" table "$TABLE_ID" 2>/dev/null || true
    ip rule del from "$IP" table "$TABLE_ID" 2>/dev/null || true
    ip rule add from "$IP" table "$TABLE_ID" priority "$TABLE_ID"
done

# Default route via WAN1
ip route replace default via 192.168.1.1 dev enp6s18 metric 100

# VPS route (bypass tunnel)
ip route replace 103.52.108.174/32 via 192.168.1.1 dev enp6s18

# LAN routing through tunnel (after sing-box creates tun-mptcp)
sleep 3
if ip link show tun-mptcp &>/dev/null; then
    ip route replace default dev tun-mptcp table 200 2>/dev/null || true
    ip rule del from 10.77.40.0/22 table 200 2>/dev/null || true
    ip rule add from 10.77.40.0/22 table 200 priority 50
fi

# Local traffic rules
ip rule del to 10.77.40.0/22 table main 2>/dev/null || true
ip rule add to 10.77.40.0/22 table main priority 40
ip rule del to 192.168.0.0/16 table main 2>/dev/null || true
ip rule add to 192.168.0.0/16 table main priority 41

echo "[MPTCP] Setup complete at $(date)"
```

```bash
sudo chmod +x /etc/networkd-dispatcher/routable.d/mptcp-setup.sh
```

Or create a dedicated systemd service:

```bash
sudo tee /etc/systemd/system/mptcp-routing.service << 'EOF'
[Unit]
Description=MPTCP Policy Routing Setup
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/networkd-dispatcher/routable.d/mptcp-setup.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mptcp-routing
```

---

## Phase 6 — Verification & Testing

### 6.1 Verify MPTCP is Working

```bash
# On Router — check MPTCP connections
ss -tiM

# On Router — watch MPTCP events in real time
ip mptcp monitor

# On Router — check MPTCP stats
nstat -az | grep -i mptcp

# Verify endpoints
ip mptcp endpoint show
# Should show all 5 endpoints

# Verify subflows are established
ss -M
# Look for connections with multiple subflows
```

### 6.2 Bandwidth Testing

```bash
# Install iperf3 on both machines
sudo apt install -y iperf3

# On VPS — start iperf3 server
iperf3 -s

# On Router — test through tunnel (should aggregate bandwidth)
# Test download (VPS → Router)
iperf3 -c 103.52.108.174 -P 5 -t 30

# Test upload (Router → VPS)
iperf3 -c 103.52.108.174 -P 5 -t 30 -R

# From a LAN client (10.77.40.x) — test end-to-end
iperf3 -c <some-internet-iperf3-server> -P 5 -t 30
```

### 6.3 Monitor Interface Usage

```bash
# Watch traffic on all WAN interfaces simultaneously
watch -n 1 'for iface in enp6s18 enp6s19 enp6s20 enp6s21 enp6s22; do
    echo -n "$iface: "
    cat /sys/class/net/$iface/statistics/rx_bytes
done'

# Or use nload / bmon for visual monitoring
sudo apt install -y nload bmon
bmon
```

---

## Phase 7 — Firewall Hardening

### VPS Firewall

```bash
# Only allow sing-box port and SSH
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 8388/tcp    # sing-box Shadowsocks
sudo ufw enable
```

### Router Firewall

```bash
# Allow LAN to reach router
sudo ufw allow in on <LAN_INTERFACE> from 10.77.40.0/22

# Allow established/related connections
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw enable
```

---

## Execution Order Checklist

| # | Step | Machine | Status |
|---|------|---------|--------|
| 1 | Verify kernel ≥ 5.6, MPTCP compiled in | Both | ⬜ |
| 2 | Install sing-box | Both | ⬜ |
| 3 | Enable MPTCP sysctl | Both | ⬜ |
| 4 | Generate Shadowsocks password | Either | ⬜ |
| 5 | Deploy VPS sing-box config | VPS | ⬜ |
| 6 | Start sing-box on VPS | VPS | ⬜ |
| 7 | Enable IP forwarding + NAT on VPS | VPS | ⬜ |
| 8 | Create routing tables on Router | Router | ⬜ |
| 9 | Configure policy routing on Router | Router | ⬜ |
| 10 | Add MPTCP endpoints on Router | Router | ⬜ |
| 11 | Deploy Router sing-box config | Router | ⬜ |
| 12 | Start sing-box on Router | Router | ⬜ |
| 13 | Route LAN traffic through TUN | Router | ⬜ |
| 14 | Verify MPTCP subflows (`ss -tiM`) | Router | ⬜ |
| 15 | Test bandwidth (iperf3) | Both | ⬜ |
| 16 | Persist with systemd | Both | ⬜ |
| 17 | Harden firewall | Both | ⬜ |

---

## Troubleshooting

### MPTCP subflows not being created
```bash
# Check that endpoints are registered
ip mptcp endpoint show

# Check limits
ip mptcp limits show
# subflow should be >= 5, add_addr_accepted >= 5

# Verify policy routing works (each source IP routes to its own gateway)
ip route get 103.52.108.174 from 192.168.1.2
ip route get 103.52.108.174 from 192.168.2.2
# Each should show a different dev
```

### No bandwidth aggregation
```bash
# Check MPTCP scheduler
cat /proc/sys/net/mptcp/scheduler
# "default" should work; try "redundant" for resilience testing

# Check if ISP is blocking/interfering with MPTCP
# MPTCP falls back to TCP if middleboxes strip MPTCP options
tcpdump -i enp6s18 -c 10 'tcp[20] & 0x30 = 0x30'
```

### sing-box TUN not creating interface
```bash
# Check sing-box logs
journalctl -u sing-box -f

# Verify TUN permissions
ls -la /dev/net/tun
# If missing:
sudo mkdir -p /dev/net
sudo mknod /dev/net/tun c 10 200
sudo chmod 666 /dev/net/tun
```

### Connection drops when one WAN goes down
```bash
# MPTCP handles this automatically — remaining subflows continue
# To test, temporarily bring down one interface:
sudo ip link set enp6s19 down
# Active connections should survive on the other 4 paths
```

---

## Expected Performance

| Metric | Single WAN | Aggregated (5 WAN) |
|--------|------------|---------------------|
| Download | 2 Gbps | ~8-9 Gbps* |
| Upload | 1 Gbps | ~4-4.5 Gbps* |
| Failover | N/A | Seamless, < 1s |

> *Actual aggregated throughput will be slightly below theoretical maximum (10G/5G) due to:
> - MPTCP protocol overhead (~5-10%)
> - Shadowsocks encryption overhead
> - Multiplex framing overhead
> - VPS processing capacity
