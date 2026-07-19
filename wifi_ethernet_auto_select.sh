#!/usr/bin/env bash
# wifi_ethernet_auto_select.sh
#
# This script gives a working wired connection priority over Wi-Fi on Debian.
# On every run it makes sure the current user's crontab has an @reboot entry
# that starts this script after 30 seconds.  It then looks for physical
# Ethernet interfaces that have carrier, and sends a ping through each one.
# If one can reach the internet, every Wi-Fi interface is brought down and the
# script exits.  If Ethernet fails, it waits 30 seconds and tries once more.
# If Ethernet still fails, it brings Wi-Fi back up and asks wpa_supplicant to
# reassociate using its existing saved network configuration.
#
# It does not use NetworkManager or nmcli.  It needs Bash, iproute2 (ip),
# iputils-ping (ping), crontab, and wpa_cli from wpa_supplicant for automatic
# Wi-Fi reconnection.  The configured wpa_supplicant instance must expose its
# normal control socket so that wpa_cli can access the saved SSID.

set -u

SCRIPT_PATH="$(readlink -f "$0")"
printf -v SCRIPT_PATH_ESCAPED '%q' "$SCRIPT_PATH"
CRON_TAG="# wifi_ethernet_auto_select"
CRON_LINE="@reboot sleep 30 && /bin/bash $SCRIPT_PATH_ESCAPED $CRON_TAG"
PING_TARGET="${PING_TARGET:-1.1.1.1}"

log() {
    printf '%s: %s\n' "${0##*/}" "$*" >&2
}

ensure_boot_cron() {
    command -v crontab >/dev/null 2>&1 || {
        log "crontab is not installed; cannot register the boot job"
        return 1
    }

    local current_crontab
    current_crontab="$(crontab -l 2>/dev/null || true)"
    if ! grep -Fqx "$CRON_LINE" <<<"$current_crontab"; then
        # The tag makes this idempotent and removes only this script's old job.
        {
            grep -Fv "$CRON_TAG" <<<"$current_crontab" || true
            printf '%s\n' "$CRON_LINE"
        } | crontab -
        log "registered a delayed boot job in this user's crontab"
    fi
}

wifi_devices() {
    local device
    for device in /sys/class/net/*; do
        device="${device##*/}"
        [[ -d "/sys/class/net/$device/wireless" ]] && printf '%s\n' "$device"
    done
}

ethernet_devices_with_carrier() {
    local device
    for device in /sys/class/net/*; do
        device="${device##*/}"
        # A physical, non-wireless ARPHRD_ETHER interface is treated as wired.
        [[ -e "/sys/class/net/$device/device" ]] || continue
        [[ ! -d "/sys/class/net/$device/wireless" ]] || continue
        [[ "$(<"/sys/class/net/$device/type")" == "1" ]] || continue
        [[ "$(<"/sys/class/net/$device/carrier")" == "1" ]] || continue
        printf '%s\n' "$device"
    done
}

internet_works_on() {
    local device="$1"
    # -I binds the probe to this interface, so a working Wi-Fi route cannot
    # make an Ethernet check appear successful.
    ping -I "$device" -c 1 -W 5 "$PING_TARGET" >/dev/null 2>&1
}

ethernet_has_internet() {
    local device
    while IFS= read -r device; do
        if internet_works_on "$device"; then
            log "internet is available over Ethernet device $device"
            return 0
        fi
    done < <(ethernet_devices_with_carrier)
    return 1
}

disconnect_wifi() {
    local device
    while IFS= read -r device; do
        ip link set dev "$device" down || log "could not bring Wi-Fi device $device down"
    done < <(wifi_devices)
}

connect_saved_wifi() {
    local device connected=1

    command -v wpa_cli >/dev/null 2>&1 || {
        log "wpa_cli is required to reconnect a saved Wi-Fi network"
        return 1
    }

    while IFS= read -r device; do
        ip link set dev "$device" up || {
            log "could not bring Wi-Fi device $device up"
            continue
        }
        # reconfigure reloads the existing wpa_supplicant configuration;
        # reassociate then selects a saved network that is currently visible.
        wpa_cli -i "$device" reconfigure >/dev/null 2>&1 || true
        if wpa_cli -i "$device" reassociate >/dev/null 2>&1; then
            log "asked wpa_supplicant to reconnect Wi-Fi device $device"
            connected=0
        else
            log "could not contact wpa_supplicant for Wi-Fi device $device"
        fi
    done < <(wifi_devices)
    return "$connected"
}

main() {
    command -v ip >/dev/null 2>&1 || {
        log "iproute2 (ip) is required"
        exit 1
    }
    command -v ping >/dev/null 2>&1 || {
        log "iputils-ping (ping) is required to test Ethernet connectivity"
        exit 1
    }

    ensure_boot_cron || true

    if ethernet_has_internet; then
        disconnect_wifi
        exit 0
    fi

    log "Ethernet has no internet connection; waiting 30 seconds before retrying"
    sleep 30

    if ethernet_has_internet; then
        disconnect_wifi
        exit 0
    fi

    log "Ethernet still has no internet connection; enabling saved Wi-Fi"
    connect_saved_wifi
}

main "$@"
