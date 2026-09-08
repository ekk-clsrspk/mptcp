# mptcp — Combine Multiple Internet Lines Into One Fast Pipe

Have 2–5 internet connections at home (DSL + 4G + Starlink, …) and want your
downloads to use **all of them at once**? These 4 scripts set that up for you.

## How it works (the short version)

Your home router opens an encrypted tunnel to a small server (VPS) on the
internet. That tunnel is special: it sends your traffic down **all your
internet lines simultaneously** and puts it back together at the other end.
Websites only see the server's address.

```
Your devices → Home router →  line 1 ─┐
                              line 2 ─┼→  VPS  → Internet
                              line 3 ─┘
```

- **Speed:** downloads use the *sum* of your lines (minus ~10% overhead).
- **Only downloads/browsing go through the tunnel.** Online games, video
  calls and DNS keep using your main line directly (faster for them).
- If your main line drops, the tunnel automatically fails over to line 2.

Built on [MPTCP](https://www.mptcp.dev/) (Linux's multipath TCP) +
[shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) for
encryption. Tested on Ubuntu with Linux kernel 6.8.

## What you need

| | Minimum | Recommended |
|---|---|---|
| **VPS** (the server) | 2 CPU cores, 2 GB RAM, close to your home | 4 CPU cores, 4 GB RAM, 2+ Gbps port |
| **Home router** (a PC running Ubuntu) | 4 cores with AES support, 4 GB RAM | Anything modern, e.g. i5/i7, 8–16 GB RAM |
| **Both machines** | Linux kernel 5.6+ (6.8+ best), root access | Ubuntu 22.04/24.04 |

Check your kernel with `uname -r`. Check AES support with
`grep -m1 aes /proc/cpuinfo` (you want to see a line back — it makes
encryption ~2× cheaper).

## Before you start: write down 6 things

Open `router-ss.sh` in a text editor and fill in the **Configuration**
block at the top (the script refuses to run until you do):

1. `VPS_IP` — your server's public address.
2. `WAN_INTERFACES` — the network port names of your internet lines
   (see them with `ip -brief link`, e.g. `eth0 eth1 …`).
3. `WAN_IPS` — the router's own address on each line, **in the same order**.
4. `WAN_GATEWAYS` — each line's gateway, **in the same order**.
5. `WAN_SUBNETS` — each line's network, **in the same order**.
6. `LAN_SUBNET` / `LAN_IP` — your home network (defaults fit most homes).

Example for 2 lines:

```bash
WAN_INTERFACES=("eth0" "eth1")
WAN_IPS=(   "192.168.1.4"   "192.168.2.4"   )
WAN_GATEWAYS=("192.168.1.1" "192.168.2.1"   )
WAN_SUBNETS=("192.168.1.0/24" "192.168.2.0/24")
```

## Setup in 4 commands

**On the VPS** (run once — it prints a password at the end, copy it):

```bash
sudo bash vps-ss.sh
```

**On the home router** (paste the password from the VPS step):

```bash
sudo bash router-ss.sh "<PASSWORD-FROM-VPS>"
```

**Speed tuning** (run once on each machine, safe to re-run anytime):

```bash
sudo bash vps-ss-optimize.sh      # on the VPS
sudo bash router-ss-optimize.sh   # on the router
```

That's it. The scripts enable everything at boot, so a reboot just works.

## What the scripts put on your machines

You only ever run the 4 scripts above. They create everything else
automatically — here's what those extra names in the troubleshooting
section refer to:

**On the router**, `router-ss.sh` generates a helper from your config:

- `/usr/local/bin/mptcp-setup.sh` — applies the bonding + routing +
  firewall rules. Re-running it by hand is the "turn it off and on again"
  for this setup: it never hurts, and it's the first thing to try when
  something looks stuck.

And registers background services (managed with `systemctl`, start at boot):

| Service | Machine | Job |
|---|---|---|
| `sslocal-mptcp` | Router | The tunnel client — your traffic's front door |
| `mptcp-routing` | Router | Runs `mptcp-setup.sh` at boot so routing survives restarts |
| `ssserver-mptcp` | VPS | The tunnel server — reassembles your traffic |
| `rps-persist` | Both | Re-applies the speed tuning at boot (created by the optimize scripts) |

Settings live in `/etc/shadowsocks-rust/config.json` (tunnel password etc.)
and `/etc/sysctl.d/90-mptcp.conf` + `91-*.conf` (speed tuning). You normally
never need to touch these — re-running the scripts rewrites them.

## How to check it's working

From any device on your home network:

```bash
curl ifconfig.me
```

It should print your **VPS address** (not your home address) — your traffic
is going through the tunnel.

On the router, watch the traffic spread over all lines:

```bash
ss -tiM          # one entry per line/subflow = bonding is live
mpstat -P ALL 1 5  # work should be spread evenly over all CPU cores
```

Then run any speed test and compare against a single line.

## Proof it works

Real result from a home with **4 ISPs bonded** through this tunnel — Ookla
Speedtest on a home PC, with per-line traffic (`eth0/eth1/eth2…`) visible on
the dashboard underneath:

![Speedtest through the bonded tunnel: 6 ms ping, 5304.98 Mbps down, 2926.46 Mbps up](proof.jpg)

The 4 lines going in:

| | Download | Upload |
|---|---|---|
| ISP 1 | 2000 Mbps | 1000 Mbps |
| ISP 2 | 2000 Mbps | 1000 Mbps |
| ISP 3 | 1000 Mbps | 500 Mbps |
| ISP 4 | 500 Mbps | 500 Mbps |
| **Total** | **5500 Mbps** | **3000 Mbps** |

Measured through the tunnel: **5305 down / 2926 up** — that's ~96% of the
combined download and ~98% of the combined upload surviving encryption and
reassembly, at 6 ms ping. No single line here could do even half of that
alone. Your numbers will match roughly the sum of *your* lines.

## If something's wrong

| Symptom | Most likely cause | Fix |
|---|---|---|
| `curl ifconfig.me` shows home IP | Tunnel/redirect not active | `sudo systemctl status sslocal-mptcp`, then `sudo /usr/local/bin/mptcp-setup.sh` |
| Tunnel dies when line 1 drops | Old version without fallback | Re-run new `router-ss.sh` (adds automatic line-2 fallback) |
| Slower than one line alone | CPU "steal" on a virtual machine | On VPS: `mpstat 1 5`, if `%steal` > 5, move to a less crowded host |
| Slow only after a reboot | Tuning didn't re-apply | `sudo systemctl enable --now rps-persist` (or re-run the optimize script) |
| Script says "edit the Configuration block" | You skipped the 6 values above | Fill them in at the top of `router-ss.sh` |

Emergency off-switch (stops tunneling instantly, back to direct):

```bash
sudo iptables -t nat -F PREROUTING
```

Re-enable with `sudo /usr/local/bin/mptcp-setup.sh`.

## What to expect (honestly)

- **Download speed:** roughly the sum of your lines minus ~10% encryption
  overhead. A 1 Gbps VPS port caps you at 1 Gbps no matter what.
- **Uploads, games, calls:** unchanged — they bypass the tunnel on purpose.
- **Latency:** same as your best line, roughly. Multipath can't beat physics.
- To undo everything, stop the services:
  `sudo systemctl disable --now sslocal-mptcp mptcp-routing` (router),
  `sudo systemctl disable --now ssserver-mptcp` (VPS).

## Files

| File | Runs on | Does |
|---|---|---|
| `vps-ss.sh` | VPS | Installs + configures the server end |
| `router-ss.sh` | Router | Installs the client, sets up bonding + routing |
| `vps-ss-optimize.sh` | VPS | Speed tuning (safe to re-run) |
| `router-ss-optimize.sh` | Router | Speed tuning (safe to re-run) |
