#!/bin/bash
###############################################################################
#  SCX P2DQ Launcher — Optimized for Minecraft (Folia) server workloads
#  Usage: sudo bash run-scx.sh
###############################################################################
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[!] Run as root: sudo bash $0"
    exit 1
fi

# Kill any existing scx_p2dq
pkill scx_p2dq 2>/dev/null || true
sleep 1

# Kill existing screen if present
screen -X -S scx quit 2>/dev/null || true
sleep 1

echo "[+] Starting scx_p2dq in screen session 'scx'..."

screen -S scx -dm scx_p2dq \
    --sched-mode performance \
    --cpu-priority true \
    --autoslice \
    --interactive-sticky \
    --latency-priority \
    --wakeup-preemption \
    --keep-running \
    --min-slice-us 250 \
    -t 500 -t 2500 -t 5000 \
    --fork-balance true \
    --exec-balance true \
    --dispatch-lb-busy 75 \
    --dispatch-lb-interactive true \
    --llc-shards 4 \
    --enable-pelt true \
    --idle-resume-us 0 \
    --stats 1

sleep 2

if screen -list | grep -q scx; then
    echo "[+] scx_p2dq running in screen 'scx'"
    echo "[+] Attach with: screen -r scx"
    echo "[+] Detach with: Ctrl+A then D"
else
    echo "[!] Failed to start. Trying to run directly..."
    scx_p2dq \
        --sched-mode performance \
        --cpu-priority true \
        --autoslice \
        --interactive-sticky \
        --latency-priority \
        --wakeup-preemption \
        --keep-running \
        --min-slice-us 250 \
        -t 500 -t 2500 -t 5000 \
        --fork-balance true \
        --exec-balance true \
        --dispatch-lb-busy 75 \
        --dispatch-lb-interactive true \
        --llc-shards 4 \
        --enable-pelt true \
        --idle-resume-us 0 \
        --stats 1
fi
