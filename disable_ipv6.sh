#!/usr/bin/env bash
# disable_ipv6.sh
#
# Permanently disable IPv6 on common Linux distributions.  The script writes
# the kernel settings used at boot, then applies them immediately.  It supports
# systemd/procps distributions (Debian, Ubuntu, Fedora, RHEL, Arch, SUSE, etc.)
# and Alpine/OpenRC.  Re-run it safely: the script replaces only its own
# managed block and backs up any file it changes.
#
# Usage: sudo ./disable_ipv6.sh

set -euo pipefail

readonly CONFIG_CONTENT='# BEGIN disable_ipv6.sh\n# Disable IPv6 for all current and future network interfaces.\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n# END disable_ipv6.sh\n'

log() {
    printf '%s: %s\n' "${0##*/}" "$*" >&2
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log 'run this script as root (for example: sudo ./disable_ipv6.sh)'
        exit 1
    fi
}

configuration_path() {
    # Alpine's OpenRC sysctl service reads /etc/sysctl.conf.  Most other
    # distributions load /etc/sysctl.d/*.conf during boot.
    if [[ -r /etc/os-release ]] && grep -qx 'ID=alpine' /etc/os-release; then
        printf '%s\n' '/etc/sysctl.conf'
    else
        printf '%s\n' '/etc/sysctl.d/99-disable-ipv6.conf'
    fi
}

write_configuration() {
    local path="$1"
    local directory backup temporary suffix=0
    directory="$(dirname "$path")"
    mkdir -p "$directory"

    if [[ -e "$path" ]]; then
        backup="${path}.bak.$(date +%Y%m%d%H%M%S)"
        while [[ -e "$backup" ]]; do
            suffix=$((suffix + 1))
            backup="${path}.bak.$(date +%Y%m%d%H%M%S).${suffix}"
        done
        cp -p -- "$path" "$backup"
        log "backed up existing configuration to $backup"
    fi

    temporary="$(mktemp "${directory}/.disable-ipv6.XXXXXX")"
    if [[ "$path" == '/etc/sysctl.conf' && -e "$path" ]]; then
        # Preserve Alpine's shared configuration file while replacing the
        # block managed by this script from an earlier run.
        awk '
            /^# BEGIN disable_ipv6\.sh$/ { skipping = 1; next }
            /^# END disable_ipv6\.sh$/ { skipping = 0; next }
            !skipping { print }
        ' "$path" >"$temporary"
        printf '\n%b' "$CONFIG_CONTENT" >>"$temporary"
    else
        printf '%b' "$CONFIG_CONTENT" >"$temporary"
    fi
    mv -f -- "$temporary" "$path"
    chmod 0644 "$path"
    log "wrote persistent configuration to $path"
}

apply_now() {
    local key
    for key in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6; do
        if ! sysctl -w "$key=1" >/dev/null; then
            log "could not apply $key; it will be retried at the next boot"
        fi
    done
}

verify() {
    local all default
    all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || true)"
    default="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || true)"
    if [[ "$all" == '1' && "$default" == '1' ]]; then
        log 'IPv6 is disabled now and will remain disabled after reboot'
    else
        log 'persistent settings were written, but IPv6 could not be fully disabled now'
        exit 1
    fi
}

main() {
    require_root
    command -v sysctl >/dev/null 2>&1 || {
        log 'sysctl is required but was not found'
        exit 1
    }

    local path
    path="$(configuration_path)"
    write_configuration "$path"
    apply_now
    verify
}

main "$@"
