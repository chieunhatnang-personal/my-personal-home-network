#!/usr/bin/env bash
#
# usb-disk-watchdog.sh
# Generic USB Disk Recovery & Watchdog Manager for Linux / Debian
# Auto-recovery for dropped USB hard drives due to EMI, cable jiggle, or brownouts.
#
set -euo pipefail

SERVICE_NAME="usb-disk-watchdog"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_TARGET="/usr/local/sbin/usb-disk-watchdog-daemon.sh"

log_info() {
    printf "\033[1;32m[INFO]\033[0m %s\n" "$*"
}

log_warn() {
    printf "\033[1;33m[WARN]\033[0m %s\n" "$*"
}

log_err() {
    printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "Please run this script as root (sudo bash $0)"
        exit 1
    fi
}

install_dependencies() {
    local enable_uhub="${1:-0}"
    if [ "$enable_uhub" -eq 1 ]; then
        log_info "Checking and installing dependencies (uhubctl)..."
        if ! command -v uhubctl >/dev/null 2>&1; then
            log_info "Installing uhubctl via apt..."
            apt-get update -qq || true
            apt-get install -y -qq uhubctl || {
                log_warn "Failed to install uhubctl from apt; power-cycling via hub will be skipped if needed."
            }
        else
            log_info "uhubctl is already installed."
        fi
    else
        log_info "uhubctl support is disabled by default; skipping uhubctl installation."
    fi
}

write_daemon_script() {
    local enable_uhub="${1:-0}"
    log_info "Creating monitoring daemon at ${SCRIPT_TARGET} (uhubctl enabled: ${enable_uhub})..."
    cat << 'EOF' > "${SCRIPT_TARGET}"
#!/usr/bin/env bash
#
# usb-disk-watchdog-daemon.sh
# Real-time daemon that tracks USB drives and auto-rebinds / power-cycles when dropped.
#
set -u

STATE_FILE="/run/usb-disk-watchdog.state"
MONITOR_INTERVAL=5
ENABLE_UHUBCTL=__ENABLE_UHUBCTL__
MAX_REBIND_TRIES=5
MAX_UHUB_TRIES=3

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [usb-disk-watchdog] $*"
}

# In-memory tracking tables:
# TRACKED_PATHS: list of persistent ID_PATH strings to monitor
# DISK_NAME[$path]: current kernel name e.g. sda, sdb
# DISK_USB_SYS[$path]: USB device sysfs dir e.g. /sys/bus/usb/devices/1-1
# DISK_HC_DEV[$path]: Host controller device name e.g. 10180000.usb
# DISK_HC_DRIVER[$path]: Host controller driver name e.g. dwc2, ehci-platform
# RETRY_COUNT[$path]: number of failed recoveries attempted
# STATE[$path]: OK | DISCONNECTED | GAVE_UP

declare -A TRACKED_PATHS
declare -A DISK_NAME
declare -A DISK_USB_SYS
declare -A DISK_HC_DEV
declare -A DISK_HC_DRIVER
declare -A RETRY_COUNT
declare -A STATE

get_usb_ancestor() {
    local devpath="$1"
    local cur="/sys${devpath}"
    while [ "$cur" != "/sys" ] && [ "$cur" != "/" ]; do
        if [ -f "$cur/idVendor" ] && [ -f "$cur/idProduct" ]; then
            echo "$cur"
            return 0
        fi
        cur="$(dirname "$cur")"
    done
    return 1
}

get_host_controller() {
    local usb_sys="$1"
    # Find the platform / pci host controller managing this USB bus
    local cur="$usb_sys"
    while [ "$cur" != "/sys" ] && [ "$cur" != "/" ]; do
        if [ -d "$cur/driver" ] && [ -f "$cur/driver/bind" ] && [ -f "$cur/driver/unbind" ]; then
            local drv_path
            drv_path="$(readlink -f "$cur/driver")"
            local drv_name
            drv_name="$(basename "$drv_path")"
            if [ "$drv_name" != "usb" ] && [ "$drv_name" != "hub" ]; then
                echo "$(basename "$cur")|$drv_name"
                return 0
            fi
        fi
        cur="$(dirname "$cur")"
    done
    return 1
}

rescan_disks() {
    # Scan all currently attached USB disks (excluding root disk and partitions)
    local root_disk
    root_disk="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE / 2>/dev/null)" 2>/dev/null || true)"
    [ -z "$root_disk" ] && root_disk="$(basename "$(findmnt -n -o SOURCE / 2>/dev/null)" 2>/dev/null || true)"

    for dev in /sys/block/sd*; do
        [ -e "$dev" ] || continue
        local bname
        bname="$(basename "$dev")"
        [ "$bname" = "$root_disk" ] && continue

        # Check if backed by USB
        local udev_path
        udev_path="$(udevadm info -q property -p "$dev" | awk -F= '/^ID_PATH=/ {print $2}')"
        local devpath
        devpath="$(udevadm info -q property -p "$dev" | awk -F= '/^DEVPATH=/ {print $2}')"

        [ -z "$udev_path" ] && continue
        [ -z "$devpath" ] && continue

        # Only track if partitioned or defined in fstab/mounts
        local is_target=0
        if [ -f /etc/fstab ] && grep -q "/dev/$bname" /etc/fstab; then
            is_target=1
        elif lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -q '/'; then
            is_target=1
        elif ls -d "${dev}/${bname}"* 2>/dev/null | grep -qE "[0-9]$"; then
            is_target=1
        fi
        [ "$is_target" -eq 0 ] && continue

        local usb_sys
        usb_sys="$(get_usb_ancestor "$devpath" || true)"
        [ -z "$usb_sys" ] && continue

        local hc_info
        hc_info="$(get_host_controller "$usb_sys" || true)"
        local hc_dev="${hc_info%%|*}"
        local hc_drv="${hc_info##*|}"

        # If disk was previously marked GAVE_UP, but is now present again physically, reset counter!
        if [ "${STATE[$udev_path]:-}" = "GAVE_UP" ]; then
            log "Detected drive at ID_PATH $udev_path has been physically reconnected. Resuming normal monitoring."
        fi

        TRACKED_PATHS["$udev_path"]=1
        DISK_NAME["$udev_path"]="$bname"
        DISK_USB_SYS["$udev_path"]="$usb_sys"
        DISK_HC_DEV["$udev_path"]="$hc_dev"
        DISK_HC_DRIVER["$udev_path"]="$hc_drv"
        RETRY_COUNT["$udev_path"]=0
        STATE["$udev_path"]="OK"
    done
}

try_rebind_controller() {
    local path="$1"
    local hc_dev="${DISK_HC_DEV[$path]:-}"
    local hc_drv="${DISK_HC_DRIVER[$path]:-}"

    if [ -z "$hc_dev" ] || [ -z "$hc_drv" ]; then
        log "Could not identify Host Controller to rebind for path: $path"
        return 1
    fi

    log "Attempting to rebind Host Controller: $hc_dev (driver: $hc_drv)..."

    # SPECIAL HANDLING FOR EHCI / OHCI COMPANION PAIR (e.g. Rockchip RK312x):
    # When EHCI fails, Linux hands the port over to OHCI (101e0000.usb).
    # If we only rebind EHCI, OHCI holds the physical port hostage!
    # We must unbind OHCI first, rebind EHCI, then rebind OHCI.
    local is_companion_ehci=0
    if [ "$hc_drv" = "ehci-platform" ] && [ -d "/sys/bus/platform/drivers/ohci-platform" ]; then
        is_companion_ehci=1
        log "Detected EHCI Companion setup. Temporarily unbinding OHCI companion to release port..."
        echo "101e0000.usb" > /sys/bus/platform/drivers/ohci-platform/unbind 2>/dev/null || true
        for odev in /sys/bus/platform/drivers/ohci-platform/*.usb; do
            [ -e "$odev" ] && echo "$(basename "$odev")" > /sys/bus/platform/drivers/ohci-platform/unbind 2>/dev/null || true
        done
        sleep 2
    fi

    local unbind_path="/sys/bus/platform/drivers/$hc_drv/unbind"
    local bind_path="/sys/bus/platform/drivers/$hc_drv/bind"

    if [ ! -f "$unbind_path" ]; then
        # Try PCI bus if platform not found
        unbind_path="/sys/bus/pci/drivers/$hc_drv/unbind"
        bind_path="/sys/bus/pci/drivers/$hc_drv/bind"
    fi

    if [ -f "$unbind_path" ] && [ -f "$bind_path" ]; then
        echo "$hc_dev" > "$unbind_path" 2>/dev/null || true
        sleep 3
        echo "$hc_dev" > "$bind_path" 2>/dev/null || true
        # Wait 4-5 seconds for EHCI to enumerate and attach SCSI disk before restoring OHCI companion!
        sleep 4

        # Restore OHCI companion after EHCI has successfully reclaimed port
        if [ "$is_companion_ehci" -eq 1 ]; then
            log "Restoring OHCI companion..."
            echo "101e0000.usb" > /sys/bus/platform/drivers/ohci-platform/bind 2>/dev/null || true
            sleep 2
        fi
        return 0
    else
        log "Bind/unbind path does not exist for driver $hc_drv"
        return 1
    fi
}

try_uhubctl_cycle() {
    local path="$1"
    if ! command -v uhubctl >/dev/null 2>&1; then
        log "uhubctl is not installed, skipping hub power cycle step."
        return 1
    fi

    local hc_dev="${DISK_HC_DEV[$path]:-}"
    log "Attempting power-cycle using uhubctl with strict 5s timeout..."
    if [ -n "$hc_dev" ]; then
        timeout 5 uhubctl -l "$hc_dev" -a cycle -d 2 2>/dev/null || timeout 5 uhubctl -a cycle -d 2 2>/dev/null || true
    else
        timeout 5 uhubctl -a cycle -d 2 2>/dev/null || true
    fi
    sleep 3
    return 0
}

remount_all() {
    log "Remounting partitions and verifying mounts..."

    # Check if any mergerfs pool is currently active/mounted
    local -a active_mergerfs_pools=()
    while read -r _ mpoint fstype _; do
        if [ "$fstype" = "fuse.mergerfs" ]; then
            active_mergerfs_pools+=("$mpoint")
        fi
    done < /proc/mounts

    # Only unmount mergerfs pools if mergerfs is actively mounted on the system
    if [ ${#active_mergerfs_pools[@]} -gt 0 ]; then
        log "Active mergerfs pool(s) detected: ${active_mergerfs_pools[*]}. Temporarily unmounting before refreshing underlying sources..."
        for pool_mp in "${active_mergerfs_pools[@]}"; do
            umount -l "$pool_mp" 2>/dev/null || true
        done
    fi

    # Unmount any dead/dangling mount points where the block device disappeared
    while read -r dev mpoint fstype rest; do
        if [[ "$dev" =~ ^/dev/sd[a-z][0-9] ]] && [ ! -b "$dev" ]; then
            log "Cleaning up stale mount: $dev on $mpoint"
            umount -l "$mpoint" 2>/dev/null || true
        fi
    done < /proc/mounts

    systemctl daemon-reload 2>/dev/null || true
    # Mount all partitions according to /etc/fstab (using UUIDs)
    mount -a 2>/dev/null || true

    # Also remount any known ext4 partitions that were previously mounted
    for p in /dev/sd*[0-9]; do
        [ -b "$p" ] || continue
        local blabel
        blabel="$(lsblk -no LABEL "$p" 2>/dev/null || true)"
        if [ "$blabel" = "PHOTOS" ] && [ ! -d "/root/sda1" ]; then
            mkdir -p /root/sda1
            mount "$p" /root/sda1 2>/dev/null || true
        elif [ "$blabel" = "PHOTO_BACKUP" ] && [ ! -d "/root/sdb1" ]; then
            mkdir -p /root/sdb1
            mount "$p" /root/sdb1 2>/dev/null || true
        fi
    done

    # Remount only the mergerfs pool(s) that were previously active and exist in /etc/fstab
    if [ ${#active_mergerfs_pools[@]} -gt 0 ]; then
        for pool_mp in "${active_mergerfs_pools[@]}"; do
            if grep -q "[[:space:]]${pool_mp}[[:space:]]" /etc/fstab 2>/dev/null; then
                log "Remounting mergerfs pool: $pool_mp"
                mount "$pool_mp" 2>/dev/null || true
            fi
        done
    fi
}

log "Starting usb-disk-watchdog daemon..."
log "Scanning current USB drives..."
rescan_disks

for p in "${!TRACKED_PATHS[@]}"; do
    log "Monitoring drive: ${DISK_NAME[$p]} (Path: $p, Controller: ${DISK_HC_DEV[$p]}, Driver: ${DISK_HC_DRIVER[$p]})"
done

# Tracking cursor for journalctl/dmesg to distinguish past events from recent ones
JOURNAL_CURSOR=""
if command -v journalctl >/dev/null 2>&1; then
    JOURNAL_CURSOR="$(journalctl -e -n 1 --show-cursor 2>/dev/null | awk '/^-- cursor:/ {print $3}' || true)"
fi

while true; do
    sleep "$MONITOR_INTERVAL"

    # Always scan for new or re-attached drives
    for dev in /sys/block/sd*; do
        [ -e "$dev" ] || continue
        local_bname="$(basename "$dev")"
        local_path="$(udevadm info -q property -p "$dev" | awk -F= '/^ID_PATH=/ {print $2}')"
        if [ -n "$local_path" ]; then
            if [ -z "${TRACKED_PATHS[$local_path]:-}" ] || [ "${STATE[$local_path]:-}" = "GAVE_UP" ]; then
                rescan_disks
                break
            fi
        fi
    done

    # Check kernel logs for recent error events
    HAS_RECENT_EVENT=0
    EVENT_DESC=""

    if command -v journalctl >/dev/null 2>&1 && [ -n "$JOURNAL_CURSOR" ]; then
        NEW_LOGS="$(journalctl --after-cursor="$JOURNAL_CURSOR" -k --no-pager 2>/dev/null || true)"
        # Update cursor to latest
        LATEST_CURSOR="$(journalctl -e -n 1 --show-cursor 2>/dev/null | awk '/^-- cursor:/ {print $3}' || true)"
        [ -n "$LATEST_CURSOR" ] && JOURNAL_CURSOR="$LATEST_CURSOR"
    else
        NEW_LOGS="$(dmesg | tail -n 30)"
    fi

    if echo "$NEW_LOGS" | grep -qE "disabled by hub \(EMI\?\)|attempt power cycle|unable to enumerate USB device"; then
        HAS_RECENT_EVENT=1
        EVENT_DESC="Detected power/signal issue (EMI / Power cycle)"
    elif echo "$NEW_LOGS" | grep -qE "USB disconnect|device descriptor read/64, error"; then
        HAS_RECENT_EVENT=1
        EVENT_DESC="Detected cable disconnection (Cable disconnect)"
    elif echo "$NEW_LOGS" | grep -qE "I/O error, dev sd|Buffer I/O error|Synchronize Cache.*failed|tag#.*FAILED"; then
        HAS_RECENT_EVENT=1
        EVENT_DESC="Detected bad block / I/O error"
    fi

    # Check each monitored disk
    for path in "${!TRACKED_PATHS[@]}"; do
        [ "${STATE[$path]}" = "GAVE_UP" ] && continue

        # Verify if disk device or path link is still present in /dev/disk/by-path/
        DISK_PRESENT=0
        if [ -e "/dev/disk/by-path/$path" ]; then
            DISK_PRESENT=1
        fi

        if [ "$DISK_PRESENT" -eq 1 ]; then
            # Drive is healthy and present
            if [ "${STATE[$path]}" != "OK" ]; then
                log "Drive at ID_PATH $path reconnected successfully!"
                STATE["$path"]="OK"
                RETRY_COUNT["$path"]=0
                remount_all
            elif [ "${RETRY_COUNT[$path]}" -gt 0 ]; then
                # Reset retry counter after drive is confirmed present and stable
                RETRY_COUNT["$path"]=0
            fi
            continue
        fi

        # Drive is MISSING!
        CURRENT_RETRIES="${RETRY_COUNT[$path]}"
        log "WARNING: Drive at ID_PATH $path was disconnected! (${EVENT_DESC:-Device lost})"

        if [ "$CURRENT_RETRIES" -lt "$MAX_REBIND_TRIES" ]; then
            CURRENT_RETRIES=$((CURRENT_RETRIES + 1))
            RETRY_COUNT["$path"]="$CURRENT_RETRIES"
            log "Attempting recovery via Controller Rebind (Attempt $CURRENT_RETRIES / $MAX_REBIND_TRIES)..."
            try_rebind_controller "$path"
            remount_all
            # Re-check immediately if the drive came back; if yes, mark OK right away
            if [ -e "/dev/disk/by-path/$path" ]; then
                log "Drive at ID_PATH $path recovered successfully after rebind!"
                STATE["$path"]="OK"
                RETRY_COUNT["$path"]=0
            fi
        elif [ "$ENABLE_UHUBCTL" -eq 1 ] && [ "$CURRENT_RETRIES" -lt $((MAX_REBIND_TRIES + MAX_UHUB_TRIES)) ]; then
            CURRENT_RETRIES=$((CURRENT_RETRIES + 1))
            RETRY_COUNT["$path"]="$CURRENT_RETRIES"
            UHUB_STEP=$((CURRENT_RETRIES - MAX_REBIND_TRIES))
            log "Rebind failed. Attempting recovery via uhubctl power-cycle (Attempt $UHUB_STEP / $MAX_UHUB_TRIES)..."
            try_uhubctl_cycle "$path"
            remount_all
        else
            if [ "$ENABLE_UHUBCTL" -eq 1 ]; then
                log "Exhausted $MAX_REBIND_TRIES Rebind attempts + $MAX_UHUB_TRIES uhubctl attempts, unable to recover drive $path."
            else
                log "Exhausted $MAX_REBIND_TRIES Rebind attempts, unable to recover drive $path."
            fi
            log "Suspending auto-recovery for this drive. If physically reconnected, watchdog will automatically detect and resume monitoring."
            STATE["$path"]="GAVE_UP"
        fi
    done
done
EOF

    sed -i "s/__ENABLE_UHUBCTL__/${enable_uhub}/g" "${SCRIPT_TARGET}"
    chmod +x "${SCRIPT_TARGET}"
}

install_systemd_service() {
    log_info "Creating systemd service at ${SERVICE_FILE}..."
    cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=USB Disk Auto-Recovery Watchdog
After=local-fs.target systemd-udevd.service
Wants=local-fs.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=${SCRIPT_TARGET}
Restart=always
RestartSec=10
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    log_info "Successfully enabled and started service ${SERVICE_NAME}!"
}

remove_systemd_service() {
    log_info "Removing service ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}" "${SCRIPT_TARGET}"
    systemctl daemon-reload
    log_info "Successfully removed service and script files."
}

status_service() {
    systemctl status "${SERVICE_NAME}" --no-pager || true
}

menu() {
    clear
    printf "========================================================\n"
    printf "     USB Disk Auto-Recovery & Watchdog Installer       \n"
    printf "========================================================\n\n"

    local current_uhub=0
    if [ -f "${SCRIPT_TARGET}" ] && grep -q '^ENABLE_UHUBCTL=1' "${SCRIPT_TARGET}"; then
        current_uhub=1
    fi

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        printf "Status: \033[1;32mActive (Running)\033[0m\n"
        if [ "$current_uhub" -eq 1 ]; then
            printf "uhubctl Power-Cycle: \033[1;32mEnabled\033[0m\n\n"
        else
            printf "uhubctl Power-Cycle: \033[1;33mDisabled (Default)\033[0m\n\n"
        fi
        printf "1. Update daemon script and restart service\n"
        printf "2. View logs\n"
        printf "3. Uninstall service from system\n"
        printf "4. Exit\n\n"
        read -rp "Select an option [1-4]: " choice
        case "$choice" in
            1)
                printf "\nEnable uhubctl USB port power-cycling? (Default: No) [y/N]: "
                read -rp "" uhub_ans
                local uhub_flag=0
                if [[ "$uhub_ans" =~ ^[yY]$ ]]; then
                    uhub_flag=1
                fi
                install_dependencies "$uhub_flag"
                write_daemon_script "$uhub_flag"
                install_systemd_service
                log_info "Update completed successfully!"
                ;;
            2)
                journalctl -u "${SERVICE_NAME}" -f
                ;;
            3)
                remove_systemd_service
                ;;
            4)
                exit 0
                ;;
            *)
                log_err "Invalid selection!"
                exit 1
                ;;
        esac
    else
        printf "Status: \033[1;33mNot installed / Inactive\033[0m\n\n"
        printf "1. Install and activate watchdog service\n"
        printf "2. Exit\n\n"
        read -rp "Select an option [1-2]: " choice
        case "$choice" in
            1)
                printf "\nEnable uhubctl USB port power-cycling? (Default: No) [y/N]: "
                read -rp "" uhub_ans
                local uhub_flag=0
                if [[ "$uhub_ans" =~ ^[yY]$ ]]; then
                    uhub_flag=1
                fi
                install_dependencies "$uhub_flag"
                write_daemon_script "$uhub_flag"
                install_systemd_service
                ;;
            2)
                exit 0
                ;;
            *)
                log_err "Invalid selection!"
                exit 1
                ;;
        esac
    fi
}

main() {
    require_root
    local with_uhub=0
    for arg in "$@"; do
        [ "$arg" = "--with-uhubctl" ] && with_uhub=1
    done

    if [ "${1:-}" = "--install" ]; then
        install_dependencies "$with_uhub"
        write_daemon_script "$with_uhub"
        install_systemd_service
    elif [ "${1:-}" = "--remove" ]; then
        remove_systemd_service
    elif [ "${1:-}" = "--status" ]; then
        status_service
    else
        menu
    fi
}

main "$@"
