#!/bin/bash
CWND=1520
modprobe tcp_bbr


# Let more of the receive buffer be used for application data vs TCP overhead
# Default is 1 (50/50 split). Setting to 2 gives 75% to app data but
# can hurt on lossy links. For your vRack paths this is fine.
sysctl -w net.ipv4.tcp_adv_win_scale=2

# Increase NIC processing budget — default 300/2000 can bottleneck at high pps
sysctl -w net.core.netdev_max_backlog=8192
sysctl -w net.core.netdev_budget=600
sysctl -w net.core.netdev_budget_usecs=4000
# Pages (4KB each). This gives ~8GB pressure / ~12GB max
sysctl -w net.ipv4.tcp_mem="2097152 3145728 4194304"
sysctl -w net.core.rmem_max=134217728    # 128MB
sysctl -w net.core.wmem_max=134217728
sysctl -w net.ipv4.tcp_rmem="4096 2097152 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 2097152 134217728"
# If you're running jumbo frames on vRack, enable MTU probing
# so TCP discovers the path MTU correctly
sysctl -w net.ipv4.tcp_mtu_probing=1

# Busy polling — trades CPU for latency on the receive side.
# Useful for your Redis/ScyllaDB traffic, maybe less so for Minecraft clients.
sysctl -w net.core.busy_read=50
sysctl -w net.core.busy_poll=50
ip route show | while read -r route; do
    echo "$route" | grep -q "initcwnd" && continue
    ip route replace $route initcwnd $CWND initrwnd $CWND
done
ip route show | while read -r route; do
    echo "$route" | grep -q "quickack" && continue
    ip route replace $route quickack 1
done
