# MPTCP Setup — Step-by-Step Execution

> Execute these steps in order. Start with the VPS, then the Router.

---

## Step 1: VPS Setup

SSH into your VPS (103.52.108.174) and run each block.

### 1A. System Prep

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y iproute2 curl wget iperf3

# Verify kernel
uname -r
# Must be 5.6+ (Ubuntu 22.04+ ships 5.15+, Ubuntu 24.04 ships 6.8+)

# Check MPTCP
sysctl net.mptcp.enabled
```

### 1B. Enable MPTCP + IP Forwarding

```bash
cat << 'EOF' | sudo tee /etc/sysctl.d/90-mptcp.conf
net.mptcp.enabled=1
net.ipv4.ip_forward=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
EOF

sudo sysctl -p /etc/sysctl.d/90-mptcp.conf

# Set MPTCP limits
sudo ip mptcp limits set subflow 8 add_addr_accepted 8
```

### 1C. Install sing-box

```bash
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
echo "deb [signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" | sudo tee /etc/apt/sources.list.d/sagernet.list
sudo apt update
sudo apt install -y sing-box
```

### 1D. Generate Password

```bash
SS_PASSWORD=$(openssl rand -base64 32)
echo "Your Shadowsocks password: $SS_PASSWORD"
echo "SAVE THIS — you need it on the router too!"
```

### 1E. VPS sing-box Config

Replace `YOUR_SS_PASSWORD_HERE` with the password from step 1D:

```bash
cat << 'SINGEOF' | sudo tee /etc/sing-box/config.json
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
SINGEOF
```

### 1F. NAT & Firewall

```bash
# NAT for tunnel traffic
sudo iptables -t nat -A POSTROUTING -o enp1s0 -j MASQUERADE
sudo iptables -A FORWARD -j ACCEPT

# Persist
sudo apt install -y iptables-persistent
sudo netfilter-persistent save

# UFW
sudo ufw allow ssh
sudo ufw allow 8388/tcp
sudo ufw --force enable
```

### 1G. Start sing-box

```bash
sudo systemctl enable sing-box
sudo systemctl restart sing-box
sudo systemctl status sing-box

# Check logs
journalctl -u sing-box -n 20
```

### 1H. Persist MPTCP Limits

```bash
cat << 'EOF' | sudo tee /etc/systemd/system/mptcp-limits.service
[Unit]
Description=MPTCP Limits Configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip mptcp limits set subflow 8 add_addr_accepted 8

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mptcp-limits
```

**VPS is ready.** ✅

---

## Step 2: Router Setup

SSH into your Router and run each block.

### 2A. System Prep

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y iproute2 curl wget iperf3

uname -r
sysctl net.mptcp.enabled
```

### 2B. Enable MPTCP + IP Forwarding + Tuning

```bash
cat << 'EOF' | sudo tee /etc/sysctl.d/90-mptcp.conf
net.mptcp.enabled=1
net.ipv4.ip_forward=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
EOF

sudo sysctl -p /etc/sysctl.d/90-mptcp.conf
```

### 2C. Create Routing Tables

```bash
# Only add if not already present
grep -q "wan1" /etc/iproute2/rt_tables || {
    echo "101 wan1" | sudo tee -a /etc/iproute2/rt_tables
    echo "102 wan2" | sudo tee -a /etc/iproute2/rt_tables
    echo "103 wan3" | sudo tee -a /etc/iproute2/rt_tables
    echo "104 wan4" | sudo tee -a /etc/iproute2/rt_tables
    echo "105 wan5" | sudo tee -a /etc/iproute2/rt_tables
    echo "200 tunnel" | sudo tee -a /etc/iproute2/rt_tables
}
```

### 2D. Policy Routing + MPTCP Endpoints

```bash
cat << 'ROUTESCRIPT' | sudo tee /usr/local/bin/mptcp-setup.sh
#!/bin/bash
set -e

echo "[MPTCP] Configuring policy routing and MPTCP endpoints..."

# ── MPTCP Endpoints ──
ip mptcp endpoint flush
ip mptcp endpoint add 192.168.1.2 dev enp6s18 subflow
ip mptcp endpoint add 192.168.2.2 dev enp6s19 subflow
ip mptcp endpoint add 192.168.3.2 dev enp6s20 subflow
ip mptcp endpoint add 192.168.4.2 dev enp6s21 subflow
ip mptcp endpoint add 192.168.5.2 dev enp6s22 subflow
ip mptcp limits set subflow 5 add_addr_accepted 5

# ── Policy Routing (per-WAN) ──
INTERFACES=("enp6s18" "enp6s19" "enp6s20" "enp6s21" "enp6s22")
for i in 1 2 3 4 5; do
    IDX=$((i - 1))
    DEV="${INTERFACES[$IDX]}"
    IP="192.168.${i}.2"
    GW="192.168.${i}.1"
    TABLE=$((100 + i))

    ip route replace "192.168.${i}.0/24" dev "$DEV" scope link table "$TABLE" 2>/dev/null || true
    ip route replace default via "$GW" dev "$DEV" table "$TABLE" 2>/dev/null || true
    ip rule del from "$IP" table "$TABLE" 2>/dev/null || true
    ip rule add from "$IP" table "$TABLE" priority "$TABLE"
done

# ── Default Route ──
ip route replace default via 192.168.1.1 dev enp6s18 metric 100

# ── VPS Direct Route (bypass tunnel) ──
ip route replace 103.52.108.174/32 via 192.168.1.1 dev enp6s18

# ── LAN → Tunnel Routing ──
# Wait for sing-box TUN interface
for attempt in $(seq 1 30); do
    if ip link show tun-mptcp &>/dev/null; then
        break
    fi
    echo "[MPTCP] Waiting for tun-mptcp interface... ($attempt/30)"
    sleep 2
done

if ip link show tun-mptcp &>/dev/null; then
    ip route replace default dev tun-mptcp table 200 2>/dev/null || true

    # Local traffic stays local
    ip rule del to 10.77.40.0/22 table main 2>/dev/null || true
    ip rule add to 10.77.40.0/22 table main priority 40
    ip rule del to 192.168.0.0/16 table main 2>/dev/null || true
    ip rule add to 192.168.0.0/16 table main priority 41

    # LAN traffic → tunnel
    ip rule del from 10.77.40.0/22 table 200 2>/dev/null || true
    ip rule add from 10.77.40.0/22 table 200 priority 50

    echo "[MPTCP] TUN routing configured ✅"
else
    echo "[MPTCP] WARNING: tun-mptcp not found after 60s!"
fi

echo "[MPTCP] Setup complete at $(date)"
ROUTESCRIPT

sudo chmod +x /usr/local/bin/mptcp-setup.sh
```

### 2E. Install sing-box

```bash
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
echo "deb [signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" | sudo tee /etc/apt/sources.list.d/sagernet.list
sudo apt update
sudo apt install -y sing-box
```

### 2F. Router sing-box Config

Replace `YOUR_SS_PASSWORD_HERE` with the same password from Step 1D:

```bash
cat << 'SINGEOF' | sudo tee /etc/sing-box/config.json
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
SINGEOF
```

### 2G. NAT for LAN

```bash
# Find your LAN interface name (the one with 10.77.40.1)
LAN_IF=$(ip -4 addr show | grep "10.77.40.1" | awk '{print $NF}')
echo "LAN interface: $LAN_IF"

# NAT LAN → tunnel
sudo iptables -t nat -A POSTROUTING -s 10.77.40.0/22 -o tun-mptcp -j MASQUERADE
sudo iptables -A FORWARD -i "$LAN_IF" -o tun-mptcp -j ACCEPT
sudo iptables -A FORWARD -i tun-mptcp -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

# Persist
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

### 2H. Start Everything

```bash
# Start sing-box first (creates TUN interface)
sudo systemctl enable sing-box
sudo systemctl restart sing-box

# Wait a moment, then run routing setup
sleep 3
sudo /usr/local/bin/mptcp-setup.sh
```

### 2I. Persist Routing on Boot

```bash
cat << 'EOF' | sudo tee /etc/systemd/system/mptcp-routing.service
[Unit]
Description=MPTCP Policy Routing Setup
After=network-online.target sing-box.service
Wants=network-online.target sing-box.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/mptcp-setup.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mptcp-routing
```

**Router is ready.** ✅

---

## Step 3: Verify

### 3A. Check MPTCP Subflows

```bash
# On Router
ss -tiM
# Should show MPTCP connections to 103.52.108.174:8388

ip mptcp endpoint show
# Should show 5 endpoints

ip mptcp monitor &
# Generate some traffic and watch for subflow events
curl -o /dev/null https://speed.cloudflare.com/__down?bytes=100000000
```

### 3B. Check All WANs Are Used

```bash
# On Router — verify source routing works for each WAN
for i in 1 2 3 4 5; do
    echo "=== WAN$i (192.168.${i}.2) ==="
    ip route get 103.52.108.174 from "192.168.${i}.2"
done
```

### 3C. Bandwidth Test

```bash
# On VPS — start server
iperf3 -s -p 5201

# On Router — run through the tunnel
# Download test
iperf3 -c 172.19.0.1 -P 10 -t 20

# Or test from a LAN client directly
# On LAN client (10.77.40.x):
iperf3 -c <any-public-iperf3-server> -P 10 -t 20
```

### 3D. Verify LAN Clients Exit via VPS

```bash
# On any LAN client (10.77.40.x)
curl ifconfig.me
# Should show the VPS public IP, not your local ISP IP
```

---

## Quick Reference — Service Management

```bash
# Restart sing-box
sudo systemctl restart sing-box

# Re-run routing setup
sudo /usr/local/bin/mptcp-setup.sh

# Check sing-box logs
journalctl -u sing-box -f

# Check MPTCP status
ss -M
nstat -az | grep -i mptcp

# Temporarily disable tunnel routing (emergency)
sudo ip rule del from 10.77.40.0/22 table 200
```
