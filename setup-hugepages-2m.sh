#!/bin/bash
# ============================================================
# DonutSMP - 2MB Huge Pages Setup Script
# Run as root on each OVH dedicated server
# Usage: sudo ./setup-hugepages-2m.sh [HEAP_SIZE_GB]
# Example: sudo ./setup-hugepages-2m.sh 35
# ============================================================

set -euo pipefail

HEAP_GB="${1:-35}"
# Pages needed: heap in MB / 2MB per page + 512 extra for JVM overhead (code cache, metaspace, GC)
PAGES=$(( (HEAP_GB * 1024 / 2) + 512 ))

echo "=========================================="
echo " DonutSMP 2MB Huge Pages Setup"
echo "=========================================="
echo "Heap size:       ${HEAP_GB}G"
echo "Pages to alloc:  ${PAGES} (x 2MB = $(( PAGES * 2 ))MB)"
echo ""

# -------------------------------------------
# 1. Check if running as root
# -------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# -------------------------------------------
# 2. Check available memory
# -------------------------------------------
TOTAL_MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
REQUIRED_MB=$(( PAGES * 2 + 4096 ))  # pages + 4GB for OS

echo "[INFO] Total system memory: $(( TOTAL_MEM_MB / 1024 ))G"
echo "[INFO] Pages will consume:  $(( PAGES * 2 / 1024 ))G"
echo "[INFO] Reserved for OS:     4G"

if [[ $TOTAL_MEM_MB -lt $REQUIRED_MB ]]; then
    echo "[FAIL] Not enough memory. Need $(( REQUIRED_MB / 1024 ))G, have $(( TOTAL_MEM_MB / 1024 ))G"
    exit 1
fi
echo "[OK] Sufficient memory"
echo ""

# -------------------------------------------
# 3. Configure memory lock limits
# -------------------------------------------
echo "--- Configuring memory lock limits ---"

LIMITS_FILE="/etc/security/limits.d/99-hugepages.conf"
cat > "$LIMITS_FILE" <<EOF
# DonutSMP - Allow locking memory for huge pages
*    soft    memlock    unlimited
*    hard    memlock    unlimited
root soft    memlock    unlimited
root hard    memlock    unlimited
EOF
echo "[OK] $LIMITS_FILE"

# -------------------------------------------
# 4. Configure sysctl
# -------------------------------------------
echo ""
echo "--- Configuring sysctl ---"

SYSCTL_FILE="/etc/sysctl.d/99-hugepages.conf"
cat > "$SYSCTL_FILE" <<EOF
# DonutSMP - Huge pages and VM tuning
# Generated on $(date)
# Heap: ${HEAP_GB}G -> ${PAGES} x 2MB pages

# Number of 2MB huge pages
vm.nr_hugepages = ${PAGES}

# Increase max memory map areas for large JVM heaps
vm.max_map_count = 2097152

# Allow overcommit for large page reservations
vm.overcommit_memory = 1

# Minimize swapping - heap should never be swapped
vm.swappiness = 1

# NUMA: let allocator handle placement
vm.zone_reclaim_mode = 0
EOF

echo "[OK] $SYSCTL_FILE"

# -------------------------------------------
# 5. Apply sysctl (allocate pages now)
# -------------------------------------------
echo ""
echo "--- Allocating huge pages ---"

# Drop caches first to free contiguous memory
sync
echo 3 > /proc/sys/vm/drop_caches
sleep 1

# Apply sysctl
sysctl --system > /dev/null 2>&1

# Also write directly in case sysctl didn't apply nr_hugepages
echo "$PAGES" > /proc/sys/vm/nr_hugepages
sleep 2

# -------------------------------------------
# 6. Verify allocation
# -------------------------------------------
echo ""
echo "--- Verification ---"

ALLOCATED=$(cat /proc/sys/vm/nr_hugepages)
FREE=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
TOTAL_CHECK=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
PAGE_SIZE=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')

echo "Requested:    ${PAGES} pages"
echo "Allocated:    ${ALLOCATED} pages"
echo "Free:         ${FREE} pages"
echo "Page size:    ${PAGE_SIZE} kB"
echo ""

if [[ $ALLOCATED -ge $PAGES ]]; then
    echo "[OK] All ${PAGES} pages allocated successfully!"
elif [[ $ALLOCATED -gt 0 ]]; then
    MISSING=$(( PAGES - ALLOCATED ))
    echo "[WARN] Only ${ALLOCATED}/${PAGES} pages allocated (${MISSING} missing)"
    echo "       Memory fragmentation prevented full allocation."
    echo "       Options:"
    echo "         1. Reboot the server and re-run this script"
    echo "         2. Reduce heap size"
    echo "         3. Use what's available ($(( ALLOCATED * 2 / 1024 ))G usable)"
else
    echo "[FAIL] No pages allocated!"
    echo "       Check available memory and try after a fresh reboot."
fi

echo ""

# -------------------------------------------
# 7. Check per-NUMA node distribution
# -------------------------------------------
echo "--- NUMA Distribution ---"
for node_dir in /sys/devices/system/node/node*; do
    if [[ -d "$node_dir/hugepages/hugepages-2048kB" ]]; then
        node=$(basename "$node_dir")
        nr=$(cat "$node_dir/hugepages/hugepages-2048kB/nr_hugepages")
        free=$(cat "$node_dir/hugepages/hugepages-2048kB/free_hugepages")
        echo "  ${node}: ${nr} allocated, ${free} free"
    fi
done

echo ""

# -------------------------------------------
# 8. Mount hugetlbfs if not mounted
# -------------------------------------------
echo "--- Hugetlbfs Mount ---"
if mount | grep -q hugetlbfs; then
    echo "[OK] hugetlbfs already mounted"
    mount | grep hugetlbfs
else
    mkdir -p /dev/hugepages
    mount -t hugetlbfs nodev /dev/hugepages
    if ! grep -q "hugetlbfs" /etc/fstab; then
        echo "hugetlbfs /dev/hugepages hugetlbfs defaults 0 0" >> /etc/fstab
    fi
    echo "[OK] Mounted hugetlbfs at /dev/hugepages"
fi

echo ""
echo "=========================================="
echo " Done! Pages persist across reboots via"
echo " $SYSCTL_FILE"
echo "=========================================="
echo ""
echo "JVM flag (already in your startup):"
echo "  -XX:+UseLargePages"
echo ""
echo "Full meminfo:"
grep Huge /proc/meminfo
