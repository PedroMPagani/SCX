#!/usr/bin/env bash
###############################################################################
#  DonutSMP - psycachy kernel installer for OVH Ubuntu nodes
#  
#  What this does:
#    1. Fixes systemd-networkd-wait-online to prevent boot hangs
#    2. Downloads & installs psycachy 6.17.13 kernel from GitHub
#    3. Verifies RAID support & initramfs integrity
#    4. Configures GRUB to boot psycachy with tuned cmdline params
#    5. Sets psycachy as the default boot kernel
#
#  Usage:  sudo bash install-psycachy.sh
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo $0"

PSYCACHY_TAG="6.17.13"
PSYCACHY_VERSION="6.17.13-3"
GITHUB_BASE="https://github.com/psygreg/linux-psycachy/releases/download/${PSYCACHY_TAG}"
WORK_DIR="/tmp/psycachy-install"

###############################################################################
# 1. Fix systemd-networkd-wait-online (prevents boot hang after systemd upgrades)
###############################################################################
log "Configuring systemd-networkd-wait-online timeout..."

# Detect the two main NIC names on this machine
PRIMARY_NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(enp|eno|eth)' | head -1 || true)
SECONDARY_NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(enp|eno|eth)' | tail -1 || true)

if [[ -n "$PRIMARY_NIC" && -n "$SECONDARY_NIC" && "$PRIMARY_NIC" != "$SECONDARY_NIC" ]]; then
    log "  Detected NICs: ${PRIMARY_NIC}, ${SECONDARY_NIC}"
    WAIT_ONLINE_ARGS="--interface=${PRIMARY_NIC} --interface=${SECONDARY_NIC} --timeout=10"
else
    warn "  Could not detect two NICs, using generic timeout only"
    WAIT_ONLINE_ARGS="--any --timeout=10"
fi

mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d/
cat > /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online ${WAIT_ONLINE_ARGS}
EOF

systemctl daemon-reload
log "  Done — networkd-wait-online will timeout after 10s"

###############################################################################
# 2. Download psycachy kernel debs
###############################################################################
log "Downloading psycachy ${PSYCACHY_VERSION} kernel packages..."

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

IMAGE_DEB="linux-image-psycachy_${PSYCACHY_VERSION}_amd64.deb"
HEADERS_DEB="linux-headers-psycachy_${PSYCACHY_VERSION}_amd64.deb"

# Download with checksums
if [[ ! -f "$IMAGE_DEB" ]]; then
    curl -fSL -o "$IMAGE_DEB" "${GITHUB_BASE}/${IMAGE_DEB}"
fi
if [[ ! -f "$HEADERS_DEB" ]]; then
    curl -fSL -o "$HEADERS_DEB" "${GITHUB_BASE}/${HEADERS_DEB}"
fi

# Verify checksums
log "Verifying checksums..."
echo "a8cb3fcc0b654ef62ec1fb89e7e0c34bd13d4ceff755ebb6b983a2a948dcdd43  ${IMAGE_DEB}" | sha256sum -c -
echo "902eb973ff2215c89c927fd140914cd2d0011a4956b875e3297abe287da8bd73  ${HEADERS_DEB}" | sha256sum -c -
log "  Checksums OK"

###############################################################################
# 3. Install kernel packages
###############################################################################
log "Installing psycachy kernel..."
dpkg -i "$IMAGE_DEB" "$HEADERS_DEB"
log "  Kernel installed"

###############################################################################
# 4. Verify RAID support & initramfs
###############################################################################
KVER="6.17.13-psycachy"
log "Checking RAID support in kernel config..."

KCONFIG="/boot/config-${KVER}"
if [[ -f "$KCONFIG" ]]; then
    # Check md/raid config options
    MD_BUILTIN=$(grep -c "^CONFIG_MD=y" "$KCONFIG" || true)
    RAID0=$(grep "^CONFIG_MD_RAID0=" "$KCONFIG" || true)
    RAID1=$(grep "^CONFIG_MD_RAID1=" "$KCONFIG" || true)

    if [[ "$MD_BUILTIN" -eq 0 ]]; then
        err "  CONFIG_MD is not enabled — this kernel cannot boot on md RAID!"
    fi
    log "  CONFIG_MD=y (built-in)"

    # Check if raid modules are built-in or modules
    RAID_AS_MODULE=false
    for mod in CONFIG_MD_RAID0 CONFIG_MD_RAID1 CONFIG_MD_RAID10 CONFIG_MD_RAID456; do
        val=$(grep "^${mod}=" "$KCONFIG" || true)
        if [[ "$val" == *"=m" ]]; then
            RAID_AS_MODULE=true
        fi
        log "  ${val:-${mod} not set}"
    done

    # If any RAID is a module, verify initramfs includes them
    if $RAID_AS_MODULE; then
        log "Checking initramfs for RAID modules..."
        INITRD="/boot/initrd.img-${KVER}"
        if [[ -f "$INITRD" ]]; then
            MISSING_MODS=""
            # Only check modules that are =m, not =y (built-in)
            # CONFIG_MD_RAID0=m  -> module name is raid0
            # CONFIG_MD_RAID1=m  -> module name is raid1
            # CONFIG_MD_RAID10=m -> module name is raid10
            # CONFIG_MD_RAID456=m -> module name is raid456
            # CONFIG_MD=y (md_mod) is built-in, skip it
            for cfg_mod in CONFIG_MD_RAID0:raid0 CONFIG_MD_RAID1:raid1 CONFIG_MD_RAID10:raid10 CONFIG_MD_RAID456:raid456; do
                cfg="${cfg_mod%%:*}"
                mod="${cfg_mod##*:}"
                val=$(grep "^${cfg}=" "$KCONFIG" || true)
                if [[ "$val" == *"=m" ]]; then
                    if ! lsinitramfs "$INITRD" 2>/dev/null | grep -q "${mod}"; then
                        MISSING_MODS="${MISSING_MODS} ${mod}"
                    fi
                fi
            done

            if [[ -n "$MISSING_MODS" ]]; then
                warn "  Missing RAID modules in initramfs:${MISSING_MODS}"
                log "  Regenerating initramfs to include RAID modules..."

                # Ensure mdadm modules are forced into initramfs
                mkdir -p /etc/initramfs-tools/conf.d
                echo 'MODULES=most' > /etc/initramfs-tools/conf.d/raid-modules.conf

                update-initramfs -u -k "$KVER"
                log "  initramfs regenerated"

                # Verify again
                STILL_MISSING=""
                for cfg_mod in CONFIG_MD_RAID0:raid0 CONFIG_MD_RAID1:raid1; do
                    cfg="${cfg_mod%%:*}"
                    mod="${cfg_mod##*:}"
                    val=$(grep "^${cfg}=" "$KCONFIG" || true)
                    if [[ "$val" == *"=m" ]]; then
                        if ! lsinitramfs "$INITRD" 2>/dev/null | grep -q "${mod}"; then
                            STILL_MISSING="${STILL_MISSING} ${mod}"
                        fi
                    fi
                done
                if [[ -n "$STILL_MISSING" ]]; then
                    err "  CRITICAL: RAID modules still missing after regeneration:${STILL_MISSING} — DO NOT REBOOT!"
                fi
                log "  Verified: RAID modules present in initramfs"
            else
                log "  All RAID modules present in initramfs"
            fi
        else
            warn "  initramfs not found at ${INITRD} — regenerating..."
            update-initramfs -c -k "$KVER"
            log "  initramfs created"
        fi
    else
        log "  RAID modules are built-in — no initramfs check needed"
    fi
else
    warn "  Kernel config not found at ${KCONFIG} — skipping RAID check"
    warn "  Make sure this kernel supports md RAID before rebooting!"
fi

###############################################################################
# 5. Configure GRUB
###############################################################################
log "Configuring GRUB..."

# Backup current grub config
cp /etc/default/grub /etc/default/grub.bak.$(date +%s)

# Detect existing OVH base params (everything before our custom additions)
# OVH defaults: nomodeset iommu=pt console=tty0 console=ttyS0,115200n8
OVH_BASE='nomodeset iommu=pt console=tty0 console=ttyS0,115200n8'

# Our tuning params (no idle=poll!)
TUNING_PARAMS='processor.max_cstate=1 amd_pstate.status=active mitigations=off'

# Set the cmdline
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${OVH_BASE} ${TUNING_PARAMS}\"|" /etc/default/grub

# Make psycachy the default kernel (GRUB_DEFAULT=0 boots first entry)
# We need to find the menu entry name after update-grub
sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' /etc/default/grub

log "  GRUB cmdline: ${OVH_BASE} ${TUNING_PARAMS}"

###############################################################################
# 6. Update GRUB and set boot order
###############################################################################
log "Running update-grub..."
update-grub

# Check that psycachy is the first entry
FIRST_ENTRY=$(grep -m1 "menuentry " /boot/grub/grub.cfg | sed "s/menuentry '\\([^']*\\)'.*/\\1/")
if echo "$FIRST_ENTRY" | grep -qi "psycachy"; then
    log "  Default boot: ${FIRST_ENTRY}"
else
    warn "  psycachy is NOT the first boot entry (first is: ${FIRST_ENTRY})"
    warn "  Finding psycachy entry..."
    
    # Find the psycachy menuentry index
    PSYCACHY_ENTRY=$(grep -n "menuentry " /boot/grub/grub.cfg | grep -i psycachy | head -1)
    if [[ -n "$PSYCACHY_ENTRY" ]]; then
        # Use the full menuentry string for GRUB_DEFAULT
        PSYCACHY_TITLE=$(echo "$PSYCACHY_ENTRY" | sed "s/.*menuentry '\\([^']*\\)'.*/\\1/")
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${PSYCACHY_TITLE}\"|" /etc/default/grub
        update-grub
        log "  Set GRUB_DEFAULT to: ${PSYCACHY_TITLE}"
    else
        warn "  Could not find psycachy in GRUB entries — you may need to set GRUB_DEFAULT manually"
    fi
fi

###############################################################################
# 7. Cleanup
###############################################################################
log "Cleaning up..."
rm -rf "$WORK_DIR"

###############################################################################
# Done
###############################################################################
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  psycachy ${PSYCACHY_VERSION} installed successfully!            ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  Reboot to boot into the new kernel:                     ║${NC}"
echo -e "${GREEN}║    sudo reboot                                           ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  After reboot, verify with:                              ║${NC}"
echo -e "${GREEN}║    uname -r  (should show 6.17.13-psycachy)              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
