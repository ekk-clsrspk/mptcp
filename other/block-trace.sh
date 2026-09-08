iptables -A OUTPUT -p icmp --icmp-type time-exceeded -j DROP
iptables -A INPUT -p udp --dport 33434:33534 -j DROP
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
netfilter-persistent save