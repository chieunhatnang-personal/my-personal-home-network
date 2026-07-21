#!/bin/sh
set -eu

# Prepare a Debian or Rocky Linux machine to boot Grml Rescue from local disk
# via GRUB.
# The script detects host-specific network values at runtime. Its fallback
# rescue password is intentionally non-secret and should be changed after use.
# Run as root on the machine you want to prepare:
#   sh grml-rescue-setup.sh

GRML_DIR="/boot/grml"
GRML_DEFAULTS="/etc/default/grml-rescueboot"
GRML_DOWNLOAD_URL="https://download.grml.org"
GRML_SIGNING_KEY_URL="https://grml.org/download/gnupg-michael-prokop.txt"
GRML_SIGNING_FINGERPRINT="33CCB136401AFEC843A3876396A87872B7EA3737"
GRML_GENERATOR_URL="https://raw.githubusercontent.com/grml/grml-rescueboot/v0.6.9/42_grml"
GRML_GENERATOR_SHA256="38f83bf9e4200c157c5041f38ac51d9094ccbbe5fcdf542ec75b12812ce0748c"
OS_FAMILY=""
GRUB_CFG=""
GRUB_MKCONFIG=""
GRUB_REBOOT=""
NETWORK_BOOT_OPTIONS=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

need_root() {
  [ "$(id -u)" = "0" ] || die "Run this script as root."
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

clean_answer() {
  bs="$(printf '\010')"
  del="$(printf '\177')"
  cr="$(printf '\015')"
  printf "%s" "$1" | sed \
    -e "s/$cr//g" \
    -e ":again" \
    -e "s/.[${bs}${del}]//g" \
    -e "t again" \
    -e "s/[${bs}${del}]//g" \
    -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]]*$//'
}

ask() {
  prompt="$1"
  default="$2"
  if [ -n "$default" ]; then
    printf '\n[Q] %s\n[Answer] [%s]: ' "$prompt" "$default" >&2
  else
    printf '\n[Q] %s\n[Answer]: ' "$prompt" >&2
  fi
  read -r ans || ans=""
  ans="$(clean_answer "$ans")"
  [ -n "$ans" ] || ans="$default"
  printf "%s" "$ans"
}

ask_secret() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf '\n[Q] %s\n[Answer hidden; leave empty to use the default]: ' "$prompt" >&2
  else
    printf '\n[Q] %s\n[Answer hidden; leave empty to skip]: ' "$prompt" >&2
  fi
  if [ -t 0 ]; then
    stty_orig="$(stty -g 2>/dev/null || true)"
    stty -echo 2>/dev/null || true
    read -r ans || ans=""
    [ -z "$stty_orig" ] || stty "$stty_orig" 2>/dev/null || true
    printf '\n' >&2
  else
    read -r ans || ans=""
  fi
  ans="$(clean_answer "$ans")"
  [ -n "$ans" ] || ans="$default"
  printf '%s' "$ans"
}

ask_yn() {
  prompt="$1"
  default="$2"
  case "$default" in
    y|Y|yes|YES|Yes) suffix="Y/n"; default="y" ;;
    n|N|no|NO|No) suffix="y/N"; default="n" ;;
    *) suffix="y/N"; default="n" ;;
  esac

  while :; do
    printf '\n[Q] %s\n[Answer] (%s): ' "$prompt" "$suffix" >&2
    read -r ans || ans=""
    ans="$(clean_answer "$ans")"
    [ -n "$ans" ] || ans="$default"
    case "$ans" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

major_version() {
  printf '%s' "$1" | sed 's/[^0-9].*$//'
}

check_os() {
  [ -r /etc/os-release ] || die "/etc/os-release not found; cannot verify OS."
  # shellcheck disable=SC1091
  . /etc/os-release
  id="${ID:-}"
  version_id="${VERSION_ID:-0}"
  major="$(major_version "$version_id")"

  case "$id" in
    debian)
      [ "${major:-0}" -ge 11 ] || die "Debian version must be >= 11. Detected VERSION_ID='$version_id'."
      OS_FAMILY="debian"
      GRUB_CFG="/boot/grub/grub.cfg"
      GRUB_MKCONFIG="update-grub"
      GRUB_REBOOT="grub-reboot"
      ;;
    rocky)
      [ "${major:-0}" = 9 ] || die "Only Rocky Linux 9 is supported. Detected VERSION_ID='$version_id'."
      OS_FAMILY="rocky"
      GRUB_CFG="/boot/grub2/grub.cfg"
      GRUB_MKCONFIG="grub2-mkconfig"
      GRUB_REBOOT="grub2-reboot"
      ;;
    *)
      die "This script supports Debian >= 11 and Rocky Linux 9. Detected ID='$id'."
      ;;
  esac
  info "OS check passed: ${PRETTY_NAME:-$id $version_id}"
}

check_bootloader() {
  cmd_exists "$GRUB_MKCONFIG" || die "$GRUB_MKCONFIG is missing. Install/configure GRUB first."
  cmd_exists "$GRUB_REBOOT" || warn "$GRUB_REBOOT is missing; setup can continue, but one-time boot staging may not work."
  [ -d "$(dirname "$GRUB_CFG")" ] || die "$(dirname "$GRUB_CFG") not found. This script expects GRUB 2."
}

install_packages() {
  case "$OS_FAMILY" in
    debian)
      info "Installing grml-rescueboot and verification tools with apt."
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y grml-rescueboot debian-keyring gpgv wget iproute2
      ;;
    rocky)
      info "Installing GRUB and verification tools with dnf."
      dnf install -y grub2-tools curl gnupg2 coreutils util-linux iproute
      ;;
  esac
}

validate_directory() {
  value="$1"
  case "$value" in
    /) die "The ISO directory cannot be the filesystem root." ;;
    /*) ;;
    *) die "The ISO directory must be an absolute path." ;;
  esac
  case "$value" in
    *[!A-Za-z0-9._/@%+=,-]*)
      die "The ISO directory contains unsupported characters. Avoid spaces and shell metacharacters."
      ;;
  esac
}

select_rocky_grml_dir() {
  boot_free_kb="$(df -Pk /boot | awk 'NR == 2 { print $4 }')"
  default_dir="/boot/grml"
  if [ -n "$boot_free_kb" ] && [ "$boot_free_kb" -lt 716800 ]; then
    default_dir="/grml"
    warn "/boot has less than 700 MiB free; the current grml-small ISO will not fit there."
  fi

  GRML_DIR="$(ask "Directory in which to store the Grml ISO" "$default_dir")"
  validate_directory "$GRML_DIR"
}

install_rocky_grub_generator() {
  generator="/etc/grub.d/42_grml"
  generator_tmp="$(mktemp)"
  timestamp="$(date +%Y%m%d%H%M%S)"

  info "Installing the Grml GRUB generator from pinned upstream release v0.6.9."
  if ! curl -fL --retry 3 -o "$generator_tmp" "$GRML_GENERATOR_URL"; then
    rm -f "$generator_tmp"
    die "Failed to download the Grml GRUB generator."
  fi
  printf '%s  %s\n' "$GRML_GENERATOR_SHA256" "$generator_tmp" | sha256sum -c - >/dev/null \
    || die "The downloaded Grml GRUB generator failed checksum verification."

  if [ -e "$generator" ]; then
    cp -a "$generator" "$generator.bak.$timestamp"
    info "Backed up $generator to $generator.bak.$timestamp"
  fi
  install -m 0755 "$generator_tmp" "$generator"
  rm -f "$generator_tmp"
}

grml_architecture() {
  case "$(uname -m)" in
    x86_64) printf 'amd64' ;;
    aarch64) printf 'arm64' ;;
    *) die "Unsupported architecture '$(uname -m)'. Grml supports x86_64 and aarch64." ;;
  esac
}

check_download_space() {
  directory="$1"
  iso_url="$2"
  required_kb=716800
  content_length="$(curl -fsIL "$iso_url" 2>/dev/null \
    | awk 'BEGIN { IGNORECASE=1 } /^content-length:/ { gsub("\\r", "", $2); if ($2 ~ /^[0-9]+$/) size=$2 } END { print size }')"
  if [ -n "$content_length" ]; then
    required_kb=$((content_length / 1024 + 65536))
  fi
  available_kb="$(df -Pk "$directory" | awk 'NR == 2 { print $4 }')"
  [ -n "$available_kb" ] || die "Could not determine free space for $directory."
  [ "$available_kb" -ge "$required_kb" ] \
    || die "Not enough free space in $directory. Need about $((required_kb / 1024)) MiB; only $((available_kb / 1024)) MiB is available."
}

download_grml_small_rocky() {
  info "Finding the latest grml-small release."
  arch="$(grml_architecture)"
  release="$(curl -fsSL "$GRML_DOWNLOAD_URL/" \
    | sed -n "s/.*grml-small-\\([0-9][0-9][0-9][0-9]\\.[0-9][0-9]\\)-$arch\\.iso.*/\\1/p" \
    | sort | tail -n 1)"
  [ -n "$release" ] || die "Could not determine the latest grml-small release."

  iso_name="grml-small-$release-$arch.iso"
  iso_url="$GRML_DOWNLOAD_URL/$iso_name"
  iso_file="$GRML_DIR/$iso_name"
  iso_tmp="$iso_file.tmp"
  verify_dir="$(mktemp -d)"
  gnupg_home="$verify_dir/gnupg"
  trap 'rm -rf "$verify_dir"' 0
  trap 'rm -rf "$verify_dir"; exit 1' HUP INT TERM
  mkdir -p "$GRML_DIR" "$gnupg_home"
  chmod 700 "$gnupg_home"
  grub2-probe -t fs "$GRML_DIR" >/dev/null 2>&1 \
    || die "GRUB cannot read the filesystem containing $GRML_DIR. Choose another ISO directory."

  if [ -f "$iso_file" ]; then
    info "Found $iso_file; verifying the existing ISO."
    verify_file="$iso_file"
  else
    check_download_space "$GRML_DIR" "$iso_url"
    info "Downloading $iso_name to $GRML_DIR."
    curl -fL --retry 3 -o "$iso_tmp" "$iso_url" \
      || die "Failed to download $iso_url (partial file left at $iso_tmp)."
    verify_file="$iso_tmp"
  fi

  info "Verifying the ISO signature and Grml signing-key fingerprint."
  curl -fsSL -o "$verify_dir/signing-key.asc" "$GRML_SIGNING_KEY_URL" \
    || die "Failed to download the Grml signing key."
  curl -fsSL -o "$verify_dir/iso.asc" "$iso_url.asc" \
    || die "Failed to download the ISO signature."
  gpg --homedir "$gnupg_home" --batch --quiet --import-options import-minimal \
    --import "$verify_dir/signing-key.asc" >/dev/null 2>&1 \
    || die "Failed to import the Grml signing key."
  fingerprint="$(gpg --homedir "$gnupg_home" --batch --with-colons \
    --fingerprint "$GRML_SIGNING_FINGERPRINT" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
  [ "$fingerprint" = "$GRML_SIGNING_FINGERPRINT" ] \
    || die "The downloaded signing key has an unexpected fingerprint."
  gpg --homedir "$gnupg_home" --batch --verify "$verify_dir/iso.asc" "$verify_file" \
    || die "The Grml ISO signature is invalid (download left at $verify_file)."

  if [ "$verify_file" = "$iso_tmp" ]; then
    mv "$iso_tmp" "$iso_file"
  fi
  rm -rf "$verify_dir"
  trap - 0 HUP INT TERM
  info "Verified $iso_file."
}

download_grml_small() {
  case "$OS_FAMILY" in
    debian)
      info "Downloading and verifying the latest grml-small ISO."
      update-grml-rescueboot -t small
      ;;
    rocky)
      download_grml_small_rocky
      ;;
  esac
}

validate_token() {
  name="$1"
  value="$2"
  case "$value" in
    *[!A-Za-z0-9._:@%+=,/-]*)
      die "$name contains unsupported characters. Avoid spaces, quotes, shell metacharacters, and backslashes."
      ;;
  esac
}

validate_hostname() {
  value="$1"
  [ -n "$value" ] || die "Hostname cannot be empty."
  [ "${#value}" -le 63 ] || die "Hostname must be 63 characters or less."
  case "$value" in
    *[!A-Za-z0-9.-]*)
      die "Hostname may contain only letters, numbers, dots, and hyphens."
      ;;
    -*|*-|.*|*.)
      die "Hostname must not start or end with a dot or hyphen."
      ;;
  esac
}

prefix_to_netmask() {
  prefix="$1"
  case "$prefix" in
    ''|*[!0-9]*) die "Invalid IPv4 prefix length '$prefix'." ;;
  esac
  [ "$prefix" -le 32 ] || die "Invalid IPv4 prefix length '$prefix'."

  awk -v bits="$prefix" 'BEGIN {
    for (i = 1; i <= 4; i++) {
      if (bits >= 8) {
        octet = 255
        bits -= 8
      } else if (bits > 0) {
        octet = 256 - (2 ^ (8 - bits))
        bits = 0
      } else {
        octet = 0
      }
      printf "%s%d", (i == 1 ? "" : "."), octet
    }
  }'
}

ipv4_dns_csv() {
  awk '
    function is_ipv4(value, parts, count, i) {
      count = split(value, parts, ".")
      if (count != 4) return 0
      for (i = 1; i <= 4; i++) {
        if (parts[i] !~ /^[0-9]+$/ || parts[i] < 0 || parts[i] > 255) return 0
      }
      return value !~ /^127\./
    }
    is_ipv4($1) && count < 2 {
      result = result (count ? "," : "") $1
      count++
    }
    END { print result }
  '
}

configure_network_options() {
  grml_host="$1"
  cmd_exists ip || die "The ip command is required to detect the current network configuration."

  default_route="$(ip -4 route show default | head -n 1)"
  [ -n "$default_route" ] || die "No IPv4 default route was found; cannot configure remote Grml access safely."
  interface="$(printf '%s\n' "$default_route" \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  gateway="$(printf '%s\n' "$default_route" \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')"
  [ -n "$interface" ] || die "Could not determine the interface used by the IPv4 default route."

  route_source="$(printf '%s\n' "$default_route" \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  if [ -z "$route_source" ]; then
    route_source="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  fi
  address_cidr="$(ip -o -4 addr show dev "$interface" scope global \
    | awk -v source="$route_source" '
        source != "" && index($4, source "/") == 1 { print $4; found=1; exit }
        NR == 1 { fallback=$4 }
        END { if (!found) print fallback }
      ')"
  [ -n "$address_cidr" ] || die "No global IPv4 address was found on $interface."
  address="${address_cidr%/*}"
  prefix="${address_cidr#*/}"
  netmask="$(prefix_to_netmask "$prefix")"

  validate_token "Network interface" "$interface"
  validate_token "IPv4 address" "$address"
  validate_token "IPv4 gateway" "$gateway"
  validate_token "IPv4 netmask" "$netmask"

  dns_lines=""
  if cmd_exists nmcli; then
    dns_lines="$(nmcli -g IP4.DNS device show "$interface" 2>/dev/null || true)"
  fi
  if [ -z "$dns_lines" ] && [ -r /etc/resolv.conf ]; then
    dns_lines="$(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf)"
  fi
  dns_servers="$(printf '%s\n' "$dns_lines" | ipv4_dns_csv)"

  # ip= uses the standard kernel format documented by Grml:
  # client-ip:server-ip:gateway:netmask:hostname:device:autoconf
  NETWORK_BOOT_OPTIONS="ip=$address::$gateway:$netmask:$grml_host:$interface:off ethdevice=$interface"
  if [ -n "$dns_servers" ]; then
    NETWORK_BOOT_OPTIONS="$NETWORK_BOOT_OPTIONS dns=$dns_servers"
  else
    warn "No non-loopback IPv4 DNS server was found; Grml will still be reachable by IP address."
  fi

  info "Detected network for Grml: interface=$interface address=$address/$prefix gateway=${gateway:-none} DNS=${dns_servers:-none}"
}

write_grml_defaults() {
  boot_options="$1"

  timestamp="$(date +%Y%m%d%H%M%S)"
  if [ -e "$GRML_DEFAULTS" ]; then
    cp -a "$GRML_DEFAULTS" "$GRML_DEFAULTS.bak.$timestamp"
    info "Backed up $GRML_DEFAULTS to $GRML_DEFAULTS.bak.$timestamp"
  fi

  cat >"$GRML_DEFAULTS" <<EOF
## Configuration file for grml-rescueboot.
## Managed by grml-rescue-setup.sh.

# Location of ISOs:
ISO_LOCATION="$GRML_DIR/"

# Boot options passed to Grml ISO entries generated by update-grub.
CUSTOM_BOOTOPTIONS='$boot_options'
EOF
}

configure_grml_options() {
  current_host="$(hostname 2>/dev/null || printf 'linux')"
  default_grml_host="${current_host}-grml"

  grml_host="$(ask "Hostname to use while booted into Grml" "$default_grml_host")"
  validate_hostname "$grml_host"
  configure_network_options "$grml_host"

  use_toram="n"
  if ask_yn "Copy Grml into RAM with toram? Recommended for disk imaging/rescue work." "y"; then
    use_toram="y"
  fi

  warn "The Grml SSH password will be stored in $GRML_DEFAULTS and $GRUB_CFG."
  warn "Use a temporary rescue password, and remove or rotate it after you are done."
  ssh_password="$(ask_secret "Temporary Grml SSH password" "Abcd1111@")"
  if [ -n "$ssh_password" ]; then
    validate_token "SSH password" "$ssh_password"
    boot_options="ssh=$ssh_password hostname=$grml_host $NETWORK_BOOT_OPTIONS"
  else
    boot_options="ssh hostname=$grml_host $NETWORK_BOOT_OPTIONS"
  fi

  if [ "$use_toram" = "y" ]; then
    boot_options="$boot_options toram"
  fi

  write_grml_defaults "$boot_options"
  info "Configured Grml SSH, hostname, and static network boot options."
}

update_grub_config() {
  info "Regenerating GRUB configuration."
  case "$OS_FAMILY" in
    debian) "$GRUB_MKCONFIG" ;;
    rocky) "$GRUB_MKCONFIG" -o "$GRUB_CFG" ;;
  esac
}

grml_entry_name() {
  sed -n \
    -e '/^menuentry "Grml Rescue System/ s/^menuentry "\([^"]*\)".*/\1/p' \
    -e '/^menuentry "grml-\(full\|small\)-.*\.iso"/ s/^menuentry "\([^"]*\)".*/\1/p' \
    "$GRUB_CFG" \
    | head -n 1
}

show_status() {
  entry="$(grml_entry_name || true)"

  printf '\n'
  info "Setup complete."
  printf 'Grml ISO files:\n'
  ls -lh "$GRML_DIR"/*.iso 2>/dev/null || true

  if [ -n "$entry" ]; then
    printf '\nGRUB entry:\n  %s\n' "$entry"
    printf '\nTo boot Grml one time later, run:\n'
    printf "  %s '%s'\n" "$GRUB_REBOOT" "$entry"
    printf '  reboot\n'
  else
    warn "No Grml GRUB entry was found. Check the GRUB configuration output above."
  fi
}

maybe_stage_one_time_boot() {
  entry="$(grml_entry_name || true)"
  [ -n "$entry" ] || return 0
  cmd_exists "$GRUB_REBOOT" || return 0

  if ask_yn "Stage the Grml entry for the next boot only? This does not reboot now." "y"; then
    "$GRUB_REBOOT" "$entry"
    info "Next boot is staged for: $entry"
    if ask_yn "Reboot now into Grml?" "y"; then
      info "Rebooting into Grml now."
      reboot
    else
      info "Run 'reboot' when ready."
    fi
  fi
}

main() {
  need_root
  check_os
  install_packages
  check_bootloader
  if [ "$OS_FAMILY" = "rocky" ]; then
    select_rocky_grml_dir
    install_rocky_grub_generator
  fi
  download_grml_small
  configure_grml_options
  update_grub_config
  show_status
  maybe_stage_one_time_boot
}

main "$@"
