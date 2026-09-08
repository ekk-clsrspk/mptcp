# Add route table for UDP/ICMP exit
echo "210 udp-exit" | sudo tee -a /etc/iproute2/rt_tables

# Route via eth8
sudo ip route add default via 172.30.0.1 dev eth8 table 210

# Mark UDP + ICMP from LAN
sudo iptables -t mangle -D PREROUTING -s 10.100.0.0/24 -p udp -j MARK --set-mark 100
sudo iptables -t mangle -D PREROUTING -s 10.100.0.0/24 -p icmp -j MARK --set-mark 100

# Route marked traffic via table 210
sudo ip rule add fwmark 100 table 210 priority 49

# NAT on eth8
sudo iptables -t nat -D POSTROUTING -s 10.100.0.0/24 -o eth8 -j MASQUERADE
