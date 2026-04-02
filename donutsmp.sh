#!/usr/bin/env bash
###############################################################################
#  CachyOS Ultra Low-Latency & Smoothness Optimization Script
#  Target: AMD GPU + high-throughput networking + responsive desktop/gaming
#  Run as root:  sudo bash optimize-cachyos.sh
#  Persist:      sudo bash optimize-cachyos.sh --install
#                (creates systemd service to apply on every boot)
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

[[ $EUID -ne 0 ]] && { err "Run as root: sudo $0"; exit 1; }

###############################################################################
# --install flag: persist as a systemd service
###############################################################################
if [[ "${1:-}" == "--install" ]]; then
    SCRIPT_DST="/usr/local/bin/cachyos-optimize.sh"
    cp "$(readlink -f "$0")" "$SCRIPT_DST"
    chmod +x "$SCRIPT_DST"
    cat > /etc/systemd/system/cachyos-optimize.service <<EOF
[Unit]
Description=CachyOS Low-Latency Optimizations
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_DST
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now cachyos-optimize.service
    log "Installed and enabled cachyos-optimize.service"
    exit 0
fi

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║    CachyOS Ultra Low-Latency Optimization Script        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

###############################################################################
# 1. SYSCTL — NETWORK STACK
###############################################################################
log "Tuning network stack..."

sysctl -w net.core.rmem_default=1048576          >/dev/null
sysctl -w net.core.wmem_default=1048576           >/dev/null
sysctl -w net.core.rmem_max=16777216              >/dev/null
sysctl -w net.core.wmem_max=16777216              >/dev/null
sysctl -w net.core.netdev_max_backlog=65536       >/dev/null
sysctl -w net.core.somaxconn=65535                >/dev/null
sysctl -w net.core.optmem_max=2097152             >/dev/null
sysctl -w net.core.netdev_budget=600              >/dev/null
sysctl -w net.core.netdev_budget_usecs=8000       >/dev/null

# TCP buffers: min / default / max  (4KB / 2MB / 16MB)
sysctl -w net.ipv4.tcp_rmem="4096 2097152 16777216"   >/dev/null
sysctl -w net.ipv4.tcp_wmem="4096 2097152 16777216"   >/dev/null
sysctl -w net.ipv4.udp_rmem_min=8192                  >/dev/null
sysctl -w net.ipv4.udp_wmem_min=8192                  >/dev/null

# TCP performance
sysctl -w net.ipv4.tcp_fastopen=3                      >/dev/null
sysctl -w net.ipv4.tcp_tw_reuse=1                      >/dev/null
sysctl -w net.ipv4.tcp_fin_timeout=10                  >/dev/null
sysctl -w net.ipv4.tcp_slow_start_after_idle=0         >/dev/null
sysctl -w net.ipv4.tcp_mtu_probing=1                   >/dev/null
sysctl -w net.ipv4.tcp_timestamps=1                    >/dev/null
sysctl -w net.ipv4.tcp_sack=1                          >/dev/null
sysctl -w net.ipv4.tcp_window_scaling=1                >/dev/null
sysctl -w net.ipv4.tcp_no_metrics_save=1               >/dev/null
sysctl -w net.ipv4.tcp_ecn=1                           >/dev/null
sysctl -w net.ipv4.tcp_adv_win_scale=2                 >/dev/null
sysctl -w net.ipv4.tcp_max_syn_backlog=65536           >/dev/null
sysctl -w net.ipv4.tcp_max_tw_buckets=2000000          >/dev/null
sysctl -w net.ipv4.tcp_syncookies=1                    >/dev/null
sysctl -w net.ipv4.tcp_keepalive_time=60               >/dev/null
sysctl -w net.ipv4.tcp_keepalive_intvl=10              >/dev/null
sysctl -w net.ipv4.tcp_keepalive_probes=6              >/dev/null

# Low-latency congestion control (BBR if available, else CUBIC)
if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    modprobe sch_fq 2>/dev/null || true
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr      >/dev/null
    sysctl -w net.core.default_qdisc=fq                >/dev/null 2>&1 || warn "  → Could not set default_qdisc=fq (module missing?)"
    log "  → BBR congestion control + fq qdisc"
else
    modprobe tcp_bbr 2>/dev/null || true
    if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        modprobe sch_fq 2>/dev/null || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr  >/dev/null
        sysctl -w net.core.default_qdisc=fq            >/dev/null 2>&1 || true
        log "  → BBR congestion control (loaded module)"
    else
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null
        warn "  → BBR not available, using CUBIC"
    fi
fi

# IPv6 matching buffers
sysctl -w net.ipv6.conf.all.accept_ra=2               >/dev/null 2>&1 || true

# Neighbor table
sysctl -w net.ipv4.neigh.default.gc_thresh1=4096      >/dev/null
sysctl -w net.ipv4.neigh.default.gc_thresh2=8192      >/dev/null
sysctl -w net.ipv4.neigh.default.gc_thresh3=16384     >/dev/null

###############################################################################
# 2. HUGEPAGES
###############################################################################
if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
    echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
    log "  → THP set to madvise"
fi

###############################################################################
# 3. SYSCTL — KERNEL / SCHEDULER
###############################################################################
log "Tuning kernel scheduler..."

# Autogroup — helps desktop responsiveness under load
sysctl -w kernel.sched_autogroup_enabled=1            >/dev/null 2>&1 || true

# CFS tunables (ignored under EEVDF/BORE but applied if running vanilla CFS)
sysctl -w kernel.sched_cfs_bandwidth_slice_us=500     >/dev/null 2>&1 || true
sysctl -w kernel.sched_child_runs_first=0             >/dev/null 2>&1 || true
sysctl -w kernel.sched_min_granularity_ns=500000      >/dev/null 2>&1 || true
sysctl -w kernel.sched_wakeup_granularity_ns=500000   >/dev/null 2>&1 || true
sysctl -w kernel.sched_latency_ns=4000000             >/dev/null 2>&1 || true

# Migration cost — higher value keeps tasks on the same core longer (better cache locality)
sysctl -w kernel.sched_migration_cost_ns=500000       >/dev/null 2>&1 || true
sysctl -w kernel.sched_nr_migrate=8                   >/dev/null 2>&1 || true
sysctl -w kernel.timer_migration=0                    >/dev/null 2>&1 || true

# BORE scheduler tunables (CachyOS ships BORE on EEVDF — these are no-ops on vanilla CFS)
if sysctl kernel.sched_burst_cache_lifetime &>/dev/null; then
    log "  → BORE scheduler detected, tuning burst params"
    sysctl -w kernel.sched_burst_smoothness_long=0    >/dev/null 2>&1 || true
    sysctl -w kernel.sched_burst_smoothness_short=0   >/dev/null 2>&1 || true
    sysctl -w kernel.sched_burst_penalty_scale=1216   >/dev/null 2>&1 || true
fi

# Preemption / real-time throttling
sysctl -w kernel.sched_rt_runtime_us=980000           >/dev/null 2>&1 || true

# Watchdog off for less jitter
sysctl -w kernel.nmi_watchdog=0                       >/dev/null 2>&1 || true
sysctl -w kernel.soft_watchdog=0                      >/dev/null 2>&1 || true
sysctl -w kernel.watchdog=0                           >/dev/null 2>&1 || true
sysctl -w kernel.watchdog_thresh=0                    >/dev/null 2>&1 || true

# Process limits
sysctl -w kernel.pid_max=4194304                      >/dev/null
sysctl -w fs.file-max=2097152                         >/dev/null
sysctl -w fs.inotify.max_user_watches=1048576         >/dev/null
sysctl -w fs.inotify.max_user_instances=8192          >/dev/null

###############################################################################
# 4. CPU GOVERNOR — PERFORMANCE
###############################################################################
log "Setting CPU governor to performance..."

AVAILABLE_GOVS=""
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]]; then
    AVAILABLE_GOVS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)
fi

for gov_path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$gov_path" ]] || continue
    if echo "$AVAILABLE_GOVS" | grep -q performance; then
        echo performance > "$gov_path" 2>/dev/null || true
    fi
done

# AMD P-State driver tuning
if [[ -d /sys/devices/system/cpu/amd_pstate ]]; then
    log "  → AMD P-State detected"
    # Prefer performance EPP
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [[ -f "$epp" ]] && echo performance > "$epp" 2>/dev/null || true
    done
    # Set boost
    for boost in /sys/devices/system/cpu/cpu*/cpufreq/boost; do
        [[ -f "$boost" ]] && echo 1 > "$boost" 2>/dev/null || true
    done
    # Pin min frequency to max — eliminates ramp-up latency
    for min_freq in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
        [[ -f "$min_freq" ]] || continue
        MAX_FREQ=$(cat "${min_freq/min/max}" 2>/dev/null)
        [[ -n "$MAX_FREQ" ]] && echo "$MAX_FREQ" > "$min_freq" 2>/dev/null || true
    done
    log "  → Min frequency pinned to max (no ramp-up delay)"
fi

# Global boost
[[ -f /sys/devices/system/cpu/cpufreq/boost ]] && echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true

# Disable C-states deeper than C1 for lowest latency (aggressive — comment out if power matters)
if [[ -d /sys/devices/system/cpu/cpu0/cpuidle ]]; then
    for cpu_dir in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]*; do
        [[ -f "$cpu_dir/disable" ]] && echo 1 > "$cpu_dir/disable" 2>/dev/null || true
    done
    log "  → Deep C-states (>C1) disabled"
fi

# PM QoS — request minimum latency from CPU
if [[ -f /dev/cpu_dma_latency ]]; then
    exec 3<>/dev/cpu_dma_latency
    echo -ne '\x00\x00\x00\x00' >&3
    log "  → cpu_dma_latency pinned to 0µs"
fi

###############################################################################
# 5. AMD GPU (amdgpu) TUNING
###############################################################################
log "Tuning AMD GPU..."

for hwmon in /sys/class/drm/card*/device; do
    [[ -f "$hwmon/vendor" ]] || continue
    VENDOR=$(cat "$hwmon/vendor" 2>/dev/null)
    [[ "$VENDOR" == "0x1002" ]] || continue   # AMD vendor ID

    log "  → Found AMD GPU at $hwmon"

    # Power profile: use VR (3D_FULL_SCREEN) or custom performance
    if [[ -f "$hwmon/power_dpm_force_performance_level" ]]; then
        echo manual > "$hwmon/power_dpm_force_performance_level" 2>/dev/null || true
    fi

    # Force highest power profile mode
    if [[ -f "$hwmon/pp_power_profile_mode" ]]; then
        # Profile 4 = VR, Profile 5 = Compute, Profile 3 = 3D Fullscreen
        # 3D fullscreen is generally best for gaming
        PP_3D=$(grep -n "3D_FULL_SCREEN" "$hwmon/pp_power_profile_mode" 2>/dev/null | head -1 | cut -d: -f1)
        if [[ -n "$PP_3D" ]]; then
            PROFILE_NUM=$((PP_3D - 1))
            echo "$PROFILE_NUM" > "$hwmon/pp_power_profile_mode" 2>/dev/null || true
            log "  → Power profile: 3D_FULL_SCREEN (index $PROFILE_NUM)"
        else
            # fallback: just try index 1 (usually 3D)
            echo 1 > "$hwmon/pp_power_profile_mode" 2>/dev/null || true
        fi
    fi

    # Force highest GPU clock level
    if [[ -f "$hwmon/pp_dpm_sclk" ]]; then
        MAX_SCLK=$(cat "$hwmon/pp_dpm_sclk" 2>/dev/null | tail -1 | awk '{print $0}' | grep -oP '^\d+')
        if [[ -n "$MAX_SCLK" ]]; then
            echo "$MAX_SCLK" > "$hwmon/pp_dpm_sclk" 2>/dev/null || true
            log "  → GPU clock forced to level $MAX_SCLK"
        fi
    fi

    # Force highest memory clock level
    if [[ -f "$hwmon/pp_dpm_mclk" ]]; then
        MAX_MCLK=$(cat "$hwmon/pp_dpm_mclk" 2>/dev/null | tail -1 | awk '{print $0}' | grep -oP '^\d+')
        if [[ -n "$MAX_MCLK" ]]; then
            echo "$MAX_MCLK" > "$hwmon/pp_dpm_mclk" 2>/dev/null || true
            log "  → VRAM clock forced to level $MAX_MCLK"
        fi
    fi

    # Set fan to automatic (avoids thermal throttle)
    for fan in "$hwmon"/hwmon/hwmon*/pwm1_enable; do
        [[ -f "$fan" ]] && echo 2 > "$fan" 2>/dev/null || true
    done

    # GPU power limit to max
    for power_cap in "$hwmon"/hwmon/hwmon*/power1_cap; do
        if [[ -f "$power_cap" ]]; then
            MAX_POWER=$(cat "${power_cap}_max" 2>/dev/null || echo "")
            if [[ -n "$MAX_POWER" && "$MAX_POWER" -gt 0 ]]; then
                echo "$MAX_POWER" > "$power_cap" 2>/dev/null || true
                log "  → Power cap set to max: $((MAX_POWER / 1000000))W"
            fi
        fi
    done
done

# AMDGPU kernel module params (for next boot — informational)
if lsmod | grep -q amdgpu; then
    log "  → Tip: Add 'amdgpu.ppfeaturemask=0xffffffff' to kernel cmdline for full OC control"
fi

###############################################################################
# 5c. AMD CPU — TOPOLOGY & CACHE TUNING
###############################################################################
log "Tuning AMD CPU specifics..."

# AMD P-State — prefer active mode with guided autonomous
if [[ -f /sys/devices/system/cpu/amd_pstate/status ]]; then
    PSTATE_STATUS=$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null)
    log "  → AMD P-State mode: $PSTATE_STATUS"

    # If guided or passive, try switching to active for better boosting
    if [[ "$PSTATE_STATUS" != "active" ]]; then
        echo active > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true
        NEW_STATUS=$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null)
        log "  → Switched P-State to: $NEW_STATUS"
    fi
fi

# AMD Precision Boost Overdrive — allow max single-thread boost
for cpu_boost in /sys/devices/system/cpu/cpu*/cpufreq/boost; do
    [[ -f "$cpu_boost" ]] && echo 1 > "$cpu_boost" 2>/dev/null || true
done

# Prefer performance bias per-core
for epb in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do
    [[ -f "$epb" ]] && echo 0 > "$epb" 2>/dev/null || true
done

###############################################################################
# 5d. AMD IOMMU / KERNEL MODULE TUNING
###############################################################################
log "Tuning AMD kernel modules..."

# Ensure IOMMU passthrough for less DMA overhead
# (Runtime — full effect needs cmdline: amd_iommu=on iommu=pt)
if [[ -d /sys/kernel/iommu_groups ]]; then
    log "  → IOMMU groups detected — recommend 'iommu=pt' in cmdline for passthrough"
fi

# amdgpu module params — set runtime where possible
if [[ -d /sys/module/amdgpu/parameters ]]; then
    # Enable GPU recovery on hang
    echo 1 > /sys/module/amdgpu/parameters/gpu_recovery 2>/dev/null || true
    log "  → amdgpu module params tuned"
fi

# Write modprobe config for boot persistence
cat > /etc/modprobe.d/99-amdgpu-performance.conf <<'MODPROBE'
# Full power / OC feature mask
options amdgpu ppfeaturemask=0xffffffff
# GPU recovery on hang
options amdgpu gpu_recovery=1
# Freesync on by default
options amdgpu freesync_video=1
MODPROBE

log "  → Written /etc/modprobe.d/99-amdgpu-performance.conf"

# Write Xorg/Wayland tearfree config for AMD
XORG_AMD_CONF="/etc/X11/xorg.conf.d/20-amdgpu.conf"
if [[ -d /etc/X11/xorg.conf.d ]] || mkdir -p /etc/X11/xorg.conf.d 2>/dev/null; then
    cat > "$XORG_AMD_CONF" <<'XORG'
Section "Device"
    Identifier  "AMD"
    Driver      "amdgpu"
    Option      "TearFree"       "true"
    Option      "VariableRefresh" "true"
    Option      "DRI"            "3"
    Option      "AccelMethod"    "glamor"
EndSection
XORG
    log "  → Written $XORG_AMD_CONF (TearFree + VRR + DRI3)"
fi

###############################################################################
# 6. I/O SCHEDULER
###############################################################################
log "Tuning I/O schedulers..."

for dev in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
    [[ -d "$dev" ]] || continue
    DEVNAME=$(basename "$dev")

    # Check rotational
    ROTATIONAL=$(cat "$dev/queue/rotational" 2>/dev/null || echo 1)
    SCHED_FILE="$dev/queue/scheduler"
    [[ -f "$SCHED_FILE" ]] || continue

    AVAILABLE=$(cat "$SCHED_FILE")

    if [[ "$ROTATIONAL" == "0" ]]; then
        # SSD/NVMe — none or mq-deadline
        if echo "$AVAILABLE" | grep -q "none"; then
            echo none > "$SCHED_FILE" 2>/dev/null || true
            log "  → $DEVNAME (SSD): scheduler=none"
        elif echo "$AVAILABLE" | grep -q "mq-deadline"; then
            echo mq-deadline > "$SCHED_FILE" 2>/dev/null || true
            log "  → $DEVNAME (SSD): scheduler=mq-deadline"
        fi
        # Increase NVMe queue depth
        [[ -f "$dev/queue/nr_requests" ]] && echo 2048 > "$dev/queue/nr_requests" 2>/dev/null || true
    else
        # HDD — bfq or mq-deadline
        if echo "$AVAILABLE" | grep -q "bfq"; then
            echo bfq > "$SCHED_FILE" 2>/dev/null || true
            log "  → $DEVNAME (HDD): scheduler=bfq"
        fi
    fi

    # Reduce read-ahead for SSDs, increase for HDDs
    if [[ "$ROTATIONAL" == "0" ]]; then
        echo 256 > "$dev/queue/read_ahead_kb" 2>/dev/null || true
    else
        echo 2048 > "$dev/queue/read_ahead_kb" 2>/dev/null || true
    fi

    # Disable I/O stats for less overhead
    echo 0 > "$dev/queue/iostats" 2>/dev/null || true

    # Disable add_random for less entropy overhead
    echo 0 > "$dev/queue/add_random" 2>/dev/null || true
done

###############################################################################
# 7. IRQ BALANCING & NIC TUNING
###############################################################################
log "Tuning network interfaces..."

# Stop irqbalance — we want manual/static affinity for lowest jitter
if systemctl is-active --quiet irqbalance 2>/dev/null; then
    systemctl stop irqbalance 2>/dev/null || true
    systemctl disable irqbalance 2>/dev/null || true
    log "  → Disabled irqbalance"
fi

for iface in /sys/class/net/*; do
    IFNAME=$(basename "$iface")
    [[ "$IFNAME" == "lo" ]] && continue
    [[ -d "$iface/device" ]] || continue   # skip virtual

    # Increase TX queue length (safe — no driver-level changes)
    ip link set "$IFNAME" txqueuelen 10000 2>/dev/null || true

    log "  → $IFNAME: txqueuelen tuned"
done

###############################################################################
# 8. KERNEL TUNABLES — MISC
###############################################################################
log "Misc kernel tuning..."

# Disable kernel audit (reduces syscall overhead)
if command -v auditctl &>/dev/null; then
    auditctl -e 0 2>/dev/null || true
fi

# NUMA balancing off for desktop (avoids page migration jitter)
sysctl -w kernel.numa_balancing=0                      >/dev/null 2>&1 || true

# Reduce printk verbosity to avoid log spam impacting perf
sysctl -w kernel.printk="3 3 3 3"                      >/dev/null 2>&1 || true

# Randomize VA space (keep for security, but note it's a tradeoff)
sysctl -w kernel.randomize_va_space=2                  >/dev/null

# Split lock detection off (can cause perf hits on some workloads)
if [[ -f /sys/kernel/debug/x86/split_lock_detect ]]; then
    echo 0 > /sys/kernel/debug/x86/split_lock_detect 2>/dev/null || true
fi

###############################################################################
# 9. POWER MANAGEMENT — DISABLE FOR LATENCY
###############################################################################
log "Disabling power-saving features..."

# PCI ASPM off
if [[ -f /sys/module/pcie_aspm/parameters/policy ]]; then
    echo performance > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
    log "  → PCIe ASPM → performance"
fi

# USB autosuspend off
for usb_auto in /sys/bus/usb/devices/*/power/autosuspend; do
    echo -1 > "$usb_auto" 2>/dev/null || true
done
for usb_ctrl in /sys/bus/usb/devices/*/power/control; do
    echo on > "$usb_ctrl" 2>/dev/null || true
done
log "  → USB autosuspend disabled"

# SATA link power off
for sata_pm in /sys/class/scsi_host/host*/link_power_management_policy; do
    echo max_performance > "$sata_pm" 2>/dev/null || true
done

# PCI runtime PM off
for pci_pm in /sys/bus/pci/devices/*/power/control; do
    echo on > "$pci_pm" 2>/dev/null || true
done
log "  → PCI/SATA power management → max performance"

# Wi-Fi power save off
for wlan in /sys/class/net/wl*; do
    WNAME=$(basename "$wlan")
    iw dev "$WNAME" set power_save off 2>/dev/null || true
done

###############################################################################
# 10. ULIMITS FOR CURRENT SESSION
###############################################################################
log "Setting ulimits..."

ulimit -n 1048576 2>/dev/null || true
ulimit -l unlimited 2>/dev/null || true

# Write limits.conf for persistence
cat > /etc/security/limits.d/99-performance.conf <<EOF
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    memlock   unlimited
*    hard    memlock   unlimited
*    soft    nproc     unlimited
*    hard    nproc     unlimited
*    soft    nice      -20
*    hard    nice      -20
*    soft    rtprio    99
*    hard    rtprio    99
EOF
log "  → /etc/security/limits.d/99-performance.conf written"

###############################################################################
# 11. KERNEL CMDLINE RECOMMENDATIONS
###############################################################################
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN} Recommended kernel cmdline parameters (add to bootloader)${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  # Low latency & performance (add to /etc/default/grub or systemd-boot entry):${NC}"
echo ""
echo "  preempt=full"
echo "  threadirqs"
echo "  tsc=reliable"
echo "  clocksource=tsc"
echo "  hpet=disable"
echo "  idle=nomwait"
echo "  processor.max_cstate=1"
echo "  amd_pstate=active"
echo "  amd_iommu=on"
echo "  iommu=pt"
echo "  amdgpu.ppfeaturemask=0xffffffff"
echo "  amdgpu.freesync_video=1"
echo "  pcie_aspm=off"
echo "  nowatchdog"
echo "  nmi_watchdog=0"
echo "  audit=0"
echo "  nosoftlockup"
echo "  skew_tick=1"
echo "  rcupdate.rcu_expedited=1"
echo "  split_lock_detect=off"
echo ""
echo -e "${RED}  # DANGER — disables CPU security mitigations for extra perf:${NC}"
echo "  mitigations=off"
echo ""

###############################################################################
# 12. WRITE PERSISTENT SYSCTL CONFIG
###############################################################################
log "Writing persistent sysctl config..."

cat > /etc/sysctl.d/99-cachyos-performance.conf <<'SYSCTL'
# ── Network ──────────────────────────────────────────
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535
net.core.optmem_max = 2097152
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.default_qdisc = fq

net.ipv4.tcp_rmem = 4096 2097152 16777216
net.ipv4.tcp_wmem = 4096 2097152 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_congestion_control = bbr

net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# ── Kernel / Scheduler ──────────────────────────────
kernel.sched_autogroup_enabled = 1
kernel.nmi_watchdog = 0
kernel.numa_balancing = 0
kernel.pid_max = 4194304
kernel.printk = 3 3 3 3

# ── FS ───────────────────────────────────────────────
fs.file-max = 2097152
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
SYSCTL

CWND=1820
ip route show | while read -r route; do
    echo "$route" | grep -q "initcwnd" && continue
    ip route replace $route initcwnd $CWND initrwnd $CWND
done
ip route show | while read -r route; do
    echo "$route" | grep -q "quickack" && continue
    ip route replace $route quickack 1
done

log "  → /etc/sysctl.d/99-cachyos-performance.conf written"

###############################################################################
# DONE
###############################################################################
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  All optimizations applied!                             ║${NC}"
echo -e "${GREEN}║                                                         ║${NC}"
echo -e "${GREEN}║  • Run with --install to persist via systemd service    ║${NC}"
echo -e "${GREEN}║  • Add kernel cmdline params above for full effect      ║${NC}"
echo -e "${GREEN}║  • Reboot recommended for kernel-level changes          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
