#!/bin/bash
CWND=1520
modprobe tcp_bbr
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_slow_start_after_idle=0
sysctl -w net.ipv4.tcp_adv_win_scale=2
sysctl -w net.core.netdev_max_backlog=8192
sysctl -w net.core.netdev_budget=600
sysctl -w net.core.netdev_budget_usecs=4000
sysctl -w net.ipv4.tcp_mem="2097152 3145728 4194304"
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.ipv4.tcp_rmem="4096 2097152 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 2097152 134217728"
sysctl -w net.ipv4.tcp_mtu_probing=1
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
