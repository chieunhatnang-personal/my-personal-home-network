#!/usr/bin/env bash
# Interactive setup for a small Debian photo-sync primary or backup server.
# Intended for a local terminal, run as root.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME=${0##*/}
FSTAB=/etc/fstab
SMB_CONF=/etc/samba/smb.conf
SMB_MANAGED_CONF=/etc/samba/photosync-setup.conf
HOME_PHOTOS_DIR=/etc/homephotos
RESTIC_CONTROLLER_DIR=$HOME_PHOTOS_DIR/restic
RESTIC_SERVERS_DIR=$RESTIC_CONTROLLER_DIR/servers
RESTIC_STORAGES_DIR=$RESTIC_CONTROLLER_DIR/storages
RESTIC_REPOSITORIES_DIR=$RESTIC_CONTROLLER_DIR/repositories
RESTIC_JOBS_DIR=$RESTIC_CONTROLLER_DIR/jobs
RESTIC_LOCKS_DIR=$RESTIC_CONTROLLER_DIR/locks
RESTIC_ARCHIVE_DIR=$HOME_PHOTOS_DIR/archives/restic
RESTIC_CONTROLLER_KEY=$HOME_PHOTOS_DIR/keys/restic-ed25519
RESTIC_INSTALL_PATH=/usr/local/sbin/photosync-setup

MOUNT_OPTIONS='defaults,nofail,x-systemd.device-timeout=10s,x-systemd.mount-timeout=30s'

# Sensible home-photo defaults. The primary server creates snapshots nightly;
# maintenance retains recovery points without keeping every daily snapshot forever.
RESTIC_BACKUP_TIME='02:30'
RESTIC_MAINTENANCE_TIME='03:30'
RESTIC_KEEP_DAILY=30
RESTIC_KEEP_WEEKLY=8
RESTIC_KEEP_MONTHLY=12
RESTIC_KEEP_YEARLY=3

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '\n==> %s\n' "$*"
}

require_root() {
  [ "${EUID}" -eq 0 ] || die "Run this script as root: sudo ./${SCRIPT_NAME}"
}

require_tty() {
  [ -t 0 ] && [ -t 1 ] || die "This interactive script needs a terminal."
}

backup_file() {
  local path=$1
  [ -e "$path" ] || return 0
  cp -a -- "$path" "${path}.bak.$(date +%Y%m%d%H%M%S)"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  local packages=("$@") missing=() package
  for package in "${packages[@]}"; do
    dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed || missing+=("$package")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0

  command_exists apt-get || die "Missing packages: ${missing[*]}. Install them with your distribution package manager."
  note "Installing required packages: ${missing[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# Menu result is returned in MENU_INDEX. Arrow keys move the selection; Enter accepts it.
choose_menu() {
  local title=$1
  shift
  local options=("$@") selected=0 key sequence i marker
  local cyan='' green='' reset=''
  if [[ -z ${NO_COLOR:-} ]]; then cyan=$'\033[1;36m'; green=$'\033[1;32m'; reset=$'\033[0m'; fi
  [ "${#options[@]}" -gt 0 ] || die "Internal error: menu has no choices."

  while :; do
    printf '\033[2J\033[H'
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  %s\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "$cyan" "$title" "$reset"
    printf 'Use Up/Down arrows, then Enter.\n\n'
    for i in "${!options[@]}"; do
      marker=' '
      [ "$i" -eq "$selected" ] && marker='>'
      if [[ $i == "$selected" ]]; then printf '%s %s %s%s\n' "$green" "$marker" "${options[$i]}" "$reset"; else printf '   %s\n' "${options[$i]}"; fi
    done

    IFS= read -rsn1 key
    case "$key" in
      '') MENU_INDEX=$selected; return 0 ;;
      $'\x1b')
        IFS= read -rsn2 -t 1 sequence || true
        case "$sequence" in
          '[A') selected=$(( (selected - 1 + ${#options[@]}) % ${#options[@]} )) ;;
          '[B') selected=$(( (selected + 1) % ${#options[@]} )) ;;
        esac
        ;;
      k|K) selected=$(( (selected - 1 + ${#options[@]}) % ${#options[@]} )) ;;
      j|J) selected=$(( (selected + 1) % ${#options[@]} )) ;;
    esac
  done
}

confirm() {
  choose_menu "$1" 'Yes' 'No'
  [ "$MENU_INDEX" -eq 0 ]
}

press_enter_to_continue() {
  local ignored
  printf '\nPress Enter to go back...'
  IFS= read -r ignored
}

ask() {
  local prompt=$1 default=${2-} answer
  while :; do
    if [ -n "$default" ]; then
      printf '%s [%s]: ' "$prompt" "$default"
    else
      printf '%s: ' "$prompt"
    fi
    IFS= read -r answer
    answer=${answer:-$default}
    [ -n "$answer" ] && { REPLY=$answer; return 0; }
    printf 'A value is required.\n' >&2
  done
}

ask_secret() {
  local prompt=$1 answer
  while :; do
    printf '%s: ' "$prompt"
    IFS= read -rs answer
    printf '\n'
    [ -n "$answer" ] && { REPLY=$answer; return 0; }
    printf 'A value is required.\n' >&2
  done
}

valid_name() {
  [[ $1 =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
}

ask_name() {
  local prompt=$1 default=$2
  while :; do
    ask "$prompt (lowercase letters, numbers, _ or -)" "$default"
    if valid_name "$REPLY"; then
      return 0
    fi
    printf 'Use 1-32 lowercase characters; the first must be a letter.\n' >&2
  done
}

root_disk() {
  local source parent
  source=$(findmnt -nr -o SOURCE / 2>/dev/null || true)
  case "$source" in
    /dev/*)
      parent=$(lsblk -nro PKNAME "$source" 2>/dev/null | head -n1 || true)
      if [ -n "$parent" ]; then
        printf '/dev/%s\n' "$parent"
      else
        printf '%s\n' "$source"
      fi
      ;;
  esac
}

drive_label() {
  local disk=$1 details
  details=$(lsblk -dnro SIZE,MODEL "$disk" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  printf '%s - %s' "$disk" "${details:-unknown size}"
}

mounted_path_for_disk() {
  local disk=$1
  # A disk may contain several partitions. Return the first non-root mount,
  # which is the strongest signal that it is the intended storage disk.
  lsblk -nrpo NAME,PKNAME,MOUNTPOINT | awk -v disk="$disk" \
    '$1 == disk || $2 == disk { if ($3 != "" && $3 != "/") { print $3; exit } }'
}

select_storage_disk() {
  local root root_name candidate candidate_name type mounted_path
  local preferred_disks=() preferred_labels=() other_disks=() other_labels=()
  local disks=() labels=()
  root=$(root_disk)
  root_name=${root##*/}

  # IFS is intentionally strict globally for safer shell scripting; override
  # it here because lsblk's two columns are separated by spaces.
  while IFS=' ' read -r candidate type; do
    [ "$type" = disk ] || continue
    [ "$candidate" = "$root" ] && continue
    candidate_name=${candidate##*/}
    # eMMC exposes boot areas as separate block devices (for example
    # mmcblk0boot0). They are part of the system device, not data disks.
    [[ $candidate_name = "$root_name"* ]] && continue
    mounted_path=$(mounted_path_for_disk "$candidate")
    if [ -n "$mounted_path" ]; then
      preferred_disks+=("$candidate")
      preferred_labels+=("$(drive_label "$candidate") (mounted at $mounted_path; recommended)")
    else
      other_disks+=("$candidate")
      other_labels+=("$(drive_label "$candidate")")
    fi
  done < <(lsblk -dnpo NAME,TYPE)

  disks=("${preferred_disks[@]}" "${other_disks[@]}")
  labels=("${preferred_labels[@]}" "${other_labels[@]}")

  [ "${#disks[@]}" -gt 0 ] || die "No non-system storage disks were detected. Attach a disk and run again."
  if [ "${#preferred_disks[@]}" -eq 0 ] && [ "${#disks[@]}" -eq 1 ]; then
    labels[0]="${labels[0]} (auto-detected)"
  fi
  choose_menu 'Choose the storage drive. The system/root drive is excluded.' "${labels[@]}" 'Cancel'
  [ "$MENU_INDEX" -lt "${#disks[@]}" ] || exit 0
  SELECTED_DISK=${disks[$MENU_INDEX]}
}

filesystem_label() {
  local device=$1 type label size
  type=$(blkid -s TYPE -o value "$device" 2>/dev/null || true)
  label=$(blkid -s LABEL -o value "$device" 2>/dev/null || true)
  size=$(lsblk -dnro SIZE "$device")
  printf '%s - %s%s (%s)' "$device" "${type:-unknown}" "${label:+, label: $label}" "$size"
}

discover_filesystems() {
  local disk=$1 device type
  local devices=()
  mapfile -t devices < <(lsblk -nrpo NAME,PKNAME,TYPE | awk -v disk="$disk" \
    '$1 == disk || ($2 == disk && $3 == "part") { print $1 }')
  for device in "${devices[@]}"; do
    type=$(blkid -s TYPE -o value "$device" 2>/dev/null || true)
    if [ -n "$type" ]; then
      printf '%s\n' "$device"
    fi
  done
}

confirm_format() {
  local disk=$1
  printf '\nFormatting %s permanently destroys every partition and file on that disk.\n' "$disk"
  printf 'Type exactly %s to continue: ' "$disk"
  local answer
  IFS= read -r answer
  [ "$answer" = "$disk" ] || die "Format cancelled."
}

hp_format_guard() {
  local disk=$1 root ancestors item mounts types
  root=$(findmnt -rn -o SOURCE /) || die 'Cannot identify system filesystem; formatting refused.'
  [[ $root == /dev/* ]] || die 'Unsupported root layout; format manually after review.'
  ancestors=$(lsblk -s -nrpo NAME "$root") || die 'Cannot identify all root backing devices.'
  [[ -n $ancestors ]] || die 'Unknown root ancestry.'
  while IFS= read -r item; do
    [[ $item != "$disk" ]] || die 'Refusing to format a system backing device.'
  done <<< "$ancestors"
  types=$(lsblk -dnro TYPE "$disk") || die 'Cannot inspect formatting target.'
  [[ $types == disk ]] || die 'Formatting requires a whole, standalone disk.'
  types=$(lsblk -nr -o TYPE "$disk") || die 'Cannot inspect disk children.'
  while IFS= read -r item; do
    case $item in disk|part) ;; *) die 'Disk has layered holders; formatting refused.';; esac
  done <<< "$types"
  mounts=$(lsblk -nr -o MOUNTPOINT "$disk") || die 'Cannot inspect mount use.'
  [[ -z ${mounts//[[:space:]]/} ]] || die 'Disk or partition is mounted/in use; formatting refused.'
}

format_ext4_disk() {
  local disk=$1 label=$2
  hp_format_guard "$disk"
  install_packages parted e2fsprogs
  confirm_format "$disk"
  note "Creating a GPT partition table and an ext4 filesystem on $disk"
  parted -s "$disk" mklabel gpt
  parted -s "$disk" mkpart primary ext4 1MiB 100%
  partprobe "$disk"
  udevadm settle
  local partition
  partition=$(lsblk -nrpo NAME,PKNAME,TYPE | awk -v disk="$disk" \
    '$2 == disk && $3 == "part" { print $1; exit }')
  [ -n "$partition" ] || die "Could not find the new partition on $disk."
  mkfs.ext4 -F -L "$label" "$partition"
  tune2fs -m 1 "$partition" >/dev/null
  SELECTED_FILESYSTEM=$partition
}

mount_filesystem() {
  local device=$1 mountpoint=$2 uuid fstype entry
  hp_safe_path "$mountpoint" || die "Use a safe absolute mount path."
  [[ $(realpath -m -- "$mountpoint") == "$mountpoint" ]] || die "Mount path must not contain symlinks."
  uuid=$(blkid -s UUID -o value "$device")
  fstype=$(blkid -s TYPE -o value "$device")
  [ -n "$uuid" ] && [ -n "$fstype" ] || die "Could not read filesystem UUID/type from $device."
  [ "$fstype" = ext4 ] || die "This script currently mounts only ext4 filesystems for server storage."

  if findmnt -rn --mountpoint "$mountpoint" >/dev/null; then
    local current_source
    current_source=$(findmnt -nr -o SOURCE --mountpoint "$mountpoint")
    [ "$current_source" = "$device" ] || die "$mountpoint is already mounted from $current_source."
    MOUNTPOINT=$mountpoint
    return 0
  fi

  if grep -Eq "^[[:space:]]*UUID=[^[:space:]]+[[:space:]]+${mountpoint}[[:space:]]" "$FSTAB"; then
    die "$mountpoint already has an /etc/fstab entry. Review it before continuing."
  fi

  # The backing directory is deliberately inaccessible to SMB/SFTP users. If a
  # removable disk disappears, clients cannot write into the system disk.
  install -d -m 0700 -o root -g root "$mountpoint"
  entry="UUID=$uuid $mountpoint ext4 $MOUNT_OPTIONS 0 2"
  backup_file "$FSTAB"
  printf '%s\n' "$entry" >> "$FSTAB"
  systemctl daemon-reload
  mount "$mountpoint"
  findmnt -rn --mountpoint "$mountpoint" >/dev/null || die "Failed to mount $mountpoint."
  MOUNTPOINT=$mountpoint
}

setup_storage() {
  local default_mount=$1 volume_label=$2 device choices=() filesystems=() selected
  select_storage_disk
  device=$SELECTED_DISK
  mapfile -t filesystems < <(discover_filesystems "$device")

  if [ "${#filesystems[@]}" -eq 0 ]; then
    printf '\nNo filesystem was detected on %s. It must be formatted before use.\n' "$device"
    confirm "Format $device as a new ext4 server-storage disk?" || exit 0
    format_ext4_disk "$device" "$volume_label"
  else
    for selected in "${filesystems[@]}"; do
      choices+=("Use existing filesystem: $(filesystem_label "$selected")")
    done
    choices+=("Erase the whole disk and format $device as ext4" 'Cancel')
    choose_menu "Existing filesystems were detected on $device." "${choices[@]}"
    if [ "$MENU_INDEX" -lt "${#filesystems[@]}" ]; then
      SELECTED_FILESYSTEM=${filesystems[$MENU_INDEX]}
    elif [ "$MENU_INDEX" -eq "${#filesystems[@]}" ]; then
      confirm "Erase $device and replace it with a new ext4 filesystem?" || exit 0
      format_ext4_disk "$device" "$volume_label"
    else
      exit 0
    fi
  fi

  ask 'Mount point' "$default_mount"
  mount_filesystem "$SELECTED_FILESYSTEM" "$REPLY"
  note "Mounted $SELECTED_FILESYSTEM at $MOUNTPOINT"
  findmnt -no SOURCE,FSTYPE,OPTIONS "$MOUNTPOINT"
}

ensure_samba_include() {
  install_packages samba
  [ -f "$SMB_CONF" ] || die "Samba configuration not found at $SMB_CONF."
  grep -Eq '^[[:space:]]*\[global\][[:space:]]*$' "$SMB_CONF" || die "No [global] section was found in $SMB_CONF."
  if ! grep -Fqx '   include = /etc/samba/photosync-setup.conf' "$SMB_CONF"; then
    backup_file "$SMB_CONF"
    sed -i '/^[[:space:]]*\[global\][[:space:]]*$/a\   include = /etc/samba/photosync-setup.conf' "$SMB_CONF"
  fi
  if [ ! -e "$SMB_MANAGED_CONF" ]; then
    install -m 0600 -o root -g root /dev/null "$SMB_MANAGED_CONF"
    printf '%s\n' '# Managed by photosync-setup.sh. Do not put passwords here.' > "$SMB_MANAGED_CONF"
  fi
  testparm -s >/dev/null || die "Samba configuration is invalid. Restore the newest ${SMB_CONF}.bak.* file and review it."
}

add_samba_share() {
  local mountpoint=$1 share username default_user path server_ip
  ask_name 'Share name, for example iphone-alice' 'iphone'
  share=$REPLY
  grep -Eq "^\[$share\]$" "$SMB_MANAGED_CONF" && die "A managed Samba share named $share already exists."
  path="$mountpoint/$share"

  default_user=${share//-/_}
  ask_name 'SMB username' "$default_user"
  username=$REPLY
  if ! id "$username" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$username"
  fi
  install -d -m 0700 -o "$username" -g "$(id -gn "$username")" "$path"

  printf '\nSet the SMB password for %s. This password is entered twice and is not stored in this script.\n' "$username"
  smbpasswd -a "$username"

  {
    printf '\n[%s]\n' "$share"
    printf '   path = %s\n' "$path"
    printf '   browseable = yes\n'
    printf '   read only = no\n'
    printf '   guest ok = no\n'
    printf '   valid users = %s\n' "$username"
    printf '   create mask = 0600\n'
    printf '   directory mask = 0700\n'
  } >> "$SMB_MANAGED_CONF"

  if ! testparm -s >/dev/null; then
    die "Samba configuration became invalid. Remove the [$share] block from $SMB_MANAGED_CONF before restarting Samba."
  fi
  systemctl enable --now smbd
  systemctl reload smbd
  server_ip=$(hostname -I | awk '{print $1}')
  printf '\n========================================\n'
  printf 'PhotoSync SMB connection details\n'
  printf '========================================\n'
  printf 'Server address : %s\n' "$server_ip"
  printf 'SMB port       : 445\n'
  printf 'Share name     : %s\n' "$share"
  printf 'Username       : %s\n' "$username"
  printf 'Windows path   : \\\\%s\\%s\n' "$server_ip" "$share"
  printf 'Server folder  : %s\n' "$path"
  printf 'Password       : the password entered during this setup (not displayed)\n'
  printf '\nIn PhotoSync, add an SMB target with the server address, share name,\n'
  printf 'username, and password shown above. Keep “Allow overwrite” disabled.\n'
}

setup_primary() {
  note 'Primary server setup: mounted storage plus private SMB upload shares.'
  setup_storage /mnt/photos PHOTOS
  ensure_samba_include
  while confirm 'Add a private phone upload share now?'; do
    add_samba_share "$MOUNTPOINT"
  done
  note "Primary setup finished. The storage is mounted at $MOUNTPOINT."
  printf 'Use one SMB share and one Samba account per phone. Do not enable guest access.\n'
}

add_phone_backup_share() {
  note 'Add a private SMB upload share for another phone.'
  # Adding a phone must never reopen storage setup: the primary installation
  # has already selected and mounted this location.
  MOUNTPOINT=/mnt/photos
  findmnt -rn -M "$MOUNTPOINT" -o SOURCE >/dev/null || \
    die "Primary photo storage is not mounted at $MOUNTPOINT. Choose Install server first, then try again."
  ensure_samba_include
  add_samba_share "$MOUNTPOINT"
}

print_samba_share() {
  local share=$1 path=$2 users=$3
  [ -n "$share" ] && [ "$share" != global ] || return 0
  printf '\nShare         : %s\n' "$share"
  printf 'Path          : %s\n' "${path:-not specified}"
  printf 'Allowed users : %s\n' "${users:-not specified}"
}

list_samba_shares() {
  local line share='' path='' users=''
  install_packages samba
  note 'Configured Samba shares'

  while IFS= read -r line; do
    if [[ $line =~ ^\[([^]]+)\]$ ]]; then
      print_samba_share "$share" "$path" "$users"
      share=${BASH_REMATCH[1]}
      path=''
      users=''
      continue
    fi
    if [[ $line =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      path=${BASH_REMATCH[1]}
    elif [[ $line =~ ^[[:space:]]*valid[[:space:]]+users[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      users=${BASH_REMATCH[1]}
    fi
  done < <(testparm -s 2>/dev/null)
  print_samba_share "$share" "$path" "$users"
}

change_samba_password() {
  local users=() entries=() username
  install_packages samba
  mapfile -t users < <(pdbedit -L 2>/dev/null | cut -d: -f1 | sort -u)
  [ "${#users[@]}" -gt 0 ] || die 'No Samba users were found. Create a phone backup share first.'

  for username in "${users[@]}"; do
    entries+=("$username")
  done
  entries+=('Cancel')
  choose_menu 'Choose the Samba user whose password you want to change.' "${entries[@]}"
  [ "$MENU_INDEX" -lt "${#users[@]}" ] || return 0
  username=${users[$MENU_INDEX]}

  printf '\nSet a new SMB password for %s. It will be requested twice and never displayed.\n' "$username"
  smbpasswd "$username"
  note "Password changed for Samba user $username."
}

delete_samba_share() {
  local shares=() entries=() share='' line username='' path='' temp
  install_packages samba
  [ -f "$SMB_MANAGED_CONF" ] || die 'No managed Samba shares were found.'

  # Only offer shares created by this script.  This protects the distribution
  # defaults and any Samba configuration the administrator maintains manually.
  mapfile -t shares < <(awk '
    /^\[[^]]+\][[:space:]]*$/ {
      name=$0
      sub(/^\[/, "", name)
      sub(/\][[:space:]]*$/, "", name)
      print name
    }
  ' "$SMB_MANAGED_CONF")
  [ "${#shares[@]}" -gt 0 ] || die 'No managed Samba shares were found.'

  for share in "${shares[@]}"; do
    entries+=("$share")
  done
  entries+=('Cancel')
  choose_menu 'Choose the Samba share to delete.' "${entries[@]}"
  [ "$MENU_INDEX" -lt "${#shares[@]}" ] || return 0
  share=${shares[$MENU_INDEX]}

  # Display the affected folder and login before asking for destructive
  # confirmation.  The folder and its photos are deliberately retained.
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      path=${BASH_REMATCH[1]}
    elif [[ $line =~ ^[[:space:]]*valid[[:space:]]+users[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      username=${BASH_REMATCH[1]}
    fi
  done < <(awk -v target="$share" '
    /^\[[^]]+\][[:space:]]*$/ {
      name=$0
      sub(/^\[/, "", name)
      sub(/\][[:space:]]*$/, "", name)
      active = (name == target)
      next
    }
    active { print }
  ' "$SMB_MANAGED_CONF")

  printf '\nShare  : %s\nFolder : %s\nUser   : %s\n' "$share" "${path:-not specified}" "${username:-not specified}"
  printf 'This removes SMB access only. The folder and its existing photos/videos stay on disk.\n'
  confirm "Delete the SMB share '$share'?" || return 0

  backup_file "$SMB_MANAGED_CONF"
  temp=$(mktemp)
  awk -v target="$share" '
    /^\[[^]]+\][[:space:]]*$/ {
      name=$0
      sub(/^\[/, "", name)
      sub(/\][[:space:]]*$/, "", name)
      skip = (name == target)
    }
    !skip { print }
  ' "$SMB_MANAGED_CONF" > "$temp"
  chmod 0600 "$temp"
  chown root:root "$temp"
  mv -- "$temp" "$SMB_MANAGED_CONF"

  testparm -s >/dev/null || die "Samba configuration became invalid. Restore the newest ${SMB_MANAGED_CONF}.bak.* file before restarting Samba."
  systemctl reload smbd

  # The Unix account is retained so the existing private folder keeps its
  # owner.  Remove only the Samba credential, unless another managed share
  # still grants that account access.
  if [ -n "$username" ] && ! grep -Eq "^[[:space:]]*valid[[:space:]]+users[[:space:]]*=[[:space:]]*${username}[[:space:]]*$" "$SMB_MANAGED_CONF"; then
    smbpasswd -x "$username" >/dev/null 2>&1 || true
  fi
  note "Deleted Samba share $share. Its files were kept at ${path:-the original folder}."
}

ensure_sshd_include() {
  install_packages openssh-server
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config || \
    die 'This server does not include /etc/ssh/sshd_config.d/*.conf. Add that Include line near the top of /etc/ssh/sshd_config, then rerun.'
  install -d -m 0755 -o root -g root /etc/ssh/sshd_config.d
}

setup_backup_user() {
  local mountpoint=$1 username repository config host keys_dir key_file
  install_packages restic
  ask_name 'Backup SFTP username' 'restic'
  username=$REPLY
  ask_name 'Repository directory name' 'photos'
  repository=$REPLY

  if ! id "$username" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir "/$repository" --shell /usr/sbin/nologin "$username"
  fi

  # Chroot requires every parent to be root-owned and not writable by others.
  chown root:root "$mountpoint"
  chmod 0755 "$mountpoint"
  install -d -m 0700 -o "$username" -g "$(id -gn "$username")" "$mountpoint/$repository"

  config="/etc/ssh/sshd_config.d/99-photosync-${username}.conf"
  [ ! -e "$config" ] || die "SSH restriction file already exists: $config"
  printf 'Match User %s\n' "$username" > "$config"
  printf '%s\n' '    ChrootDirectory '"$mountpoint" >> "$config"
  printf '%s\n' '    ForceCommand internal-sftp' >> "$config"
  printf '%s\n' '    AllowTcpForwarding no' >> "$config"
  printf '%s\n' '    X11Forwarding no' >> "$config"
  printf '%s\n' '    PermitTTY no' >> "$config"
  keys_dir=/etc/ssh/photosync-restic-keys
  key_file="$keys_dir/$username"
  install -d -m 0700 -o root -g root "$keys_dir"
  install -m 0600 -o root -g root /dev/null "$key_file"
  printf '%s\n' '    AuthorizedKeysFile /etc/ssh/photosync-restic-keys/%u' >> "$config"
  chmod 0644 "$config"
  if ! sshd -t; then
    rm -f "$config"
    die "Generated SSH configuration was invalid; it was removed."
  fi
  systemctl enable --now ssh
  systemctl reload ssh

  printf '\nSet the SFTP password for %s. Prefer an SSH key when you configure the primary server.\n' "$username"
  passwd "$username"
  host=$(hostname -I | awk '{print $1}')
  BACKUP_SFTP_USER=$username
  BACKUP_REPOSITORY=$repository
  BACKUP_HOST=$host
}

write_backup_defaults() {
  local config=/etc/photosync-restic-backup.conf
  install -m 0600 -o root -g root /dev/null "$config"
  {
    printf '%s\n' '# Created by photosync-setup.sh. The actual Restic job runs on the primary server.'
    printf 'BACKUP_HOST=%q\n' "$BACKUP_HOST"
    printf 'BACKUP_SFTP_USER=%q\n' "$BACKUP_SFTP_USER"
    printf 'BACKUP_REPOSITORY=%q\n' "$BACKUP_REPOSITORY"
    printf 'BACKUP_MOUNTPOINT=%q\n' "$MOUNTPOINT"
    printf 'PRIMARY_SOURCE=%q\n' '/mnt/photos'
    printf 'BACKUP_TIME=%q\n' "$RESTIC_BACKUP_TIME"
    printf 'MAINTENANCE_TIME=%q\n' "$RESTIC_MAINTENANCE_TIME"
    printf 'RETENTION=%q\n' "daily=$RESTIC_KEEP_DAILY weekly=$RESTIC_KEEP_WEEKLY monthly=$RESTIC_KEEP_MONTHLY yearly=$RESTIC_KEEP_YEARLY"
    printf '%s\n' 'COMPRESSION=auto'
    printf '%s\n' 'INTEGRITY_CHECK=monthly-5-percent'
  } > "$config"
}

write_primary_restic_helper() {
  local helper=/root/configure-primary-photo-restic.sh host_key
  # When invoked on the backup server, use its local host key.  The primary
  # server setup path supplies a scanned key for the remote backup server.
  host_key=${BACKUP_HOST_KEY:-}
  [ -n "$host_key" ] || host_key=$(cat /etc/ssh/ssh_host_ed25519_key.pub)
  cat > "$helper" <<EOF
#!/usr/bin/env bash
# Run this once as root on the PRIMARY photo server.
set -Eeuo pipefail

BACKUP_HOST='$BACKUP_HOST'
BACKUP_USER='$BACKUP_SFTP_USER'
BACKUP_REPOSITORY='$BACKUP_REPOSITORY'
BACKUP_HOST_KEY='$host_key'
SOURCE_PATH='/mnt/photos'
SSH_KEY='/root/.ssh/photosync-restic-ed25519'
CONFIG_DIR='/etc/photosync-restic'

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y restic openssh-client
install -d -m 0700 /root/.ssh "\$CONFIG_DIR" /var/cache/photosync-restic
if [ ! -f "\$SSH_KEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "\$SSH_KEY"
  printf '\nAuthorize this public key on the backup server by running:\n'
  printf '  sudo photosync-setup.sh authorize-restic-key\n\n'
  cat "\${SSH_KEY}.pub"
  exit 0
fi
touch /root/.ssh/known_hosts
chmod 0600 /root/.ssh/known_hosts
ssh-keygen -R "\$BACKUP_HOST" -f /root/.ssh/known_hosts >/dev/null 2>&1 || true
printf '%s %s\n' "\$BACKUP_HOST" "\$BACKUP_HOST_KEY" >> /root/.ssh/known_hosts
if ! sftp -i "\$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes "\$BACKUP_USER@\$BACKUP_HOST" <<< 'quit' >/dev/null 2>&1; then
  printf 'The primary SSH key is not yet authorized on the backup server.\n' >&2
  printf 'Run sudo /root/photosync-setup.sh setup-primary-restic to authorize it automatically with the backup administrator login.\n' >&2
  exit 1
fi
if [ ! -f "\$CONFIG_DIR/password" ]; then
  read -rsp 'Create a Restic repository password: ' password; printf '\n'
  read -rsp 'Repeat the Restic repository password: ' password2; printf '\n'
  [ "\$password" = "\$password2" ] || { printf 'Passwords did not match.\n' >&2; exit 1; }
  umask 077; printf '%s\n' "\$password" > "\$CONFIG_DIR/password"; unset password password2
fi
cat > "\$CONFIG_DIR/environment" <<ENV
export RESTIC_REPOSITORY=sftp:\${BACKUP_USER}@\${BACKUP_HOST}:/\${BACKUP_REPOSITORY}
export RESTIC_PASSWORD_FILE=\${CONFIG_DIR}/password
export RESTIC_CACHE_DIR=/var/cache/photosync-restic
ENV
chmod 0600 "\$CONFIG_DIR/environment"
. "\$CONFIG_DIR/environment"
restic cat config >/dev/null 2>&1 || restic init
cat > /usr/local/sbin/photosync-restic-backup <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/photosync-restic/environment
exec restic backup --compression auto --tag photos /mnt/photos
SCRIPT
cat > /usr/local/sbin/photosync-restic-maintenance <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/photosync-restic/environment
restic forget --prune --keep-daily 30 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3
restic check --read-data-subset=5%
SCRIPT
chmod 0700 /usr/local/sbin/photosync-restic-backup /usr/local/sbin/photosync-restic-maintenance
cat > /etc/systemd/system/photosync-restic-backup.service <<'UNIT'
[Unit]
Description=Photo library Restic backup
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/photosync-restic-backup
UNIT
cat > /etc/systemd/system/photosync-restic-backup.timer <<'UNIT'
[Unit]
Description=Nightly photo library Restic backup
[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/photosync-restic-maintenance.service <<'UNIT'
[Unit]
Description=Photo library Restic retention and integrity check
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/photosync-restic-maintenance
UNIT
cat > /etc/systemd/system/photosync-restic-maintenance.timer <<'UNIT'
[Unit]
Description=Weekly photo library Restic maintenance
[Timer]
OnCalendar=Sun *-*-* 03:30:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now photosync-restic-backup.timer photosync-restic-maintenance.timer
printf '\nRestic is configured: nightly backup at 02:30, weekly retention/integrity maintenance.\n'
EOF
  chmod 0700 "$helper"
  PRIMARY_HELPER=$helper
}

authorize_restic_key() {
  local username public_key key_file
  install_packages openssh-server
  ask_name 'Backup SFTP username' 'restic'
  username=$REPLY
  key_file="/etc/ssh/photosync-restic-keys/$username"
  [ -e "$key_file" ] || die "No Restic endpoint exists for user $username. Set up the backup server first."
  printf 'Paste the primary server SSH public key (one line): '
  IFS= read -r public_key
  [[ $public_key =~ ^(ssh-ed25519|ecdsa-sha2-[^[:space:]]+|ssh-rsa)[[:space:]] ]] || die 'That is not a supported SSH public key.'
  grep -Fqx "$public_key" "$key_file" || printf '%s\n' "$public_key" >> "$key_file"
  chmod 0600 "$key_file"
  sshd -t
  systemctl reload ssh
  note "SSH key authorized for backup user $username."
}

setup_backup() {
  note 'Backup server setup: mounted storage plus an SFTP-only, chrooted Restic repository.'
  setup_storage /mnt/photo-backup PHOTO_BACKUP
  ensure_sshd_include
  setup_backup_user "$MOUNTPOINT"
  write_backup_defaults
  write_primary_restic_helper
  note "Backup endpoint ready: sftp:${BACKUP_SFTP_USER}@${BACKUP_HOST}:/${BACKUP_REPOSITORY}"
  printf 'Storage is mounted at %s with nofail and boot mounting.\n' "$MOUNTPOINT"
  printf 'Default policy: nightly at %s; keep %s daily, %s weekly, %s monthly, and %s yearly snapshots.\n' \
    "$RESTIC_BACKUP_TIME" "$RESTIC_KEEP_DAILY" "$RESTIC_KEEP_WEEKLY" "$RESTIC_KEEP_MONTHLY" "$RESTIC_KEEP_YEARLY"
  printf 'A primary-server configuration helper was created at %s.\n' "$PRIMARY_HELPER"
  printf 'Copy it to the primary server, run it once to create its SSH key, then run photosync-setup.sh authorize-restic-key here.\n'
}

view_backup_server_info() {
  local config=/etc/photosync-restic-backup.conf mountpoint repo_path keys_file key_count
  [ -f "$config" ] || die 'No installed Restic backup-server configuration was found. Choose Install backup server first.'

  # This is a root-owned file written by this script; it contains endpoint
  # metadata only, never the Restic repository password.
  # shellcheck disable=SC1090
  . "$config"
  mountpoint=${BACKUP_MOUNTPOINT:-/mnt/photo-backup}
  repo_path="$mountpoint/$BACKUP_REPOSITORY"
  keys_file="/etc/ssh/photosync-restic-keys/$BACKUP_SFTP_USER"
  key_count=0
  [ -f "$keys_file" ] && key_count=$(grep -cE '^(ssh-ed25519|ecdsa-sha2-|ssh-rsa) ' "$keys_file" || true)

  note 'Installed Restic backup server information'
  printf 'Server name       : %s\n' "$(hostname)"
  printf 'Restic endpoint   : sftp:%s@%s:/%s\n' "$BACKUP_SFTP_USER" "$BACKUP_HOST" "$BACKUP_REPOSITORY"
  printf 'Username          : %s\n' "$BACKUP_SFTP_USER"
  printf 'Storage mount     : %s\n' "$mountpoint"
  printf 'Repository path   : %s\n' "$repo_path"
  printf 'Primary source    : %s\n' "$PRIMARY_SOURCE"
  printf 'Schedule          : nightly %s; maintenance Sunday %s\n' "$BACKUP_TIME" "$MAINTENANCE_TIME"
  printf 'Retention         : %s\n' "$RETENTION"
  printf 'Authorized SSH keys: %s\n' "$key_count"
  if findmnt -rn -M "$mountpoint" -o SOURCE,FSTYPE,OPTIONS; then
    printf '\nDisk usage:\n'
    df -h "$mountpoint"
    if [ -d "$repo_path" ]; then
      printf '\nRepository directory status: present\n'
    else
      printf '\nRepository directory status: missing\n'
    fi
  else
    printf '\nStorage status: not mounted. This is safe with nofail, but backups cannot be received until the disk returns.\n'
  fi
  command_exists restic && printf '\nRestic version: %s\n' "$(restic version)"
  press_enter_to_continue
}

ensure_restic_controller() {
  install_packages restic openssh-client sshpass
  hp_init
  command_exists systemd-creds || note "Debian credential fallback: root-only 0600 secrets, NOT encrypted at rest. Use full-disk encryption."
  install -d -m 0700 -o root -g root "$RESTIC_CONTROLLER_DIR" "$RESTIC_SERVERS_DIR" "$RESTIC_ARCHIVE_DIR" "$HOME_PHOTOS_DIR/keys"
  if [ ! -f "$RESTIC_CONTROLLER_KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$RESTIC_CONTROLLER_KEY"
    note "Created controller SSH key: ${RESTIC_CONTROLLER_KEY}.pub"
  fi
  hp_install_self
}

controller_server_dir() {
  valid_name "$1" || die "Invalid Restic server id: $1"
  local legacy=${HP_LEGACY_RESTIC_DIR:-/etc/photosync-restic-controller}
  if [[ ! -f $RESTIC_SERVERS_DIR/$1/server.conf && -f $legacy/servers/$1/server.conf ]]; then
    printf '%s/servers/%s\n' "$legacy" "$1"
  else
    printf '%s/%s\n' "$RESTIC_SERVERS_DIR" "$1"
  fi
}

encrypt_controller_secret() {
  local output=$1 credential_name=$2 secret=$3 temp
  hp_init
  if ! command_exists systemd-creds; then
    # Debian 11: explicitly marked root-only file, never pretend it is encrypted.
    temp=$(mktemp "$HOME_PHOTOS_DIR/tmp/credential.XXXXXX")
    printf 'HOMEPHOTOS-PRIVATE-V1\n%s' "$secret" > "$temp"
    chmod 0600 "$temp"
    mv -- "$temp" "$output"
    return
  fi
  temp=$(mktemp)
  chmod 0600 "$temp"
  printf '%s' "$secret" > "$temp"
  # systemd-creds authenticates the embedded credential name against the
  # encrypted file's basename when decrypting. Keep those names identical.
  credential_name=$(basename "$output")
  systemd-creds encrypt --with-key=host --name="$credential_name" "$temp" "$output" >/dev/null
  chmod 0600 "$output"
  rm -f -- "$temp"
}

decrypt_controller_secret() {
  local path=$1
  [ -f "$path" ] || die "Encrypted credential is missing: $path"
  local header
  IFS= read -r header < "$path" || true
  if [[ $header == HOMEPHOTOS-PRIVATE-V1 ]]; then
    tail -n +2 -- "$path"
  else
    command_exists systemd-creds || die 'Legacy encrypted credential needs systemd-creds on its original host. Export/re-enter it there; no automatic decryption migration.'
    systemd-creds decrypt "$path" - 2>/dev/null
  fi
}

valid_host() {
  [[ $1 =~ ^[A-Za-z0-9._:-]+$ ]]
}

valid_absolute_path() {
  [[ $1 =~ ^/[A-Za-z0-9._/+@%-]+(/[-A-Za-z0-9._+@%]+)*$ ]]
}

valid_backup_time() {
  [[ $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

ask_host() {
  local prompt=$1 default=${2-}
  while :; do
    ask "$prompt" "$default"
    valid_host "$REPLY" && return 0
    printf 'Enter an IP address or hostname without spaces.\n' >&2
  done
}

ask_absolute_path() {
  local prompt=$1 default=$2
  while :; do
    ask "$prompt" "$default"
    valid_absolute_path "$REPLY" && return 0
    printf 'Enter an absolute path using normal filename characters.\n' >&2
  done
}

ask_backup_time() {
  local prompt=$1 default=$2
  while :; do
    ask "$prompt (HH:MM, 24-hour time)" "$default"
    valid_backup_time "$REPLY" && return 0
    printf 'Enter a valid time such as 02:30.\n' >&2
  done
}

ask_nonnegative_integer() {
  local prompt=$1 default=$2
  while :; do
    ask "$prompt" "$default"
    [[ $REPLY =~ ^[0-9]+$ ]] && return 0
    printf 'Enter zero or a positive whole number.\n' >&2
  done
}

parse_source_paths() {
  local input=$1 item
  SOURCE_PATHS=()
  while IFS= read -r item || [ -n "$item" ]; do
    item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$item" ] || continue
    valid_absolute_path "$item" || die "Backup source must be an absolute path: $item"
    SOURCE_PATHS+=("$item")
  done < <(printf '%s' "$input" | tr ',' '\n')
  [ "${#SOURCE_PATHS[@]}" -gt 0 ] || die 'At least one backup source path is required.'
}

source_paths_display() {
  local joined='' path
  for path in "${SOURCE_PATHS[@]}"; do
    [ -z "$joined" ] || joined+=', '
    joined+=$path
  done
  printf '%s' "$joined"
}

write_controller_server_config() {
  local dir config path
  dir=$(controller_server_dir "$SERVER_ID")
  install -d -m 0700 -o root -g root "$dir"
  config="$dir/server.conf"
  {
    printf 'SERVER_ID=%q\n' "$SERVER_ID"
    printf 'SERVER_LABEL=%q\n' "$SERVER_LABEL"
    printf 'BACKUP_HOST=%q\n' "$BACKUP_HOST"
    printf 'ADMIN_USER=%q\n' "$ADMIN_USER"
    printf 'SFTP_USER=%q\n' "$SFTP_USER"
    printf 'REMOTE_MOUNTPOINT=%q\n' "$REMOTE_MOUNTPOINT"
    printf 'REPOSITORY=%q\n' "$REPOSITORY"
    printf 'BACKUP_TIME=%q\n' "$BACKUP_TIME"
    printf 'MAINTENANCE_TIME=%q\n' "$MAINTENANCE_TIME"
    printf 'KEEP_DAILY=%q\n' "$KEEP_DAILY"
    printf 'KEEP_WEEKLY=%q\n' "$KEEP_WEEKLY"
    printf 'KEEP_MONTHLY=%q\n' "$KEEP_MONTHLY"
    printf 'KEEP_YEARLY=%q\n' "$KEEP_YEARLY"
    printf 'COMPRESSION=%q\n' "$COMPRESSION"
    printf 'ENABLED=%q\n' "$ENABLED"
    printf 'SOURCE_PATHS=('
    for path in "${SOURCE_PATHS[@]}"; do printf ' %q' "$path"; done
    printf ' )\n'
  } > "$config"
  chmod 0600 "$config"
}

load_controller_server() {
  local dir
  dir=$(controller_server_dir "$1")
  [ -f "$dir/server.conf" ] || die "Restic backup server is not configured: $1"
  # Root-owned controller profiles are executable shell assignments so arrays
  # and paths containing spaces remain lossless.
  # shellcheck disable=SC1090
  . "$dir/server.conf"
}

controller_server_ids() {
  local config
  for config in "$RESTIC_SERVERS_DIR"/*/server.conf "${HP_LEGACY_RESTIC_DIR:-/etc/photosync-restic-controller}"/servers/*/server.conf; do
    [ -f "$config" ] || continue
    basename "$(dirname "$config")"
  done | sort -u
}

pin_controller_host_key() {
  local id=$1 dir host_key fingerprint
  load_controller_server "$id"
  dir=$(controller_server_dir "$id")
  host_key=$(ssh-keyscan -T 5 -t ed25519 "$BACKUP_HOST" 2>/dev/null | awk '$2 == "ssh-ed25519" { print $2 " " $3; exit }' || true)
  [ -n "$host_key" ] || die "Could not read an ED25519 SSH host key from $BACKUP_HOST."
  fingerprint=$(printf '%s\n' "$host_key" | ssh-keygen -lf - | awk '{print $2}')
  printf '\nBackup host: %s\nSSH fingerprint: %s\n' "$BACKUP_HOST" "$fingerprint"
  confirm 'Trust this SSH host key?' || return 1
  printf '%s %s\n' "$BACKUP_HOST" "$host_key" > "$dir/known_hosts"
  chmod 0600 "$dir/known_hosts"
}

ensure_remote_backup_storage() {
  local id=$1 check_script device filesystem_type confirm_device setup_script
  load_controller_server "$id"
  check_script=$(printf 'MOUNTPOINT=%q\n' "$REMOTE_MOUNTPOINT")
  check_script+=$'\n'
  check_script+=$(cat <<'REMOTE_STORAGE_CHECK'
set -Eeuo pipefail
if findmnt -rn -M "$MOUNTPOINT" -o SOURCE,FSTYPE,OPTIONS; then
  exit 0
fi
printf 'No filesystem is mounted at %s. Available block devices:\n' "$MOUNTPOINT"
lsblk -pnro NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS
exit 42
REMOTE_STORAGE_CHECK
)
  if remote_controller_exec "$id" "$check_script"; then
    return 0
  fi

  ask 'Remote backup block device or partition' '/dev/sda1'
  device=$REPLY
  [[ $device =~ ^/dev/[A-Za-z0-9._/-]+$ ]] || die 'Enter a valid /dev/... block-device path.'
  filesystem_type=$(remote_controller_exec "$id" "lsblk -dnro FSTYPE '$device' 2>/dev/null | head -n 1" || true)
  if [ -z "$filesystem_type" ]; then
    printf '\n%s has no detected filesystem. Formatting destroys all data on that device.\n' "$device"
    confirm "Format $device as ext4?" || die 'Remote storage setup cancelled.'
    printf 'Type the exact device path %s to confirm: ' "$device"
    IFS= read -r confirm_device
    [ "$confirm_device" = "$device" ] || die 'Device confirmation did not match.'
  else
    printf '\nDetected filesystem on %s: %s\n' "$device" "$filesystem_type"
    confirm "Mount this existing filesystem at $REMOTE_MOUNTPOINT?" || die 'Remote storage setup cancelled.'
  fi

  setup_script=$(printf 'DEVICE=%q\nMOUNTPOINT=%q\nFORMAT=%q\n' \
    "$device" "$REMOTE_MOUNTPOINT" "$([ -z "$filesystem_type" ] && printf yes || printf no)")
  setup_script+=$'\n'
  setup_script+=$(cat <<'REMOTE_STORAGE_SETUP'
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ]
test -b "$DEVICE"
root_source=$(findmnt -rn -o SOURCE /)
root_parent=$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n 1 || true)
[ "$DEVICE" != "$root_source" ]
[ -z "$root_parent" ] || [ "$DEVICE" != "/dev/$root_parent" ]
if [ "$FORMAT" = yes ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y e2fsprogs
  mkfs.ext4 -F -L PHOTO_BACKUP "$DEVICE"
fi
filesystem_type=$(lsblk -dnro FSTYPE "$DEVICE" | head -n 1)
[ -n "$filesystem_type" ]
uuid=$(blkid -s UUID -o value "$DEVICE")
[ -n "$uuid" ]
install -d -m 0755 -o root -g root "$MOUNTPOINT"
if grep -Eq "^[^#]+[[:space:]]+$MOUNTPOINT[[:space:]]+" /etc/fstab; then
  printf 'An existing fstab entry already targets %s; refusing to replace it automatically.\n' "$MOUNTPOINT" >&2
  exit 1
fi
printf 'UUID=%s %s %s defaults,nofail,x-systemd.device-timeout=10s,x-systemd.mount-timeout=30s 0 2\n' \
  "$uuid" "$MOUNTPOINT" "$filesystem_type" >> /etc/fstab
systemctl daemon-reload
mount "$MOUNTPOINT"
findmnt -rn -M "$MOUNTPOINT" -o SOURCE,FSTYPE,OPTIONS
REMOTE_STORAGE_SETUP
)
  remote_controller_exec "$id" "$setup_script" || die 'Remote backup storage setup failed.'
}

remote_controller_exec() {
  local id=$1 script=$2 dir admin_password encoded target status
  load_controller_server "$id"
  dir=$(controller_server_dir "$id")
  [ -f "$dir/known_hosts" ] || die "No pinned SSH host key exists for $id. Edit the server connection first."
  admin_password=$(decrypt_controller_secret "$dir/admin-password.cred")
  encoded=$(printf '%s' "$script" | base64 -w 0)
  target="${ADMIN_USER}@${BACKUP_HOST}"
  set +e
  SSHPASS="$admin_password" sshpass -e ssh -n \
    -o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=1 \
    -o ConnectionAttempts=1 -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$dir/known_hosts" \
    "$target" "printf '%s' '$encoded' | base64 -d | bash"
  status=$?
  set -e
  unset admin_password
  return "$status"
}

provision_controller_server() {
  local id=$1 public_key_b64 remote_script endpoint_id=$1 remote_server_id=$1
  if [[ -f $RESTIC_REPOSITORIES_DIR/$id/repository.conf ]]; then
    load_controller_repository "$id"; endpoint_id=$REPOSITORY_ID
    load_controller_storage "$REPOSITORY_STORAGE_ID"
    [[ $STORAGE_SERVER_ID == "$REPOSITORY_SERVER_ID" ]] || die 'Repository server and storage server do not match.'
    remote_server_id=$REPOSITORY_SERVER_ID
    load_controller_server "$remote_server_id"
  else
    load_controller_server "$id"
  fi
  public_key_b64=$(base64 -w 0 "${RESTIC_CONTROLLER_KEY}.pub")
  remote_script=$(printf 'SERVER_ID=%q\nSFTP_USER=%q\nMOUNTPOINT=%q\nREPOSITORY=%q\nPUBLIC_KEY_B64=%q\n' \
    "$endpoint_id" "$SFTP_USER" "$REMOTE_MOUNTPOINT" "$REPOSITORY" "$public_key_b64")
  remote_script+=$'\n'
  remote_script+=$(cat <<'REMOTE_SCRIPT'
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ]; then
  printf 'The stored administrator account must log in with uid 0.\n' >&2
  exit 1
fi
if ! findmnt -rn -M "$MOUNTPOINT" -o SOURCE,FSTYPE,OPTIONS >/dev/null; then
  printf 'Backup storage is not mounted at %s. Mount the backup disk there before provisioning.\n' "$MOUNTPOINT" >&2
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openssh-server ca-certificates
if ! id "$SFTP_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir "/$REPOSITORY" --shell /usr/sbin/nologin "$SFTP_USER"
fi
usermod --home "/$REPOSITORY" --shell /usr/sbin/nologin "$SFTP_USER"
chown root:root "$MOUNTPOINT"
chmod 0755 "$MOUNTPOINT"
install -d -m 0700 -o "$SFTP_USER" -g "$(id -gn "$SFTP_USER")" "$MOUNTPOINT/$REPOSITORY"

keys_dir="/etc/ssh/photosync-restic-controller/$SERVER_ID"
key_file="$keys_dir/authorized_keys"
install -d -m 0755 -o root -g root "$keys_dir"
printf '%s' "$PUBLIC_KEY_B64" | base64 -d > "$key_file"
printf '\n' >> "$key_file"
chmod 0644 "$key_file"
chown root:root "$key_file"

ssh_config="/etc/ssh/sshd_config.d/99-photosync-restic-controller-$SERVER_ID.conf"
{
  printf 'Match User %s\n' "$SFTP_USER"
  printf '    ChrootDirectory %s\n' "$MOUNTPOINT"
  printf '    ForceCommand internal-sftp\n'
  printf '    AuthorizedKeysFile %s\n' "$key_file"
  printf '    PubkeyAuthentication yes\n'
  printf '    PasswordAuthentication no\n'
  printf '    AllowTcpForwarding no\n'
  printf '    X11Forwarding no\n'
  printf '    PermitTTY no\n'
} > "$ssh_config"
chmod 0644 "$ssh_config"
sshd -t
systemctl enable --now ssh
systemctl reload ssh
printf 'Remote Restic endpoint ready: %s/%s (SFTP user %s)\n' "$MOUNTPOINT" "$REPOSITORY" "$SFTP_USER"
REMOTE_SCRIPT
)
  note "Provisioning Restic endpoint on $BACKUP_HOST"
  remote_controller_exec "$remote_server_id" "$remote_script" || die "Remote provisioning failed for $id."
}

restic_controller_command() {
  local id=$1 action=$2 dir repository_url password_command sftp_command credential_id=$1 lock_fd lock_path
  shift 2
  if [[ -f $RESTIC_JOBS_DIR/$id/job.conf ]]; then
    hp_resolve_job "$id"
    credential_id=$JOB_REPOSITORY_ID
  elif [[ -f $RESTIC_REPOSITORIES_DIR/$id/repository.conf ]]; then
    hp_resolve_repository "$id"
  else
    load_controller_server "$id"
  fi
  if [[ $action == backup ]]; then
    hp_restic_init
    lock_path="$RESTIC_LOCKS_DIR/repository-${credential_id}.lock"
    exec {lock_fd}>"$lock_path"
    flock -n "$lock_fd" || die "Another backup is already running for repository '$credential_id'."
  fi
  hp_install_self
  dir=$(controller_server_dir "$SERVER_ID")
  repository_url="sftp:${SFTP_USER}@${BACKUP_HOST}:/${REPOSITORY}"
  password_command="$RESTIC_INSTALL_PATH restic-secret $credential_id"
  local ssh_key=$RESTIC_CONTROLLER_KEY
  [[ $dir != "${HP_LEGACY_RESTIC_DIR:-/etc/photosync-restic-controller}/"* ]] || ssh_key=/root/.ssh/photosync-restic-controller-ed25519
  export RESTIC_CACHE_DIR="$HOME_PHOTOS_DIR/cache/restic"
  # Restic tokenizes sftp.command itself. Attach each -o value so an option
  # cannot be separated from its argument by that tokenizer.
  sftp_command="ssh -i $ssh_key -oBatchMode=yes -oConnectTimeout=15 -oStrictHostKeyChecking=yes -oUserKnownHostsFile=$dir/known_hosts ${SFTP_USER}@${BACKUP_HOST} -s sftp"
  case "$action" in
    init)
      restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" cat config >/dev/null 2>&1 || \
        restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" init
      ;;
    backup)
      hp_restic_source_guard
      local compression_args=()
      if restic backup --help | grep -q -- --compression; then compression_args=(--compression "$COMPRESSION"); fi
      # Interrupted network sessions leave repository locks behind. Restic's
      # normal unlock removes only stale locks and preserves active ones.
      restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" \
        unlock
      restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" \
        backup --one-file-system "${compression_args[@]}" --tag "photosync-$SERVER_ID" "${SOURCE_PATHS[@]}" "$@"
      ;;
    dry-run)
      # A controller dry run validates authentication and repository access.
      # It deliberately does not invoke `restic backup --dry-run`, because
      # Restic would still walk and read every configured source file.
      restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" \
        cat config >/dev/null
      ;;
    snapshots)
      restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" snapshots "$@"
      ;;
    maintenance)
      restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" \
        forget --prune --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" --keep-yearly "$KEEP_YEARLY"
      restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" \
        check --read-data-subset=5%
      ;;
    *) die "Unknown Restic controller action: $action" ;;
  esac
}

write_controller_jobs() {
  local id=$1 service timer maintenance_service maintenance_timer
  load_controller_server "$id"
  hp_install_self
  install -d -m 0700 -o root -g root "$HOME_PHOTOS_DIR/cache/restic"
  service="/etc/systemd/system/photosync-restic-${id}-backup.service"
  timer="/etc/systemd/system/photosync-restic-${id}-backup.timer"
  maintenance_service="/etc/systemd/system/photosync-restic-${id}-maintenance.service"
  maintenance_timer="/etc/systemd/system/photosync-restic-${id}-maintenance.timer"
  {
    printf '[Unit]\nDescription=Restic backup to %s\nAfter=network-online.target\nWants=network-online.target\n' "$SERVER_LABEL"
    printf 'StartLimitIntervalSec=6h\nStartLimitBurst=6\n'
    printf '[Service]\nType=oneshot\nEnvironment=HOME=/root\nEnvironment=XDG_CACHE_HOME=/etc/homephotos/cache/restic\n'
    printf 'ExecStart=%s restic-run %s\nRestart=on-failure\nRestartSec=30m\n' "$RESTIC_INSTALL_PATH" "$id"
  } > "$service"
  {
    printf '[Unit]\nDescription=Daily Restic backup to %s\n' "$SERVER_LABEL"
    printf '[Timer]\nOnCalendar=*-*-* %s:00\nPersistent=true\nRandomizedDelaySec=5m\n' "$BACKUP_TIME"
    printf '[Install]\nWantedBy=timers.target\n'
  } > "$timer"
  {
    printf '[Unit]\nDescription=Restic retention and integrity check for %s\nAfter=network-online.target\nWants=network-online.target\n' "$SERVER_LABEL"
    printf 'StartLimitIntervalSec=6h\nStartLimitBurst=6\n'
    printf '[Service]\nType=oneshot\nEnvironment=HOME=/root\nEnvironment=XDG_CACHE_HOME=/etc/homephotos/cache/restic\n'
    printf 'ExecStart=%s restic-maintenance %s\nRestart=on-failure\nRestartSec=30m\n' "$RESTIC_INSTALL_PATH" "$id"
  } > "$maintenance_service"
  {
    printf '[Unit]\nDescription=Weekly Restic maintenance for %s\n' "$SERVER_LABEL"
    printf '[Timer]\nOnCalendar=Sun *-*-* %s:00\nPersistent=true\nRandomizedDelaySec=15m\n' "$MAINTENANCE_TIME"
    printf '[Install]\nWantedBy=timers.target\n'
  } > "$maintenance_timer"
  chmod 0644 "$service" "$timer" "$maintenance_service" "$maintenance_timer"
  systemctl daemon-reload
  if [ "$ENABLED" = yes ]; then
    systemctl enable --now "photosync-restic-${id}-backup.timer" "photosync-restic-${id}-maintenance.timer"
  else
    systemctl disable --now "photosync-restic-${id}-backup.timer" "photosync-restic-${id}-maintenance.timer" 2>/dev/null || true
  fi
}

dry_run_controller_server() {
  local id=$1 remote_script path dir unit
  load_controller_server "$id"
  dir=$(controller_server_dir "$id")
  note "Backup-server dry run: $SERVER_LABEL ($BACKUP_HOST)"
  remote_script=$(printf 'SERVER_ID=%q\nSFTP_USER=%q\nMOUNTPOINT=%q\nREPOSITORY=%q\n' \
    "$SERVER_ID" "$SFTP_USER" "$REMOTE_MOUNTPOINT" "$REPOSITORY")
  remote_script+=$'\n'
  remote_script+=$(cat <<'REMOTE_DRY_RUN'
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ]
findmnt -rn -M "$MOUNTPOINT" -o SOURCE,FSTYPE,OPTIONS
test -d "$MOUNTPOINT/$REPOSITORY"
test -f "/etc/ssh/photosync-restic-controller/$SERVER_ID/authorized_keys"
test -f "/etc/ssh/sshd_config.d/99-photosync-restic-controller-$SERVER_ID.conf"
sshd -t
df -h "$MOUNTPOINT"
printf 'Backup-server checks passed.\n'
REMOTE_DRY_RUN
)
  remote_controller_exec "$id" "$remote_script" || die "Backup-server dry run failed for $id."
  note 'Primary-server source checks'
  for path in "${SOURCE_PATHS[@]}"; do
    [ -d "$path" ] || die "Backup source does not exist: $path"
    printf 'Source present: %s\n' "$path"
  done
  bash -n "$dir/server.conf"
  for unit in \
    "photosync-restic-${id}-backup.service" \
    "photosync-restic-${id}-backup.timer" \
    "photosync-restic-${id}-maintenance.service" \
    "photosync-restic-${id}-maintenance.timer"; do
    systemctl cat "$unit" >/dev/null || die "Installed systemd unit is missing: $unit"
  done
  if [ "$ENABLED" = yes ]; then
    systemctl is-enabled --quiet "photosync-restic-${id}-backup.timer" || die 'Backup timer is not enabled.'
    systemctl is-enabled --quiet "photosync-restic-${id}-maintenance.timer" || die 'Maintenance timer is not enabled.'
  fi
  printf 'Primary configuration and systemd job checks passed.\n'
  note 'Restic authentication and repository-access check (no source scan or data transfer)'
  restic_controller_command "$id" dry-run
  printf 'Restic repository access passed. No source files were scanned.\n'
}

show_controller_server_info() {
  local id=$1 dir source_display next_backup next_maintenance
  load_controller_server "$id"
  dir=$(controller_server_dir "$id")
  source_display=$(source_paths_display)
  next_backup=$(systemctl show "photosync-restic-${id}-backup.timer" -p NextElapseUSecRealtime --value 2>/dev/null || true)
  next_maintenance=$(systemctl show "photosync-restic-${id}-maintenance.timer" -p NextElapseUSecRealtime --value 2>/dev/null || true)
  note "Restic backup server: $SERVER_LABEL"
  printf 'ID                 : %s\n' "$SERVER_ID"
  printf 'Backup host        : %s\n' "$BACKUP_HOST"
  printf 'Administrator      : %s (password encrypted at rest)\n' "$ADMIN_USER"
  printf 'SFTP user          : %s\n' "$SFTP_USER"
  printf 'Remote repository  : %s/%s\n' "$REMOTE_MOUNTPOINT" "$REPOSITORY"
  printf 'Primary sources    : %s\n' "$source_display"
  printf 'Backup time        : %s daily\n' "$BACKUP_TIME"
  printf 'Maintenance        : Sunday %s\n' "$MAINTENANCE_TIME"
  printf 'Schedule timezone  : %s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || printf unknown)"
  printf 'Retention          : %s daily, %s weekly, %s monthly, %s yearly\n' \
    "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY" "$KEEP_YEARLY"
  printf 'Compression        : %s\n' "$COMPRESSION"
  printf 'Scheduled jobs     : %s\n' "$ENABLED"
  printf 'Next backup        : %s\n' "${next_backup:-not scheduled}"
  printf 'Next maintenance   : %s\n' "${next_maintenance:-not scheduled}"
  printf 'Admin credential   : %s\n' "$dir/admin-password.cred"
  printf 'Repository secret  : %s\n' "$dir/repository-password.cred"
  printf '\nLatest service result:\n'
  systemctl show "photosync-restic-${id}-backup.service" -p Result -p ExecMainStatus -p ActiveEnterTimestamp --no-pager 2>/dev/null || true
}

show_controller_recovery_credentials() {
  local id=$1 dir repository_dir admin_password repository_password
  if [[ -f $RESTIC_REPOSITORIES_DIR/$id/repository.conf ]]; then
    hp_resolve_repository "$id"
    repository_dir=$(hp_resource_dir repository "$id")
  else
    load_controller_server "$id"
    repository_dir=$(controller_server_dir "$id")
  fi
  confirm "Display recovery credentials for $SERVER_LABEL on screen?" || return 0
  dir=$(controller_server_dir "$SERVER_ID")
  admin_password=$(decrypt_controller_secret "$dir/admin-password.cred")
  repository_password=$(decrypt_controller_secret "$repository_dir/repository-password.cred")
  printf '\nBackup host                : %s\n' "$BACKUP_HOST"
  printf 'Administrator username    : %s\n' "$ADMIN_USER"
  printf 'Administrator password    : %s\n' "$admin_password"
  printf 'SFTP username             : %s\n' "$SFTP_USER"
  printf 'Restic repository         : sftp:%s@%s:/%s\n' "$SFTP_USER" "$BACKUP_HOST" "$REPOSITORY"
  printf 'Restic encryption password: %s\n' "$repository_password"
  unset admin_password repository_password
  press_enter_to_continue
}

add_controller_server() {
  local dir admin_password repository_password source_input
  ensure_restic_controller
  note 'Add and remotely provision a Restic backup server.'
  ask_name 'Server id (used in service names)' 'photo-backup'
  SERVER_ID=$REPLY
  dir=$(controller_server_dir "$SERVER_ID")
  [ ! -e "$dir/server.conf" ] || die "A Restic backup server with id $SERVER_ID already exists."
  ask 'Display name' 'Photo backup server'
  SERVER_LABEL=$REPLY
  ask_host 'Backup server IP address or hostname'
  BACKUP_HOST=$REPLY
  ask_name 'Backup server administrator username' 'root'
  ADMIN_USER=$REPLY
  ask_secret "Password for ${ADMIN_USER}@${BACKUP_HOST} (stored encrypted on this primary)"
  admin_password=$REPLY
  ask_name 'Restricted SFTP username' 'restic'
  SFTP_USER=$REPLY
  ask_absolute_path 'Mounted backup disk path on the backup server' '/mnt/photo-backup'
  REMOTE_MOUNTPOINT=$REPLY
  ask_name 'Restic repository directory name' 'photos'
  REPOSITORY=$REPLY
  ask 'Primary source paths, comma-separated' '/mnt/photos'
  source_input=$REPLY
  parse_source_paths "$source_input"
  ask_backup_time 'Daily backup time (primary server local time)' "$RESTIC_BACKUP_TIME"
  BACKUP_TIME=$REPLY
  ask_backup_time 'Sunday maintenance time (primary server local time)' "$RESTIC_MAINTENANCE_TIME"
  MAINTENANCE_TIME=$REPLY
  ask_nonnegative_integer 'Daily recovery points to keep' "$RESTIC_KEEP_DAILY"; KEEP_DAILY=$REPLY
  ask_nonnegative_integer 'Weekly recovery points to keep' "$RESTIC_KEEP_WEEKLY"; KEEP_WEEKLY=$REPLY
  ask_nonnegative_integer 'Monthly recovery points to keep' "$RESTIC_KEEP_MONTHLY"; KEEP_MONTHLY=$REPLY
  ask_nonnegative_integer 'Yearly recovery points to keep' "$RESTIC_KEEP_YEARLY"; KEEP_YEARLY=$REPLY
  choose_menu 'Restic compression' 'Automatic (recommended)' 'Maximum' 'Off'
  case "$MENU_INDEX" in 0) COMPRESSION=auto ;; 1) COMPRESSION=max ;; 2) COMPRESSION=off ;; esac
  ENABLED=yes

  write_controller_server_config
  encrypt_controller_secret "$dir/admin-password.cred" "photosync-${SERVER_ID}-admin" "$admin_password"
  unset admin_password
  pin_controller_host_key "$SERVER_ID" || die 'Backup server addition cancelled before SSH trust was saved.'

  choose_menu 'Restic repository encryption password' \
    'Generate a strong password automatically (recommended)' \
    'Enter my own password'
  if [ "$MENU_INDEX" -eq 0 ]; then
    install_packages openssl
    repository_password=$(openssl rand -base64 36 | tr -d '\n')
  else
    ask_secret 'Restic encryption password'
    repository_password=$REPLY
    ask_secret 'Repeat Restic encryption password'
    [ "$repository_password" = "$REPLY" ] || die 'Restic encryption passwords did not match.'
  fi
  encrypt_controller_secret "$dir/repository-password.cred" "photosync-${SERVER_ID}-repository" "$repository_password"
  unset repository_password

  ensure_remote_backup_storage "$SERVER_ID"
  provision_controller_server "$SERVER_ID"
  restic_controller_command "$SERVER_ID" init
  write_controller_jobs "$SERVER_ID"
  note "Restic backup server $SERVER_LABEL is installed and scheduled."
  printf 'Use Show recovery credentials and store the Restic encryption password somewhere outside this primary server.\n'
}

edit_controller_connection() {
  local id=$1 dir admin_password
  load_controller_server "$id"
  dir=$(controller_server_dir "$id")
  ask_host 'Backup server IP address or hostname' "$BACKUP_HOST"; BACKUP_HOST=$REPLY
  ask_name 'Backup server administrator username' "$ADMIN_USER"; ADMIN_USER=$REPLY
  choose_menu 'Administrator password' 'Keep current encrypted password' 'Enter a new password'
  if [ "$MENU_INDEX" -eq 1 ]; then
    ask_secret "New password for ${ADMIN_USER}@${BACKUP_HOST}"
    admin_password=$REPLY
    encrypt_controller_secret "$dir/admin-password.cred" "photosync-${SERVER_ID}-admin" "$admin_password"
    unset admin_password
  fi
  write_controller_server_config
  pin_controller_host_key "$id" || return 0
  ensure_remote_backup_storage "$id"
  provision_controller_server "$id"
  restic_controller_command "$id" init
  write_controller_jobs "$id"
  note 'Connection and administrator credentials updated.'
}

edit_controller_backup_settings() {
  local id=$1 source_input current_sources
  load_controller_server "$id"
  current_sources=$(source_paths_display)
  ask 'Display name' "$SERVER_LABEL"; SERVER_LABEL=$REPLY
  ask_name 'Restricted SFTP username' "$SFTP_USER"; SFTP_USER=$REPLY
  ask_absolute_path 'Mounted backup disk path on the backup server' "$REMOTE_MOUNTPOINT"; REMOTE_MOUNTPOINT=$REPLY
  ask_name 'Restic repository directory name' "$REPOSITORY"; REPOSITORY=$REPLY
  ask 'Primary source paths, comma-separated' "$current_sources"; source_input=$REPLY
  parse_source_paths "$source_input"
  ask_backup_time 'Daily backup time (primary server local time)' "$BACKUP_TIME"; BACKUP_TIME=$REPLY
  ask_backup_time 'Sunday maintenance time (primary server local time)' "$MAINTENANCE_TIME"; MAINTENANCE_TIME=$REPLY
  ask_nonnegative_integer 'Daily recovery points to keep' "$KEEP_DAILY"; KEEP_DAILY=$REPLY
  ask_nonnegative_integer 'Weekly recovery points to keep' "$KEEP_WEEKLY"; KEEP_WEEKLY=$REPLY
  ask_nonnegative_integer 'Monthly recovery points to keep' "$KEEP_MONTHLY"; KEEP_MONTHLY=$REPLY
  ask_nonnegative_integer 'Yearly recovery points to keep' "$KEEP_YEARLY"; KEEP_YEARLY=$REPLY
  choose_menu "Scheduled jobs are currently: $ENABLED" 'Enable scheduled jobs' 'Disable scheduled jobs'
  [ "$MENU_INDEX" -eq 0 ] && ENABLED=yes || ENABLED=no
  choose_menu "Compression is currently: $COMPRESSION" 'Automatic' 'Maximum' 'Off'
  case "$MENU_INDEX" in 0) COMPRESSION=auto ;; 1) COMPRESSION=max ;; 2) COMPRESSION=off ;; esac
  write_controller_server_config
  ensure_remote_backup_storage "$id"
  provision_controller_server "$id"
  restic_controller_command "$id" init
  write_controller_jobs "$id"
  note 'Backup sources, endpoint, retention, and schedule updated.'
}

delete_controller_server() {
  local id=$1 dir archive remote_script unit
  load_controller_server "$id"
  choose_menu "Delete management for $SERVER_LABEL? Repository backup data will always be preserved." \
    'Remove primary management and remote SFTP access' \
    'Remove primary management only' \
    'Cancel'
  [ "$MENU_INDEX" -lt 2 ] || return 0
  printf 'Type the server id %s to confirm: ' "$id"
  IFS= read -r REPLY
  [ "$REPLY" = "$id" ] || die 'Confirmation did not match; nothing was deleted.'

  if [ "$MENU_INDEX" -eq 0 ]; then
    remote_script=$(printf 'SERVER_ID=%q\nSFTP_USER=%q\n' "$SERVER_ID" "$SFTP_USER")
    remote_script+=$'\n'
    remote_script+=$(cat <<'REMOTE_DELETE'
set -Eeuo pipefail
archive="/root/photosync-restic-controller-archive/${SERVER_ID}-$(date +%Y%m%d%H%M%S)"
install -d -m 0700 "$archive"
ssh_config="/etc/ssh/sshd_config.d/99-photosync-restic-controller-$SERVER_ID.conf"
keys_dir="/etc/ssh/photosync-restic-controller/$SERVER_ID"
[ ! -f "$ssh_config" ] || mv "$ssh_config" "$archive/"
[ ! -d "$keys_dir" ] || mv "$keys_dir" "$archive/"
sshd -t
systemctl reload ssh
printf 'Remote SFTP authorization removed. Repository files were preserved.\n'
REMOTE_DELETE
)
    remote_controller_exec "$id" "$remote_script" || die 'Remote SFTP cleanup failed; primary management was not removed.'
  fi

  systemctl disable --now "photosync-restic-${id}-backup.timer" "photosync-restic-${id}-maintenance.timer" 2>/dev/null || true
  dir=$(controller_server_dir "$id")
  archive="$RESTIC_ARCHIVE_DIR/${id}-$(date +%Y%m%d%H%M%S)"
  install -d -m 0700 -o root -g root "$archive"
  for unit in \
    "/etc/systemd/system/photosync-restic-${id}-backup.service" \
    "/etc/systemd/system/photosync-restic-${id}-backup.timer" \
    "/etc/systemd/system/photosync-restic-${id}-maintenance.service" \
    "/etc/systemd/system/photosync-restic-${id}-maintenance.timer"; do
    [ ! -e "$unit" ] || mv "$unit" "$archive/"
  done
  mv "$dir" "$archive/profile"
  systemctl daemon-reload
  note "Removed $SERVER_LABEL from active management. Recovery archive: $archive"
}

controller_server_menu() {
  local id=$1
  while :; do
    load_controller_server "$id"
    choose_menu "Manage Restic server: $SERVER_LABEL" \
      'View status and configuration' \
      'Run dry run on primary and backup server' \
      'Run backup now' \
      'View snapshots' \
      'Edit host and root account' \
      'Edit SFTP, backup paths, schedule and retention' \
      'Re-provision remote endpoint' \
      'Show recovery credentials' \
      'Delete this backup server' \
      'Go back' \
      'Quit'
    case "$MENU_INDEX" in
      0) hp_action show_controller_server_info "$id" ;;
      1) hp_action dry_run_controller_server "$id" ;;
      2) hp_action restic_controller_command "$id" backup ;;
      3) hp_action restic_controller_command "$id" snapshots ;;
      4) hp_action edit_controller_connection "$id" ;;
      5) hp_action edit_controller_backup_settings "$id" ;;
      6) ensure_remote_backup_storage "$id"; provision_controller_server "$id"; write_controller_jobs "$id"; press_enter_to_continue ;;
      7) show_controller_recovery_credentials "$id" ;;
      8) delete_controller_server "$id"; return 0 ;;
      9) return 0 ;;
      10) return 0 ;;
    esac
  done
}

list_and_manage_controller_servers() {
  local ids=() entries=() id
  mapfile -t ids < <(controller_server_ids)
  [ "${#ids[@]}" -gt 0 ] || { note 'No Restic backup servers are configured.'; press_enter_to_continue; return 0; }
  for id in "${ids[@]}"; do
    load_controller_server "$id"
    entries+=("$SERVER_LABEL — $BACKUP_HOST — daily $BACKUP_TIME")
  done
  entries+=('Go back')
  choose_menu 'Select a Restic backup server.' "${entries[@]}"
  [ "$MENU_INDEX" -lt "${#ids[@]}" ] || return 0
  controller_server_menu "${ids[$MENU_INDEX]}"
}

dry_run_all_controller_servers() {
  local ids=() id
  mapfile -t ids < <(controller_server_ids)
  [ "${#ids[@]}" -gt 0 ] || die 'No Restic backup servers are configured.'
  for id in "${ids[@]}"; do
    dry_run_controller_server "$id"
  done
  press_enter_to_continue
}

restic_controller_menu() {
  while :; do
    choose_menu 'Restic backup management (runs from this primary server)' \
      'Add a Restic backup server' \
      'List and manage Restic backup servers' \
      'Dry run all Restic backup servers' \
      'Go back' \
      'Quit'
    case "$MENU_INDEX" in
      0) hp_action add_controller_server ;;
      1) hp_action list_and_manage_controller_servers ;;
      2) hp_action dry_run_all_controller_servers ;;
      3) return 0 ;;
      4) return 0 ;;
    esac
  done
}

setup_primary_restic_backup() {
  local backup_host backup_user backup_admin backup_admin_password repository host_key fingerprint ssh_key remote_tmp remote_command
  MOUNTPOINT=/mnt/photos
  findmnt -rn -M "$MOUNTPOINT" -o SOURCE >/dev/null || \
    die "Primary photo storage is not mounted at $MOUNTPOINT. Choose Install server first."

  note 'Set up this primary server to back up its photos to a Restic backup server.'
  ask 'Backup server IP address or hostname'
  backup_host=$REPLY
  ask_name 'Backup server SFTP username' 'restic'
  backup_user=$REPLY
  ask_name 'Backup server administrator username' 'root'
  backup_admin=$REPLY
  ask_secret "Password for ${backup_admin}@${backup_host} (used once; not stored)"
  backup_admin_password=$REPLY
  ask_name 'Restic repository directory name' 'photos'
  repository=$REPLY

  install_packages restic openssh-client sshpass
  # Some SSH servers print a banner/comment before the actual key.  Select
  # the key record by type instead of assuming that the first line is a key.
  host_key=$(ssh-keyscan -T 5 -t ed25519 "$backup_host" 2>/dev/null | awk '$2 == "ssh-ed25519" { print $2 " " $3; exit }' || true)
  [ -n "$host_key" ] || die "Could not read an ED25519 SSH host key from $backup_host. Check that the backup server is online and SSH is listening."
  fingerprint=$(printf '%s\n' "$host_key" | ssh-keygen -lf - | awk '{print $2}')
  printf '\nBackup server : %s\nSFTP user     : %s\nRepository    : /%s\nSSH fingerprint: %s\n' \
    "$backup_host" "$backup_user" "$repository" "$fingerprint"
  confirm 'Trust this backup server SSH key and continue?' || return 0

  BACKUP_HOST=$backup_host
  BACKUP_SFTP_USER=$backup_user
  BACKUP_REPOSITORY=$repository
  BACKUP_HOST_KEY=$host_key

  ssh_key=/root/.ssh/photosync-restic-ed25519
  install -d -m 0700 /root/.ssh
  if [ ! -f "$ssh_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$ssh_key"
    note "Created primary-server SSH key: ${ssh_key}.pub"
  fi
  [ -f "${ssh_key}.pub" ] || die "Primary SSH public key was not created at ${ssh_key}.pub."
  touch /root/.ssh/known_hosts
  chmod 0600 /root/.ssh/known_hosts
  ssh-keygen -R "$backup_host" -f /root/.ssh/known_hosts >/dev/null 2>&1 || true
  printf '%s %s\n' "$backup_host" "$host_key" >> /root/.ssh/known_hosts

  # The backup endpoint created by this script has a root-owned authorized-key
  # file.  Use the backup administrator login once to install the primary's
  # public key there; neither the administrator password nor the Restic
  # password is saved.
  remote_tmp="/tmp/photosync-restic-${backup_user}-${RANDOM}.pub"
  if ! SSHPASS="$backup_admin_password" sshpass -e scp \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts \
    "${ssh_key}.pub" "${backup_admin}@${backup_host}:${remote_tmp}"; then
    unset backup_admin_password
    die "Could not copy the primary SSH key to ${backup_admin}@${backup_host}. Check the administrator username, password, and SSH access."
  fi
  remote_command="set -eu; key_file=/etc/ssh/photosync-restic-keys/${backup_user}; test -e \$key_file || { printf '%s\\n' 'No matching Restic SFTP endpoint exists for this username.' >&2; exit 1; }; grep -Fqx -f ${remote_tmp} \$key_file || cat ${remote_tmp} >> \$key_file; rm -f ${remote_tmp}; chmod 0600 \$key_file; sshd -t; systemctl reload ssh"
  if ! SSHPASS="$backup_admin_password" sshpass -e ssh \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts \
    "${backup_admin}@${backup_host}" "$remote_command"; then
    unset backup_admin_password
    die "Could not authorize the primary SSH key on the backup server. Ensure the SFTP username ${backup_user} was created by Install backup server."
  fi
  unset backup_admin_password

  write_primary_restic_helper
  note 'Primary SSH key was authorized on the backup server.'
  printf 'Completing the encrypted Restic repository and daily schedule now.\n\n'
  "$PRIMARY_HELPER"
}

primary_samba_menu() {
  while :; do
    choose_menu 'Samba management' \
      'Add new Samba for PhotoSync backup' \
      'List all Samba shares' \
      'Change a Samba user password' \
      'Delete a Samba share' \
      'Go back' \
      'Quit'
    case "$MENU_INDEX" in
      0) add_phone_backup_share ;;
      1) list_samba_shares ;;
      2) change_samba_password ;;
      3) delete_samba_share ;;
      4) return 0 ;;
      5) exit 0 ;;
    esac
  done
}

primary_menu() {
  while :; do
    choose_menu 'PhotoSync primary server management' \
      'Install or update the primary SMB server' \
      'Samba management' \
      'Restic backup server management' \
      'Quit'
    case "$MENU_INDEX" in
      0) setup_primary ;;
      1) primary_samba_menu ;;
      2) restic_controller_menu ;;
      3) exit 0 ;;
    esac
  done
}

backup_menu() {
  while :; do
    choose_menu 'Restic backup server' \
      'Install backup server' \
      'View installed backup server information' \
      'Go back' \
      'Quit'
    case "$MENU_INDEX" in
      0) setup_backup ;;
      1) view_backup_server_info ;;
      2) return 0 ;;
      3) exit 0 ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: sudo ./$SCRIPT_NAME [primary|add-samba|list-samba|change-samba-password|delete-samba]
       sudo ./$SCRIPT_NAME restic-run SERVER_ID
       sudo ./$SCRIPT_NAME restic-maintenance SERVER_ID
       sudo ./$SCRIPT_NAME restic-dry-run SERVER_ID

       sudo ./$SCRIPT_NAME icloud-run PROFILE_ID [auth|test|fast|full|reconcile]
       sudo ./$SCRIPT_NAME library-check LIBRARY_ID

Without an argument, the colored HomePhotos menu opens (Up/Down + Enter).
Debian 11+ required. Configuration/private state: /etc/homephotos/.
No wizard. Each operation returns to its menu. Optional applications have
additional prerequisites. Existing photos are never automatically migrated.
EOF
}

main() {
  local role=${1-} server_id=${2-}
  case "$role" in
    -h|--help|help) usage; exit 0 ;;
  esac
  require_root
  hp_require_debian
  hp_init
  case "$role" in
    library-check) hp_library_load "$server_id"; return;;
    icloud-run) hp_icloud_run "$server_id" "${3:-full}"; return;;
    immich-start) hp_immich_start; return;;
    immich-stop) hp_immich_stop; return;;
    immich-supervise) hp_immich_supervise; return;;
    restic-secret) decrypt_controller_secret "$(hp_restic_secret_path "$server_id")"; return;;
    restic-run)
      [ -n "$server_id" ] || die 'restic-run requires a server id.'
      restic_controller_command "$server_id" backup
      exit 0
      ;;
    restic-maintenance)
      [ -n "$server_id" ] || die 'restic-maintenance requires a server id.'
      restic_controller_command "$server_id" maintenance
      exit 0
      ;;
    restic-dry-run)
      [ -n "$server_id" ] || die 'restic-dry-run requires a server id.'
      dry_run_controller_server "$server_id"
      exit 0
      ;;
  esac
  require_tty
  case "$role" in
    '') hp_main_menu; exit 0 ;;
    primary|add-samba|list-samba|change-samba-password|delete-samba) ;;
    *) die "Unknown role: $role. Use primary, add-samba, list-samba, change-samba-password, delete-samba, or --help." ;;
  esac

  case "$role" in
    primary) hp_main_menu ;;
    add-samba) add_phone_backup_share ;;
    list-samba) list_samba_shares ;;
    change-samba-password) change_samba_password ;;
    delete-samba) delete_samba_share ;;
  esac
}

# HomePhotos v1: state is private and isolated from photo storage.
hp_require_debian() {
  local ID='' VERSION_ID=''
  . "${1:-/etc/os-release}"
  [[ $ID == debian && $VERSION_ID =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'HomePhotos requires Debian 11 or newer.'
  (( ${VERSION_ID%%.*} >= 11 )) || die 'HomePhotos requires Debian 11 or newer.'
}

hp_init() {
  umask 077
  local private
  for private in "$HOME_PHOTOS_DIR" "$HOME_PHOTOS_DIR"/{libraries,icloud,keys,logs,cache,tmp,archives,restic,venvs}; do
    [[ ! -L $private ]] || die 'Private state directory must not be a symlink.'
    [[ ! -e $private || $(stat -c %u -- "$private") == "$EUID" ]] || die 'Private state must be owned by the running administrator.'
  done
  mkdir -p "$HOME_PHOTOS_DIR"/{libraries,icloud,keys,logs,cache,tmp,archives}
  chmod 0700 "$HOME_PHOTOS_DIR"
  export TMPDIR="$HOME_PHOTOS_DIR/tmp"
}

hp_safe_path() {
  [[ $1 =~ ^/[A-Za-z0-9_./-]+$ && $1 != / && $1 != */../* && $1 != */.. && $1 != */./* ]]
}

hp_storage_check() {
  local path=$1 expected=${2:-} uuid dev root fsroot
  hp_safe_path "$path" || die 'Use an absolute storage path without spaces or special characters.'
  [[ -d $path && $(realpath -e -- "$path") == "$path" ]] || die 'Storage path must exist and have no symlinks.'
  uuid=$(findmnt -rn --mountpoint "$path" -o UUID) || die 'Storage is not an exact mount point.'
  dev=$(findmnt -rn --mountpoint "$path" -o MAJ:MIN) || die 'Cannot identify storage device.'
  root=$(findmnt -rn --target / -o MAJ:MIN) || die 'Cannot identify root filesystem.'
  fsroot=$(findmnt -rn --mountpoint "$path" -o FSROOT) || die 'Cannot identify filesystem root.'
  [[ -n $uuid && -n $dev && -n $root && $dev != "$root" && $fsroot == / ]] || die 'Refusing root filesystem, bind subtree, or unidentified storage.'
  [[ -z $expected || $uuid == "$expected" ]] || die 'Storage UUID changed; refusing to write.'
  HP_CHECK_UUID=$uuid
}

hp_storage_save() {
  local path=$1
  hp_storage_check "$path"
  hp_init
  # Do not silently redirect existing library registrations to another drive.
  if [[ -f $HOME_PHOTOS_DIR/storage.conf ]]; then
    hp_storage_load
    [[ $path == "$HP_STORAGE_MOUNT" && $HP_CHECK_UUID == "$HP_STORAGE_UUID" ]] || die 'Storage already configured; manual reviewed migration required.'
  fi
  {
    printf 'HP_STORAGE_MOUNT=%q\n' "$path"
    printf 'HP_STORAGE_UUID=%q\n' "$HP_CHECK_UUID"
  } > "$HOME_PHOTOS_DIR/storage.conf.tmp"
  mv -- "$HOME_PHOTOS_DIR/storage.conf.tmp" "$HOME_PHOTOS_DIR/storage.conf"
}

hp_storage_load() {
  [[ -f $HOME_PHOTOS_DIR/storage.conf ]] || die 'Configure an existing mounted storage filesystem first.'
  . "$HOME_PHOTOS_DIR/storage.conf"
}

hp_storage_guard() {
  hp_storage_load
  hp_storage_check "$HP_STORAGE_MOUNT" "$HP_STORAGE_UUID"
}

hp_library_path_guard() {
  local path=$1 resolved
  hp_storage_guard
  hp_safe_path "$path" || die 'Unsafe library path.'
  resolved=$(realpath -m -- "$path")
  [[ $resolved == "$path" && $path == "$HP_STORAGE_MOUNT/"* ]] || die 'Library must be inside configured storage without symlinks.'
  # Reject nested mounts: a different disk below storage must not bypass UUID checks.
  local owner
  owner=$(findmnt -rn --target "$(dirname "$path")" -o TARGET) || die 'Cannot identify library backing mount.'
  [[ $owner == "$HP_STORAGE_MOUNT" ]] || die 'Library parent is on another mount.'
  if [[ -e $path ]]; then
    owner=$(findmnt -rn --target "$path" -o TARGET) || die 'Cannot identify library backing mount.'
    [[ $owner == "$HP_STORAGE_MOUNT" ]] || die 'Library is on another mount.'
  fi
}

hp_library_save() {
  local id=$1 path=$2 mode=$3
  valid_name "$id" || die 'Invalid library id.'
  hp_library_path_guard "$path"
  hp_init
  [[ ! -e $HOME_PHOTOS_DIR/libraries/$id.conf ]] || die 'Library id already exists.'
  case $mode in
    create) [[ ! -e $path ]] || die 'Path exists: choose adopt.'; mkdir -m 0700 -- "$path" ;;
    adopt) [[ -d $path ]] || die 'Adopt requires an existing directory.' ;;
    *) die 'Choose create or adopt.' ;;
  esac
  printf 'HP_LIBRARY_PATH=%q\n' "$path" > "$HOME_PHOTOS_DIR/libraries/$id.conf"
}

hp_library_load() {
  valid_name "$1" || die 'Invalid library id.'
  [[ -f $HOME_PHOTOS_DIR/libraries/$1.conf ]] || die 'Library not registered.'
  . "$HOME_PHOTOS_DIR/libraries/$1.conf"
  hp_library_path_guard "$HP_LIBRARY_PATH"
  [[ -d $HP_LIBRARY_PATH ]] || die 'Library directory missing.'
}

hp_icloud_profile_save() {
  local id=$1 username=$2 library=$3 dir
  valid_name "$id" && valid_name "$library" || die 'Invalid profile/library id.'
  [[ $username =~ ^[A-Za-z0-9_.+@-]+$ && $username == *@* ]] || die 'Enter an Apple account email address.'
  hp_library_load "$library"
  hp_init
  dir="$HOME_PHOTOS_DIR/icloud/$id"
  [[ ! -e $dir/profile.conf ]] || die 'Profile already exists.'
  mkdir -p "$dir"/{cookies,config,cache,data}
  {
    printf 'HP_ICLOUD_USERNAME=%q\n' "$username"
    printf 'HP_ICLOUD_LIBRARY=%q\n' "$library"
    printf 'HP_ICLOUD_APPLE_LIBRARY=%q\n' "${4:-Personal Library}"
    printf 'HP_ICLOUD_DESTINATION=%q\n' "$HP_LIBRARY_PATH/imports/icloud-$id"
  } > "$dir/profile.conf"
}

hp_icloud_profile_ids() {
  local file
  for file in "$HOME_PHOTOS_DIR"/icloud/*/profile.conf; do
    [[ -f $file ]] || continue
    basename "$(dirname "$file")"
  done | LC_ALL=C sort
}

hp_icloud_select_profile() {
  local id username file
  local -a ids=() labels=()
  mapfile -t ids < <(hp_icloud_profile_ids)
  if (( ${#ids[@]} == 0 )); then
    note 'No iCloud profile is configured. Add and authenticate a profile first.'
    return 1
  fi
  for id in "${ids[@]}"; do
    file="$HOME_PHOTOS_DIR/icloud/$id/profile.conf"
    HP_ICLOUD_USERNAME=
    . "$file"
    username=${HP_ICLOUD_USERNAME:-unknown-account}
    labels+=("$id — $username")
  done
  choose_menu 'Select iCloud profile' "${labels[@]}"
  HP_SELECTED_ICLOUD_PROFILE=${ids[$MENU_INDEX]}
}

hp_icloud_select_apple_library() {
  local id=$1 dir binary output
  local -a libraries=()
  valid_name "$id" || die 'Invalid iCloud profile id.'
  dir="$HOME_PHOTOS_DIR/icloud/$id"
  [[ -f $dir/profile.conf ]] || die 'iCloud profile not configured.'
  . "$dir/profile.conf"
  binary="$HOME_PHOTOS_DIR/venvs/icloudpd/bin/icloudpd"
  [[ -x $binary ]] || die 'Install native icloudpd first.'
  output=$(mktemp "$HOME_PHOTOS_DIR/tmp/icloud-libraries.XXXXXX")
  if ! HOME="$dir" XDG_CONFIG_HOME="$dir/config" XDG_CACHE_HOME="$dir/cache" XDG_DATA_HOME="$dir/data" \
    "$binary" --username "$HP_ICLOUD_USERNAME" --cookie-directory "$dir/cookies" \
      --list-libraries --log-level error --no-progress-bar >"$output"; then
    rm -f -- "$output"
    die 'Could not list Apple Photos libraries. Authenticate or renew this profile first.'
  fi
  mapfile -t libraries < <(grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' "$output" | sed -e '/^[[:space:]]*$/d')
  rm -f -- "$output"
  (( ${#libraries[@]} > 0 )) || die 'The account returned no Apple Photos libraries.'
  choose_menu 'Select Apple Photos library' "${libraries[@]}"
  HP_SELECTED_APPLE_LIBRARY=${libraries[$MENU_INDEX]}
}

hp_icloud_profile_set_apple_library() {
  local id=$1 apple_library=$2 dir temp
  valid_name "$id" || die 'Invalid iCloud profile id.'
  [[ -n $apple_library && $apple_library != *$'\n'* && $apple_library != *$'\r'* ]] || die 'Invalid Apple Photos library name.'
  dir="$HOME_PHOTOS_DIR/icloud/$id"
  [[ -f $dir/profile.conf ]] || die 'iCloud profile not configured.'
  . "$dir/profile.conf"
  temp=$(mktemp "$dir/profile.conf.XXXXXX")
  {
    printf 'HP_ICLOUD_USERNAME=%q\n' "$HP_ICLOUD_USERNAME"
    printf 'HP_ICLOUD_LIBRARY=%q\n' "$HP_ICLOUD_LIBRARY"
    printf 'HP_ICLOUD_APPLE_LIBRARY=%q\n' "$apple_library"
    printf 'HP_ICLOUD_DESTINATION=%q\n' "$HP_ICLOUD_DESTINATION"
  } > "$temp"
  chmod 0600 "$temp"
  mv -- "$temp" "$dir/profile.conf"
  note "Apple Photos library updated to: $apple_library"
}

hp_icloud_edit_apple_library() {
  hp_icloud_select_profile || return 1
  local id=$HP_SELECTED_ICLOUD_PROFILE
  hp_icloud_select_apple_library "$id"
  hp_icloud_profile_set_apple_library "$id" "$HP_SELECTED_APPLE_LIBRARY"
}

hp_icloud_run() (
  local id=$1 mode=$2 dir binary
  valid_name "$id" || die 'Invalid iCloud profile id.'
  dir="$HOME_PHOTOS_DIR/icloud/$id"
  [[ -f $dir/profile.conf ]] || die 'iCloud profile not configured.'
  . "$dir/profile.conf"
  hp_library_load "$HP_ICLOUD_LIBRARY"
  binary="$HOME_PHOTOS_DIR/venvs/icloudpd/bin/icloudpd"
  [[ -x $binary ]] || die 'Install native icloudpd first.'
  hp_init
  export HOME="$dir" XDG_CONFIG_HOME="$dir/config" XDG_CACHE_HOME="$dir/cache" XDG_DATA_HOME="$dir/data"
  hp_library_path_guard "$HP_LIBRARY_PATH/imports"
  mkdir -p -m 0700 -- "$HP_LIBRARY_PATH/imports"
  hp_library_path_guard "$HP_ICLOUD_DESTINATION"
  mkdir -p -m 0700 -- "$HP_ICLOUD_DESTINATION"
  export TZ=Etc/UTC
  local args=(--username "$HP_ICLOUD_USERNAME" --directory "$HP_ICLOUD_DESTINATION" --cookie-directory "$dir/cookies" --library "$HP_ICLOUD_APPLE_LIBRARY" --size original --live-photo-size original --folder-structure '{:%Y/%m/%d}')
  case $mode in
    auth) args+=(--auth-only) ;;
    test) args+=(--recent 10) ;;
    fast|sync) args+=(--until-found 25) ;;
    full|reconcile) : ;;
    *) die 'Unsupported iCloud action: only auth, test, fast, full, reconcile.' ;;
  esac
  # One process per account; no deletion or cloud modification flags ever.
  exec 9> "$dir/run.lock"
  flock -n 9 || die 'This iCloud profile is already running.'
  if "$binary" "${args[@]}"; then
    printf 'success %s\n' "$mode" > "$dir/status"
  else
    printf 'failed: review private log; re-authenticate interactively if session expired\n' > "$dir/status"
    return 1
  fi
)

hp_install_self() {
  [[ $(realpath -m -- "${BASH_SOURCE[0]}") == $(realpath -m -- "$RESTIC_INSTALL_PATH") ]] || install -m 0700 "${BASH_SOURCE[0]}" "$RESTIC_INSTALL_PATH"
}

hp_icloud_install() {
  local python=${1:-python3} arch wheel
  arch=$(uname -m)
  case $arch in
    x86_64|aarch64|armv7l) ;;
    *) die "No pinned icloudpd 1.32.3 manylinux binary wheel for architecture: $arch"; return 1;;
  esac
  # These platform wheels embed icloudpd's runtime; Debian 11 Python 3.9
  # is only the installer/venv host, not the application's Python runtime.
  "$python" -c 'import sys; assert sys.version_info[:2] >= (3,9)' || { die 'Python 3.9+ with venv is required; system Python is never replaced.'; return 1; }
  hp_init || return 1
  [[ $python != python3 && $python != /usr/bin/python3 ]] || install_packages python3-venv ca-certificates || return 1
  install -d -m 0700 "$HOME_PHOTOS_DIR/cache" "$HOME_PHOTOS_DIR/cache/pip" "$HOME_PHOTOS_DIR/cache/icloudpd" || return 1
  wheel=$("$python" - "$arch" "$HOME_PHOTOS_DIR/cache/icloudpd" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.request
from urllib.parse import urlsplit

os.umask(0o077)
tags = {
    'x86_64': 'manylinux1_x86_64.manylinux_2_5_x86_64',
    'aarch64': 'manylinux2014_aarch64.manylinux_2_17_aarch64',
    'armv7l': 'manylinux2014_armv7l.manylinux_2_17_armv7l',
}
filename = 'icloudpd-1.32.3-py2.py3-none-' + tags[sys.argv[1]] + '.whl'
with urllib.request.urlopen('https://pypi.org/pypi/icloudpd/1.32.3/json', timeout=60) as response:
    metadata = json.load(response)
matching = [item for item in metadata['urls'] if item['filename'] == filename
            and item.get('packagetype') == 'bdist_wheel' and not item.get('yanked')]
if len(matching) != 1:
    raise SystemExit('Expected exactly one official pinned manylinux wheel; no source/universal fallback.')
item = matching[0]
url = urlsplit(item['url'])
if url.scheme != 'https' or url.netloc != 'files.pythonhosted.org':
    raise SystemExit('Rejected non-official wheel download URL.')
expected = item['digests']['sha256']
if not re.fullmatch(r'[0-9a-f]{64}', expected):
    raise SystemExit('Invalid PyPI SHA256 digest.')
target = Path(sys.argv[2]) / filename
partial = target.with_suffix('.whl.part')
try:
    digest = hashlib.sha256()
    with urllib.request.urlopen(item['url'], timeout=120) as response, partial.open('wb') as output:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            output.write(chunk)
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise SystemExit('PyPI wheel SHA256 verification failed; refusing installation.')
    os.replace(partial, target)
    target.chmod(0o600)
finally:
    if partial.exists():
        partial.unlink()
print(target)
PY
  ) || { die 'Could not download and verify the pinned icloudpd binary wheel.'; return 1; }
  "$python" -m venv "$HOME_PHOTOS_DIR/venvs/icloudpd" || return 1
  PIP_CACHE_DIR="$HOME_PHOTOS_DIR/cache/pip" "$HOME_PHOTOS_DIR/venvs/icloudpd/bin/python" -m pip install --no-index --no-deps --only-binary=:all: --upgrade "$wheel" || return 1
  "$HOME_PHOTOS_DIR/venvs/icloudpd/bin/icloudpd" --version || { die 'icloudpd binary smoke test failed.'; return 1; }
}

hp_icloud_background() {
  local id=$1 unit
  valid_name "$id" || die 'Invalid iCloud profile id.'
  [[ -f $HOME_PHOTOS_DIR/icloud/$id/profile.conf ]] || die 'Profile missing.'
  . "$HOME_PHOTOS_DIR/icloud/$id/profile.conf"
  hp_library_load "$HP_ICLOUD_LIBRARY"
  hp_init
  hp_install_self
  unit="${HP_SYSTEMD_DIR:-/etc/systemd/system}/homephotos-icloud-$id.service"
  cat > "$unit" <<EOF
[Unit]
Description=HomePhotos copy-only iCloud download ($id)
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$HP_STORAGE_MOUNT
[Service]
Type=oneshot
UMask=0077
ExecStart=$RESTIC_INSTALL_PATH icloud-run $id full
StandardInput=null
StandardOutput=append:$HOME_PHOTOS_DIR/logs/icloud-$id.log
StandardError=append:$HOME_PHOTOS_DIR/logs/icloud-$id.log
TimeoutStartSec=infinity
KillMode=control-group
EOF
  chmod 0644 "$unit"
  systemctl daemon-reload
  systemctl start --no-block "homephotos-icloud-$id.service"
  note 'Background copy started. Expired Apple sessions require interactive authentication; see status/logs.'
}

# Execute outside a conditional: Bash otherwise disables errexit inside functions.
hp_action() {
  local status
  set +e
  ( set -Eeuo pipefail; trap 'exit 130' INT; "$@" )
  status=$?
  set -e
  [[ $status == 0 ]] || printf '\nAction failed/cancelled (%s). No automatic rollback was attempted.\n' "$status" >&2
  press_enter_to_continue || true
  return 0
}

hp_samba_render() {
  local library=$1 share=$2 username=$3
  hp_library_load "$library"
  printf '\n[%s]\n   path = %s\n' "$share" "$HP_LIBRARY_PATH/uploads/$share"
  printf '   valid users = %s\n   read only = no\n   guest ok = no\n' "$username"
  printf '   create mask = 0600\n   directory mask = 0700\n'
  printf '   root preexec = %s library-check %s\n   root preexec close = yes\n' "$RESTIC_INSTALL_PATH" "$library"
}

hp_samba_share() {
  local library=$1 share=$2 username=$3 temp ancestor
  valid_name "$share" && valid_name "$username" || die 'Invalid share/user name.'
  [[ $username != root ]] || die 'Root cannot be an SMB user.'
  ! id "$username" >/dev/null 2>&1 || die 'Use a new dedicated username; existing accounts are never repurposed.'
  hp_library_load "$library"
  hp_library_path_guard "$HP_LIBRARY_PATH/uploads"
  mkdir -p -m 0711 -- "$HP_LIBRARY_PATH/uploads"
  hp_library_path_guard "$HP_LIBRARY_PATH/uploads/$share"
  [[ ! -e $HP_LIBRARY_PATH/uploads/$share ]] || die 'Upload directory already exists; refusing ownership changes.'
  ensure_samba_include
  ! testparm -s --section-name="$share" 2>/dev/null | grep -q '^\[' || die 'Share already exists.'
  hp_init
  hp_install_self
  temp=$(mktemp)
  cp -- "$SMB_MANAGED_CONF" "$temp"
  hp_samba_render "$library" "$share" "$username" >> "$temp"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$username"
  smbpasswd -a "$username"
  install -d -m 0700 -o "$username" -g "$(id -gn "$username")" "$HP_LIBRARY_PATH/uploads/$share"
  # Add traversal only, never recursive ownership or photo permission changes.
  install_packages acl
  ancestor="$HP_LIBRARY_PATH/uploads"
  while :; do
    setfacl -m "u:$username:--x" -- "$ancestor"
    [[ $ancestor != / ]] || break
    ancestor=$(dirname -- "$ancestor")
  done
  backup_file "$SMB_MANAGED_CONF"
  install -m 0600 "$temp" "$SMB_MANAGED_CONF"
  rm -- "$temp"
  testparm -s >/dev/null
  systemctl enable --now smbd
  systemctl reload smbd
}

hp_storage_prompt() {
  ask 'Existing exact data-disk mount (no formatting or moving)' /mnt/photos
  hp_storage_save "$REPLY"
}

hp_library_prompt() {
  local id path mode
  ask_name 'Library id' family; id=$REPLY
  hp_storage_guard
  ask 'Library directory' "$HP_STORAGE_MOUNT/$id"; path=$REPLY
  choose_menu 'Library operation' 'Create new empty directory' 'Adopt existing directory without changing files' 'Cancel'
  case $MENU_INDEX in 0) mode=create;; 1) mode=adopt;; *) return;; esac
  hp_library_save "$id" "$path" "$mode"
}

hp_samba_prompt() {
  local library share user
  hp_select_library || return 1
  library=$HP_SELECTED_LIBRARY
  ask_name 'Share name' phone; share=$REPLY
  ask_name 'New dedicated username' phone; user=$REPLY
  hp_samba_share "$library" "$share" "$user"
}

hp_icloud_prompt() {
  local id user library
  ask_name 'Profile id' apple; id=$REPLY
  ask 'Apple account email'; user=$REPLY
  hp_select_library || return 1
  library=$HP_SELECTED_LIBRARY
  hp_icloud_profile_save "$id" "$user" "$library" 'PrimarySync'
  note 'Profile created. Authenticate it, then use Select/change Apple library if using a shared library.'
}

hp_icloud_install_prompt() {
  ask 'Python executable (3.9+ with venv; pinned Linux binary wheel, Debian 11 supported)' python3
  hp_icloud_install "$REPLY"
}

hp_icloud_selected_action() {
  local action=$1 id
  hp_icloud_select_profile || return 1
  id=$HP_SELECTED_ICLOUD_PROFILE
  case $action in
    background) hp_icloud_background "$id";;
    status) systemctl status --no-pager "homephotos-icloud-$id.service"; ;;
    stop) systemctl stop "homephotos-icloud-$id.service";;
    *) hp_icloud_run "$id" "$action";;
  esac
}

hp_icloud_delete_prompt() {
  hp_icloud_select_profile || return 1
  local id=$HP_SELECTED_ICLOUD_PROFILE dir unit
  dir="$HOME_PHOTOS_DIR/icloud/$id"
  choose_menu "Delete iCloud profile '$id'? Downloaded photos will NOT be deleted." 'Cancel' "Delete profile '$id'"
  [[ $MENU_INDEX == 1 ]] || return 0
  unit="${HP_SYSTEMD_DIR:-/etc/systemd/system}/homephotos-icloud-$id.service"
  systemctl stop "homephotos-icloud-$id.service" 2>/dev/null || true
  if [[ -f $unit ]]; then
    systemctl disable "homephotos-icloud-$id.service" 2>/dev/null || true
    rm -f -- "$unit"
    systemctl daemon-reload 2>/dev/null || true
  fi
  rm -rf -- "$dir"
  note "Profile '$id' removed. Downloaded photos in storage were kept."
}

hp_icloud_menu() {
  while :; do
    choose_menu 'HomePhotos · iCloud copy-only imports' 'Install native icloudpd' 'Add profile' 'Authenticate / renew session' 'Select/change Apple library' 'Test download (10 recent items)' 'Sync new photos only (fast)' 'Rescan and sync missing photos' 'Start full download in background' 'Background status' 'Stop background job' 'Remove profile (keep downloaded photos)' 'Back'
    case $MENU_INDEX in
      0) hp_action hp_icloud_install_prompt;; 1) hp_action hp_icloud_prompt;;
      2) hp_action hp_icloud_selected_action auth;; 3) hp_action hp_icloud_edit_apple_library;;
      4) hp_action hp_icloud_selected_action test;; 5) hp_action hp_icloud_selected_action fast;;
      6) hp_action hp_icloud_selected_action reconcile;; 7) hp_action hp_icloud_selected_action background;;
      8) hp_action hp_icloud_selected_action status;; 9) hp_action hp_icloud_selected_action stop;;
      10) hp_action hp_icloud_delete_prompt;; 11) return;;
    esac
  done
}

hp_status() {
  printf 'HomePhotos v1\nPrivate state: %s\n' "$HOME_PHOTOS_DIR"
  if [[ -f $HOME_PHOTOS_DIR/storage.conf ]]; then
    hp_storage_load
    printf 'Storage: %s\nExpected UUID: %s\n' "$HP_STORAGE_MOUNT" "$HP_STORAGE_UUID"
    (hp_storage_guard) && df -h "$HP_STORAGE_MOUNT" || printf 'WARNING: storage unavailable or identity mismatch.\n'
  else
    printf 'Storage not registered.\n'
  fi
  hp_library_list
  printf '\nRestic profiles:\n'; controller_server_ids
}

hp_library_list() {
  local file
  printf '\nRegistered libraries:\n'
  for file in "$HOME_PHOTOS_DIR"/libraries/*.conf; do
    [[ -f $file ]] || continue
    printf '  %s\n' "$(basename "$file" .conf)"
  done
}

hp_select_library() {
  local id file path
  local -a ids=() labels=()
  for file in "$HOME_PHOTOS_DIR"/libraries/*.conf; do
    [[ -f $file ]] || continue
    id=$(basename "$file" .conf)
    HP_LIBRARY_PATH=
    . "$file"
    path=${HP_LIBRARY_PATH:-unknown-path}
    ids+=("$id")
    labels+=("$id — $path")
  done
  if (( ${#ids[@]} == 0 )); then
    note 'No photo library is registered. Create or adopt a library first.'
    return 1
  fi
  choose_menu 'Select registered photo library' "${labels[@]}"
  HP_SELECTED_LIBRARY=${ids[$MENU_INDEX]}
}

hp_storage_setup() {
  [[ ! -f $HOME_PHOTOS_DIR/storage.conf ]] || die 'Storage is already registered. Do not reformat; use status.'
  setup_storage /mnt/photos PHOTOS
  hp_storage_save "$MOUNTPOINT"
}

hp_storage_menu() {
  while :; do
    choose_menu 'Storage' 'View status' 'Register existing mounted disk' 'Configure storage disk (formatting requires confirmation)' 'Back'
    case $MENU_INDEX in
      0) hp_action hp_status;; 1) hp_action hp_storage_prompt;;
      2) hp_action hp_storage_setup;; *) return;;
    esac
  done
}

hp_library_menu() {
  while :; do
    choose_menu 'Photo libraries' 'List libraries' 'Create / adopt library' 'Back'
    case $MENU_INDEX in 0) hp_action hp_library_list;; 1) hp_action hp_library_prompt;; *) return;; esac
  done
}

hp_samba_menu() {
  while :; do
    choose_menu 'Phone uploads · Samba' 'Add PhotoSync upload destination' 'List shares and connection paths' 'Change Samba password' 'Remove share access (keep files)' 'Back'
    case $MENU_INDEX in
      0) hp_action hp_samba_prompt;; 1) hp_action list_samba_shares;;
      2) hp_action change_samba_password;; 3) hp_action delete_samba_share;; *) return;;
    esac
  done
}

hp_main_menu() {
  while :; do
    choose_menu 'HomePhotos v1 · Independent management actions' 'Storage management' 'Photo libraries' 'Phone uploads (Samba)' 'iCloud downloads' 'Restic backup management' 'Immich gallery' 'Exit' 'System status'
    case $MENU_INDEX in
      0) hp_storage_menu;; 1) hp_library_menu;; 2) hp_samba_menu;;
      3) hp_icloud_menu;; 4) restic_controller_menu;;
      5) hp_immich_menu;; 6) return 0;; 7) hp_action hp_status;;
    esac
  done
}

hp_restic_source_guard() {
  local path mount rootdev dev
  ((${#SOURCE_PATHS[@]} > 0)) || die 'Backup job has no source paths configured. Edit the job and add at least one source before running it.'
  rootdev=$(findmnt -rn --target / -o MAJ:MIN) || die 'Cannot identify root filesystem.'
  for path in "${SOURCE_PATHS[@]}"; do
    [[ -d $path && $(realpath -e -- "$path") == "$path" ]] || die 'Restic source missing or symlinked.'
    if [[ -f $HOME_PHOTOS_DIR/storage.conf ]]; then
      hp_storage_guard
      [[ $path == "$HP_STORAGE_MOUNT" || $path == "$HP_STORAGE_MOUNT/"* || $path == "$HOME_PHOTOS_DIR" || $path == "$HOME_PHOTOS_DIR/"* ]] || die 'Restic source must be registered photo storage or private HomePhotos state.'
    fi
    mount=$(findmnt -rn --target "$path" -o TARGET) || die 'Restic source has no mount.'
    dev=$(findmnt -rn --target "$path" -o MAJ:MIN) || die 'Cannot identify Restic source device.'
    if [[ $path == "$HOME_PHOTOS_DIR" || $path == "$HOME_PHOTOS_DIR/"* ]]; then
      [[ -d $HOME_PHOTOS_DIR && ! -L $HOME_PHOTOS_DIR ]] || die 'Invalid private backup source.'
    else
      if [[ -f $HOME_PHOTOS_DIR/storage.conf ]]; then
        [[ $mount == "$HP_STORAGE_MOUNT" ]] || die 'Restic source mount differs from registered photo storage.'
      fi
      [[ -n $dev && $dev != "$rootdev" && $mount != / ]] || die 'Refusing Restic root-disk fallback.'
    fi
  done
}

# Optional Immich management (embedded to keep distribution standalone).
# Official docs reviewed 2026-09-27: docs.immich.app/install/{requirements,docker-compose}
# and administration/backup-and-restore, guides/external-library.

hp_immich_dir() { printf '%s' /etc/homephotos/immich; }
hp_immich_error() { printf 'Immich: %s\n' "$*" >&2; return 1; }
hp_immich_valid_path() {
  [[ $1 =~ ^/[a-zA-Z0-9_./-]+$ && $1 != / && $1 != */ && $1 != *//* && /$1/ != */../* && /$1/ != */./* ]]
}

hp_immich_install_docker() (
  local etc_dir=${HP_DOCKER_ETC_DIR:-/etc} os_release=${HP_OS_RELEASE_FILE:-/etc/os-release}
  [[ $EUID -eq 0 || $etc_dir != /etc ]] || { hp_immich_error 'Root required to install Docker.'; return 1; }
  local ID='' VERSION_CODENAME='' arch keyring sources
  . "$os_release"
  [[ $ID == debian && -n $VERSION_CODENAME ]] || { hp_immich_error 'Official Docker installation requires Debian with VERSION_CODENAME.'; return 1; }
  arch=$(dpkg --print-architecture) || return 1
  keyring="$etc_dir/apt/keyrings/docker.asc"
  sources="$etc_dir/apt/sources.list.d/docker.sources"
  apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl || return 1
  install -d -m 0755 "$(dirname "$keyring")" "$(dirname "$sources")" || return 1
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    https://download.docker.com/linux/debian/gpg -o "$keyring" || return 1
  chmod a+r "$keyring" || return 1
  {
    printf 'Types: deb\n'
    printf 'URIs: https://download.docker.com/linux/debian\n'
    printf 'Suites: %s\n' "$VERSION_CODENAME"
    printf 'Components: stable\n'
    printf 'Architectures: %s\n' "$arch"
    printf 'Signed-By: %s\n' "$keyring"
  } >"$sources" || return 1
  apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  systemctl enable --now docker || return 1
  docker version --format '{{.Server.Version}}' >/dev/null || return 1
  docker compose version --short >/dev/null || return 1
  note 'Docker Engine and the Compose plugin were installed from Docker’s signed Debian repository.'
)

hp_immich_ensure_docker() {
  if command -v docker >/dev/null && docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
    && docker compose version --short >/dev/null 2>&1; then
    return 0
  fi
  choose_menu 'Docker Engine and Compose are required but unavailable. Install them from Docker’s official Debian repository?' 'Cancel' 'Install Docker Engine and Compose'
  [[ $MENU_INDEX == 1 ]] || return 1
  hp_immich_install_docker
}

hp_immich_preflight() (
  [[ $EUID -eq 0 ]] || { hp_immich_error 'Root required.'; return 1; }
  local ID VERSION_ID flags ram engine compose
  . /etc/os-release
  flags=$(awk -F ': ' '/^flags/{print $2; exit}' /proc/cpuinfo)
  ram=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  hp_immich_capabilities "$ID" "${VERSION_ID%%.*}" "$(uname -m)" "$(nproc)" "$ram" "$flags" || {
    hp_immich_error 'Requires Debian 11+, amd64 (x86-64-v2) or arm64, 2 CPUs and 6 GiB RAM.'; return 1;
  }
  local cmd
  for cmd in docker curl openssl findmnt flock realpath sha256sum gzip; do
    command -v "$cmd" >/dev/null || { hp_immich_error "Install prerequisite: $cmd"; return 1; }
  done
  engine=$(docker version --format '{{.Server.Version}}' 2>/dev/null) || return 1
  compose=$(docker compose version --short 2>/dev/null) || return 1
  [[ ${engine%%.*} =~ ^[0-9]+$ && ${engine%%.*} -ge 25 ]] || { hp_immich_error 'Docker Engine 25+ required; install via docs.docker.com/engine/install/debian/.'; return 1; }
  compose=${compose#v}
  [[ $compose =~ ^([0-9]+)\.([0-9]+) ]] || return 1
  (( BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 24) )) || {
    hp_immich_error 'Docker Compose plugin 2.24+ required.'; return 1;
  }
)

# One-time configuration only: moving a live database/media tree is intentionally
# not implemented. Never source .env; Docker parses it as data.
hp_immich_configure() (
  set +x
  umask 077
  hp_immich_preflight || return 1
  local d parent media=$1 db=$2 password fs
  d=$(hp_immich_dir)
  [[ ! -e $d/.env ]] || { hp_immich_error 'Already configured; refusing storage or password replacement.'; return 1; }
  hp_immich_valid_path "$media" && hp_immich_valid_path "$db" || { hp_immich_error 'Use absolute paths with letters, digits, /, _, -, . only.'; return 1; }
  hp_storage_guard && hp_library_path_guard "$media" || return 1
  [[ -d $media && -d $db && ! -L $media && ! -L $db ]] || { hp_immich_error 'Create dedicated empty media and database directories first (no symlinks).'; return 1; }
  [[ $(realpath "$media") == "$media" && $(realpath "$db") == "$db" ]] || return 1
  [[ $media != "$db" && $media/ != "$db/"* && $db/ != "$media/"* ]] || return 1
  [[ -z $(find "$media" -mindepth 1 -maxdepth 1 -print -quit) && -z $(find "$db" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
    hp_immich_error 'Storage directories must be empty; existing originals belong in external library mounts.'; return 1;
  }
  fs=$(findmnt -n -o FSTYPE -T "$db") || return 1
  case $fs in ext4|ext3|ext2|xfs|btrfs|zfs) ;; *) hp_immich_error 'Database must use a local Unix filesystem, never a network share.'; return 1;; esac
  parent=$(dirname "$d")
  [[ ! -L $parent && ! -L $d && $(realpath -m "$d") == "$d" ]] || return 1
  mkdir -p "$d" || return 1
  chmod 700 "$parent" || return 1
  chmod 700 "$d" || return 1
  exec 9>"$d/operation.lock"
  flock -n 9 || return 1
  [[ ! -e $d/.env ]] || return 1
  password=$(openssl rand -hex 32) || return 1
  hp_immich_storage_record "$media" >"$d/storage.next" && hp_immich_storage_record "$db" >>"$d/storage.next" || return 1
  mv "$d/storage.next" "$d/storage.tsv" || return 1
  mkdir -p "$d/model-cache" || return 1
  hp_immich_override >"$d/override.json" || return 1
  (set -o noclobber; printf 'UPLOAD_LOCATION=%s\nDB_DATA_LOCATION=%s\nIMMICH_VERSION=v3.2.2\nDB_PASSWORD=%s\nDB_USERNAME=postgres\nDB_DATABASE_NAME=immich\nTZ=Etc/UTC\n' "$media" "$db" "$password" >"$d/.env") || return 1
  printf 'Configured pinned Immich v3.2.2. Nothing started.\n'
)

hp_immich_storage_record() {
  local uuid
  hp_immich_valid_path "$1" && [[ -d $1 && $(realpath "$1") == "$1" ]] || return 1
  uuid=$(findmnt -n -o UUID -T "$1") || return 1
  [[ $uuid =~ ^[a-zA-Z0-9-]+$ ]] || { hp_immich_error 'Storage requires a mounted filesystem with a stable UUID.'; return 1; }
  printf '%s\t%s\n' "$1" "$uuid"
}

hp_immich_storage_guard() {
  local d path uuid actual name mode
  d=$(hp_immich_dir)
  [[ -s $d/storage.tsv ]] || return 1
  while IFS=$'\t' read -r path uuid; do
    actual=$(hp_immich_storage_record "$path") || return 1
    [[ $actual == "$path"$'\t'"$uuid" ]] || { hp_immich_error 'Storage UUID changed or mount is missing; refusing start.'; return 1; }
  done <"$d/storage.tsv"
  if [[ -f $d/mounts.tsv ]]; then
    while IFS=$'\t' read -r name path uuid mode; do
      actual=$(hp_immich_storage_record "$path") || return 1
      [[ $actual == "$path"$'\t'"$uuid" ]] || return 1
      [[ -z $mode || $mode == ro || $mode == rw ]] || return 1
    done <"$d/mounts.tsv"
  fi
}

hp_immich_compose() (
  set +x
  local d
  d=$(hp_immich_dir)
  [[ -f $d/.env && -f $d/docker-compose.yml && -f $d/override.json ]] || { hp_immich_error 'Configure and install first.'; return 1; }
  # Ignore shell overrides of application settings; secrets stay in .env.
  unset UPLOAD_LOCATION DB_DATA_LOCATION IMMICH_VERSION DB_PASSWORD DB_USERNAME DB_DATABASE_NAME COMPOSE_FILE COMPOSE_PROFILES
  docker compose --project-name homephotos-immich --project-directory "$d" --env-file "$d/.env" -f "$d/docker-compose.yml" -f "$d/override.json" "$@"
)

hp_immich_override() {
  local d name path uuid mode
  d=$(hp_immich_dir)
  # Docker restart remains disabled. Optional recovery/boot startup goes through
  # the guarded HomePhotos systemd unit so UUID checks always run first.
  printf '{"services":{"database":{"restart":"no"},"redis":{"restart":"no"},"immich-machine-learning":{"restart":"no","volumes":[{"type":"bind","source":"%s/model-cache","target":"/cache","bind":{"create_host_path":false}}]},"immich-server":{"restart":"no","volumes":[' "$d"
  local sep=''
  if [[ -f $d/mounts.tsv ]]; then
    while IFS=$'\t' read -r name path uuid mode; do
      # Legacy three-column records were read-write; preserve that behavior.
      mode=${mode:-rw}
      printf '%s{"type":"bind","source":"%s","target":"/external/%s"' "$sep" "$path" "$name"
      [[ $mode != ro ]] || printf ',"read_only":true'
      printf ',"bind":{"create_host_path":false}}'
      sep=,
    done <"$d/mounts.tsv"
  fi
  printf ']}}}\n'
}

hp_immich_mount() (
  set +x
  umask 077
  local action=$1 name=${2-} path=${3-} mode=${4:-rw} d record
  d=$(hp_immich_dir)
  [[ -f $d/.env ]] || return 1
  [[ $action != list ]] || { [[ ! -f $d/mounts.tsv ]] || cat "$d/mounts.tsv"; return 0; }
  [[ $name =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 1
  exec 9>"$d/operation.lock"; flock -n 9 || return 1
  touch "$d/mounts.tsv" || return 1
  case $action in
    add)
      [[ $mode == ro || $mode == rw ]] || return 1
      record=$(hp_immich_storage_record "$path") || return 1
      # Never expose private application state or host system trees.
      case $path in /etc|/etc/*|/root|/root/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) return 1;; esac
      grep -q "^${name}"$'\t' "$d/mounts.tsv" && return 1
      cp "$d/mounts.tsv" "$d/mounts.next" || return 1
      printf '%s\t%s\t%s\n' "$name" "$record" "$mode" >>"$d/mounts.next" || return 1 ;;
    remove) awk -F '\t' -v n="$name" '$1 != n' "$d/mounts.tsv" >"$d/mounts.next" || return 1 ;;
    *) return 1 ;;
  esac
  mv "$d/mounts.next" "$d/mounts.tsv" || return 1
  hp_immich_override >"$d/override.next" && mv "$d/override.next" "$d/override.json" || return 1
  if [[ $action == add && $mode == ro ]]; then
    printf 'Read-only mount saved. Start/apply mounts, then add /external/%s in Immich Admin > External Libraries and scan. Immich cannot delete or modify originals through this mount.\n' "$name"
  elif [[ $action == add ]]; then
    printf 'Read-write mount saved. Start/apply mounts, then add /external/%s in Immich Admin > External Libraries and scan. Immich can permanently delete originals after trash is emptied.\n' "$name"
  else
    printf 'Mount configuration removed. Original files were not deleted. Start/apply mounts to update Immich.\n'
  fi
)

hp_immich_start() (
  set +x
  hp_immich_preflight || return 1
  local d; d=$(hp_immich_dir)
  exec 9>"$d/operation.lock"; flock -n 9 || return 1
  hp_immich_storage_guard || return 1
  hp_immich_compose config --quiet >/dev/null 2>&1 || return 1
  hp_immich_compose up -d --wait --wait-timeout 180 >/dev/null 2>&1 || { hp_immich_error 'Start failed or health timeout; inspect containers locally (logs can contain private data).'; return 1; }
  hp_immich_status
)
hp_immich_status() { hp_immich_compose ps; }
hp_immich_stop() { hp_immich_compose stop >/dev/null 2>&1; }
hp_immich_supervise() {
  hp_immich_start || return 1
  # Keep systemd attached to the web/API container. Any unexpected exit makes
  # this unit fail so Restart=on-failure reruns the guarded startup path.
  docker wait immich_server >/dev/null || return 1
  return 1
}

hp_immich_autostart() {
  local action=$1 unit_dir unit
  unit_dir=${HP_SYSTEMD_DIR:-/etc/systemd/system}
  unit="$unit_dir/homephotos-immich.service"
  case $action in
    enable)
      hp_immich_preflight || return 1
      hp_immich_storage_guard || return 1
      hp_install_self
      mkdir -p "$unit_dir"
      cat >"$unit" <<EOF
[Unit]
Description=HomePhotos guarded Immich startup and recovery
Requires=docker.service
After=docker.service network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$RESTIC_INSTALL_PATH immich-supervise
ExecStop=$RESTIC_INSTALL_PATH immich-stop
Restart=on-failure
RestartSec=30s
StartLimitIntervalSec=10m
StartLimitBurst=6
TimeoutStartSec=240
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
      chmod 0644 "$unit"
      systemctl daemon-reload
      systemctl enable --now homephotos-immich.service
      note 'Immich guarded auto-start/recovery enabled. Storage UUID checks run before every start.'
      ;;
    disable)
      systemctl disable --now homephotos-immich.service 2>/dev/null || true
      rm -f -- "$unit"
      systemctl daemon-reload
      note 'Immich auto-start/recovery disabled. Immich containers were stopped; data was preserved.'
      ;;
    status)
      if [[ -f $unit ]]; then
        systemctl is-enabled homephotos-immich.service 2>/dev/null || true
        systemctl status homephotos-immich.service --no-pager || true
      else
        printf 'Immich auto-start/recovery: disabled\n'
      fi
      ;;
    *) return 1 ;;
  esac
}

hp_immich_autostart_menu() {
  while :; do
    choose_menu 'Immich auto-start and failure recovery' 'Enable (start at boot and restart after failure)' 'Disable (stop Immich and remove boot start)' 'View status' 'Back'
    case $MENU_INDEX in
      0) hp_immich_autostart enable; press_enter_to_continue ;;
      1) hp_immich_autostart disable; press_enter_to_continue ;;
      2) hp_immich_autostart status; press_enter_to_continue ;;
      *) return 0 ;;
    esac
  done
}

hp_immich_backup() (
  set +x
  set -o pipefail
  umask 077
  local d tmp dest
  d=$(hp_immich_dir)
  [[ -f $d/.env ]] || return 1
  mkdir -p "$d/backups" || return 1
  exec 9>"$d/operation.lock"; flock -n 9 || return 1
  tmp=$(mktemp "$d/backups/.dump.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  hp_immich_compose exec -T database pg_dump --clean --if-exists --dbname=immich --username=postgres 2>/dev/null | gzip >"$tmp" || { hp_immich_error 'Database dump failed; partial file discarded.'; return 1; }
  gzip -t "$tmp" || return 1
  dest="$d/backups/immich-v3.2.2-$(date -u +%Y%m%dT%H%M%SZ)-${tmp##*.}.sql.gz"
  mv "$tmp" "$dest" || return 1
  printf 'Database-only backup: %s\nAlso back up media and external originals (database first, files second).\n' "$dest"
)

hp_immich_install() (
  set +x
  umask 077
  hp_immich_preflight && hp_immich_storage_guard || return 1
  local d tmp hash
  d=$(hp_immich_dir)
  exec 9>"$d/operation.lock"; flock -n 9 || return 1
  tmp=$(mktemp "$d/.compose.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 https://github.com/immich-app/immich/releases/download/v3.2.2/docker-compose.yml -o "$tmp" || return 1
  hash=$(sha256sum "$tmp"); hash=${hash%% *}
  [[ $hash == fa98c3eb0884b0b88aaee11a9c9acb8cfb17a0f495d12c21358deb6d3e8a546b ]] || { hp_immich_error 'Official compose checksum mismatch; refusing installation.'; return 1; }
  if [[ -e $d/docker-compose.yml ]]; then
    cmp -s "$tmp" "$d/docker-compose.yml" || { hp_immich_error 'Existing compose differs; no automatic upgrade or overwrite.'; return 1; }
  else
    mv "$tmp" "$d/docker-compose.yml" || return 1
  fi
  hp_immich_compose config --quiet >/dev/null 2>&1 || return 1
  hp_immich_compose pull >/dev/null 2>&1 || { hp_immich_error 'Image pull failed; nothing started.'; return 1; }
  printf 'Official pinned v3.2.2 compose and images installed; choose Start explicitly. No automatic upgrades.\n'
)

hp_immich_configure_prompt() {
  local media db media_default db_default
  hp_immich_ensure_docker || { hp_immich_error 'Docker installation was cancelled or failed.'; return 1; }
  hp_storage_load
  media_default="$HP_STORAGE_MOUNT/immich"
  db_default=${HP_IMMICH_DB_DEFAULT:-/var/lib/immich/postgres}
  printf '%s\n' \
    'Immich managed media (uploads, thumbnails and transcoded files) should be on the large storage drive.' \
    'The PostgreSQL database should be on the local NVMe/system drive for fast random I/O.' \
    'Existing photo libraries are added later as read-write external folders; do not use them here.'
  ask 'Media directory (large storage drive)' "$media_default"; media=$REPLY
  ask 'Database directory (local NVMe/system drive)' "$db_default"; db=$REPLY
  hp_immich_valid_path "$media" && hp_immich_valid_path "$db" || {
    hp_immich_error 'Use absolute paths with letters, digits, /, _, -, . only.'; return 1;
  }
  [[ ! -e $media || ( -d $media && ! -L $media ) ]] || { hp_immich_error 'Media path exists but is not a normal directory.'; return 1; }
  [[ ! -e $db || ( -d $db && ! -L $db ) ]] || { hp_immich_error 'Database path exists but is not a normal directory.'; return 1; }
  mkdir -p -- "$media" "$db" || { hp_immich_error 'Could not create the storage directories.'; return 1; }
  chmod 700 -- "$media" "$db" || return 1
  hp_immich_configure "$media" "$db"
}

hp_immich_menu() {
  local name path
  while :; do
    choose_menu 'Immich (optional, pinned v3.2.2; no automatic upgrade)' 'Configure storage (one time)' 'Install Immich v3.2.2 compose/images' 'Status' 'Start / apply mounts' 'Stop (preserve everything)' 'Database backup' 'Add read-write external folder' 'Add read-only external folder' 'Config auto restart Immich' 'Remove external mount (not files)' 'List external mounts' 'Back'
    case $MENU_INDEX in
      0)
        printf 'Docker Engine 25+ and Compose 2.24+ must already be installed using https://docs.docker.com/engine/install/debian/\n'
        hp_immich_configure_prompt || printf 'Configuration failed.\n' ;;
      1) hp_immich_install || printf 'Installation failed.\n' ;;
      2) hp_immich_status || printf 'Not installed or Docker unavailable.\n' ;;
      3)
        choose_menu 'Starts Immich on TCP 2283 (all interfaces). Use trusted LAN/firewall, never port-forward. Continue?' 'Cancel' 'Start'
        if [[ $MENU_INDEX == 1 ]]; then hp_immich_start || printf 'Start failed.\n'; fi ;;
      4) hp_immich_stop || printf 'Stop failed.\n' ;;
      5) hp_immich_backup || printf 'Backup failed.\n' ;;
      6|7)
        printf 'Mount name (lowercase): '; IFS= read -r name || return
        printf 'Existing originals directory: '; IFS= read -r path || return
        if [[ $MENU_INDEX == 6 ]]; then
          hp_immich_mount add "$name" "$path" rw || printf 'Mount rejected.\n'
        else
          hp_immich_mount add "$name" "$path" ro || printf 'Mount rejected.\n'
        fi ;;
      8) hp_immich_autostart_menu ;;
      9)
        printf 'Mount name to remove: '; IFS= read -r name || return
        hp_immich_mount remove "$name" || printf 'Mount removal failed.\n' ;;
      10) hp_immich_mount list || printf 'Not configured.\n' ;;
      *) return 0 ;;
    esac
    press_enter_to_continue
  done
}

hp_immich_capabilities() {
  local os=$1 version=$2 arch=$3 cores=$4 ram_kib=$5 flags=" $6 " flag
  [[ $os == debian && $version =~ ^[0-9]+$ && $version -ge 11 ]] || return 1
  [[ $cores =~ ^[0-9]+$ && $cores -ge 2 && $ram_kib =~ ^[0-9]+$ && $ram_kib -ge 6291456 ]] || return 1
  case $arch in
    aarch64|arm64) return 0 ;;
    x86_64|amd64)
      flags=${flags//pni/sse3}
      for flag in sse3 ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm; do
        [[ $flags == *" $flag "* ]] || return 1
      done ;;
    *) return 1 ;;
  esac
}


# Restic v2 resource model. Server connections, remote storage, repositories,
# and jobs are independent so one host can expose several disks/repositories.
hp_restic_init() {
  umask 077
  mkdir -p "$RESTIC_SERVERS_DIR" "$RESTIC_STORAGES_DIR" "$RESTIC_REPOSITORIES_DIR" "$RESTIC_JOBS_DIR" "$RESTIC_LOCKS_DIR" "$RESTIC_ARCHIVE_DIR"
  chmod 0700 "$RESTIC_CONTROLLER_DIR" "$RESTIC_SERVERS_DIR" "$RESTIC_STORAGES_DIR" "$RESTIC_REPOSITORIES_DIR" "$RESTIC_JOBS_DIR" "$RESTIC_LOCKS_DIR" "$RESTIC_ARCHIVE_DIR"
}

hp_resource_dir() {
  valid_name "$2" || die "Invalid $1 id: $2"
  case $1 in
    server) printf '%s/%s' "$RESTIC_SERVERS_DIR" "$2";;
    storage) printf '%s/%s' "$RESTIC_STORAGES_DIR" "$2";;
    repository) printf '%s/%s' "$RESTIC_REPOSITORIES_DIR" "$2";;
    job) printf '%s/%s' "$RESTIC_JOBS_DIR" "$2";;
    *) die 'Unknown Restic resource type.';;
  esac
}

write_controller_server_config() {
  local dir; hp_restic_init; dir=$(hp_resource_dir server "$SERVER_ID")
  mkdir -p "$dir"
  { printf 'SERVER_ID=%q\nSERVER_LABEL=%q\nBACKUP_HOST=%q\nADMIN_USER=%q\n' "$SERVER_ID" "$SERVER_LABEL" "$BACKUP_HOST" "$ADMIN_USER"; } > "$dir/server.conf"
  chmod 0600 "$dir/server.conf"
}
write_controller_storage_config() {
  local dir; hp_restic_init; dir=$(hp_resource_dir storage "$STORAGE_ID"); mkdir -p "$dir"
  { printf 'STORAGE_ID=%q\nSTORAGE_LABEL=%q\nSTORAGE_SERVER_ID=%q\nSTORAGE_KIND=%q\nSTORAGE_DEVICE=%q\nSTORAGE_UUID=%q\nREMOTE_MOUNTPOINT=%q\n' "$STORAGE_ID" "$STORAGE_LABEL" "$STORAGE_SERVER_ID" "$STORAGE_KIND" "$STORAGE_DEVICE" "$STORAGE_UUID" "$REMOTE_MOUNTPOINT"; } > "$dir/storage.conf"
  chmod 0600 "$dir/storage.conf"
}
write_controller_repository_config() {
  local dir; hp_restic_init; dir=$(hp_resource_dir repository "$REPOSITORY_ID"); mkdir -p "$dir"
  { printf 'REPOSITORY_ID=%q\nREPOSITORY_LABEL=%q\nREPOSITORY_SERVER_ID=%q\nREPOSITORY_STORAGE_ID=%q\nSFTP_USER=%q\nREPOSITORY=%q\n' "$REPOSITORY_ID" "$REPOSITORY_LABEL" "$REPOSITORY_SERVER_ID" "$REPOSITORY_STORAGE_ID" "$SFTP_USER" "$REPOSITORY"; } > "$dir/repository.conf"
  chmod 0600 "$dir/repository.conf"
}
write_controller_job_config() {
  local dir path; hp_restic_init; dir=$(hp_resource_dir job "$JOB_ID"); mkdir -p "$dir"
  { printf 'JOB_ID=%q\nJOB_LABEL=%q\nJOB_REPOSITORY_ID=%q\nBACKUP_TIME=%q\nMAINTENANCE_TIME=%q\nKEEP_DAILY=%q\nKEEP_WEEKLY=%q\nKEEP_MONTHLY=%q\nKEEP_YEARLY=%q\nCOMPRESSION=%q\nENABLED=%q\nSOURCE_PATHS=(' "$JOB_ID" "$JOB_LABEL" "$JOB_REPOSITORY_ID" "$BACKUP_TIME" "$MAINTENANCE_TIME" "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY" "$KEEP_YEARLY" "$COMPRESSION" "$ENABLED"; for path in "${SOURCE_PATHS[@]}"; do printf ' %q' "$path"; done; printf ' )\n'; } > "$dir/job.conf"
  chmod 0600 "$dir/job.conf"
}
load_controller_job() { SOURCE_PATHS=(); local d; d=$(hp_resource_dir job "$1"); [[ -f $d/job.conf ]] || die "Restic job not configured: $1"; . "$d/job.conf"; }
load_controller_repository() { local d; d=$(hp_resource_dir repository "$1"); [[ -f $d/repository.conf ]] || die "Restic repository not configured: $1"; . "$d/repository.conf"; }
load_controller_storage() { local d; d=$(hp_resource_dir storage "$1"); [[ -f $d/storage.conf ]] || die "Restic storage not configured: $1"; . "$d/storage.conf"; }

hp_resolve_job() {
  load_controller_job "$1"
  hp_resolve_repository "$JOB_REPOSITORY_ID"
}

hp_resolve_repository() {
  load_controller_repository "$1"
  load_controller_storage "$REPOSITORY_STORAGE_ID"
  [[ $STORAGE_SERVER_ID == "$REPOSITORY_SERVER_ID" ]] || die 'Repository server and storage server do not match.'
  load_controller_server "$REPOSITORY_SERVER_ID"
}

hp_restic_secret_path() {
  local id=$1 path
  path="$RESTIC_REPOSITORIES_DIR/$id/repository-password.cred"
  if [[ -f $path ]]; then printf '%s' "$path"; else printf '%s/repository-password.cred' "$(controller_server_dir "$id")"; fi
}

hp_resource_ids() { local f suffix=$2; for f in "$1"/*/"$suffix"; do [[ -f $f ]] && basename "$(dirname "$f")"; done | sort; }
hp_job_ids() { hp_resource_ids "$RESTIC_JOBS_DIR" job.conf; }

write_controller_jobs() {
  local id=$1 unit_dir=${HP_SYSTEMD_DIR:-/etc/systemd/system} service timer maintenance_service maintenance_timer
  load_controller_job "$id"; mkdir -p "$unit_dir" "$HOME_PHOTOS_DIR/cache/restic"
  service="$unit_dir/homephotos-restic-job-${id}-backup.service"; timer="$unit_dir/homephotos-restic-job-${id}-backup.timer"
  maintenance_service="$unit_dir/homephotos-restic-job-${id}-maintenance.service"; maintenance_timer="$unit_dir/homephotos-restic-job-${id}-maintenance.timer"
  printf '[Unit]\nDescription=Restic job %s\nAfter=network-online.target\n[Service]\nType=oneshot\nExecStart=%s restic-run %s\n' "$JOB_LABEL" "$RESTIC_INSTALL_PATH" "$id" > "$service"
  printf '[Unit]\nDescription=Schedule Restic job %s\n[Timer]\nOnCalendar=*-*-* %s:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n' "$JOB_LABEL" "$BACKUP_TIME" > "$timer"
  printf '[Unit]\nDescription=Maintain Restic job %s\n[Service]\nType=oneshot\nExecStart=%s restic-maintenance %s\n' "$JOB_LABEL" "$RESTIC_INSTALL_PATH" "$id" > "$maintenance_service"
  printf '[Unit]\nDescription=Schedule maintenance %s\n[Timer]\nOnCalendar=Sun *-*-* %s:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n' "$JOB_LABEL" "$MAINTENANCE_TIME" > "$maintenance_timer"
  chmod 0644 "$service" "$timer" "$maintenance_service" "$maintenance_timer"; systemctl daemon-reload
  if [[ $ENABLED == yes ]]; then systemctl enable --now "homephotos-restic-job-${id}-backup.timer" "homephotos-restic-job-${id}-maintenance.timer"; else systemctl disable --now "homephotos-restic-job-${id}-backup.timer" "homephotos-restic-job-${id}-maintenance.timer" 2>/dev/null || true; fi
}

hp_migrate_legacy_profile() {
  local id=$1 src="${HP_LEGACY_RESTIC_DIR:-/etc/photosync-restic-controller}/servers/$1" path
  hp_restic_init; [[ -f $src/server.conf ]] || die "Legacy profile not found: $id"
  # shellcheck disable=SC1090
  . "$src/server.conf"
  [[ -f $RESTIC_JOBS_DIR/$id/job.conf ]] && return 0
  write_controller_server_config
  for path in admin-password.cred known_hosts; do [[ ! -f $src/$path ]] || cp -p "$src/$path" "$RESTIC_SERVERS_DIR/$id/$path"; done
  STORAGE_ID=$id STORAGE_LABEL="$SERVER_LABEL storage" STORAGE_SERVER_ID=$id STORAGE_KIND=direct STORAGE_DEVICE=legacy STORAGE_UUID=legacy; write_controller_storage_config
  REPOSITORY_ID=$id REPOSITORY_LABEL="$SERVER_LABEL repository" REPOSITORY_SERVER_ID=$id REPOSITORY_STORAGE_ID=$id; write_controller_repository_config
  [[ ! -f $src/repository-password.cred ]] || cp -p "$src/repository-password.cred" "$RESTIC_REPOSITORIES_DIR/$id/repository-password.cred"
  JOB_ID=$id JOB_LABEL="$SERVER_LABEL backup" JOB_REPOSITORY_ID=$id; write_controller_job_config
  note "Legacy profile '$id' migrated idempotently; original files were preserved."
}

hp_dependents() { local dir=$1 key=$2 value=$3 f actual; for f in "$dir"/*/*.conf; do [[ -f $f ]] || continue; actual=$(bash -c ". \"$f\"; printf '%s' \"\${$key-}\""); [[ $actual == "$value" ]] && basename "$(dirname "$f")"; done; }
hp_delete_job() { local id=$1 d; d=$(hp_resource_dir job "$id"); systemctl disable --now "homephotos-restic-job-${id}-backup.timer" "homephotos-restic-job-${id}-maintenance.timer" 2>/dev/null || true; rm -f "${HP_SYSTEMD_DIR:-/etc/systemd/system}"/homephotos-restic-job-"$id"-{backup,maintenance}.{service,timer}; [[ ! -e $d ]] || mv "$d" "$RESTIC_ARCHIVE_DIR/job-$id-$(date +%s)"; }
hp_delete_repository() { local id=$1 deps d; deps=$(hp_dependents "$RESTIC_JOBS_DIR" JOB_REPOSITORY_ID "$id"); [[ -z $deps ]] || die "Repository is used by jobs: $deps"; d=$(hp_resource_dir repository "$id"); [[ ! -e $d ]] || mv "$d" "$RESTIC_ARCHIVE_DIR/repository-$id-$(date +%s)"; note 'Repository management removed; remote data preserved.'; }
hp_delete_storage() { local id=$1 deps d; deps=$(hp_dependents "$RESTIC_REPOSITORIES_DIR" REPOSITORY_STORAGE_ID "$id"); [[ -z $deps ]] || die "Storage is used by repositories: $deps"; d=$(hp_resource_dir storage "$id"); [[ ! -e $d ]] || mv "$d" "$RESTIC_ARCHIVE_DIR/storage-$id-$(date +%s)"; note 'Storage registration removed; filesystem and data preserved.'; }
hp_delete_server() { local id=$1 deps d; deps=$(hp_dependents "$RESTIC_STORAGES_DIR" STORAGE_SERVER_ID "$id"); deps+=$(hp_dependents "$RESTIC_REPOSITORIES_DIR" REPOSITORY_SERVER_ID "$id"); [[ -z $deps ]] || die "Server has dependent resources: $deps"; d=$(hp_resource_dir server "$id"); [[ ! -e $d ]] || mv "$d" "$RESTIC_ARCHIVE_DIR/server-$id-$(date +%s)"; }

hp_remote_storage_direct_script() { cat <<'REMOTE'
set -Eeuo pipefail
root_source=$(findmnt -rn -o SOURCE /); root_chain=$(lsblk -s -nrpo NAME "$root_source")
test -b "$DEVICE"; ! grep -Fxq "$DEVICE" <<< "$root_chain"
[[ -z $(lsblk -nr -o MOUNTPOINT "$DEVICE" | tr -d '[:space:]') ]] || { echo 'Device is mounted/in use' >&2; exit 1; }
if [[ $MODE == format ]]; then
  [[ $CONFIRMATION == "TYPE THE EXACT WHOLE DISK $DEVICE" ]] || exit 1
  [[ $(lsblk -dnro TYPE "$DEVICE") == disk ]] || exit 1
  parted -s "$DEVICE" mklabel gpt; parted -s "$DEVICE" mkpart primary ext4 1MiB 100%; partprobe "$DEVICE"; udevadm settle
  DEVICE=$(lsblk -nrpo NAME,PKNAME,TYPE | awk -v d="$DEVICE" '$2==d && $3=="part"{print $1;exit}'); mkfs.ext4 -F "$DEVICE"
fi
[[ $(blkid -s TYPE -o value "$DEVICE") == ext4 ]] || { echo 'Only direct ext4 storage is accepted' >&2; exit 1; }
uuid=$(blkid -s UUID -o value "$DEVICE"); [[ -n $uuid ]]; mkdir -p "$MOUNTPOINT"
grep -q "^UUID=$uuid " /etc/fstab || printf 'UUID=%s %s ext4 defaults,nofail,x-systemd.device-timeout=10s 0 2\n' "$uuid" "$MOUNTPOINT" >> /etc/fstab
mount "$MOUNTPOINT"; [[ $(findmnt -rn -M "$MOUNTPOINT" -o UUID) == "$uuid" ]] || exit 1
REMOTE
}
hp_remote_storage_lvm_script() { cat <<'REMOTE'
echo 'LVM IS OPTIONAL and changes storage topology; use only after explicit review.' >&2
[[ $LVM_CONFIRM == "CREATE LVM $VG/$LV ON $DEVICE" ]] || exit 1
pvcreate "$DEVICE"; vgcreate "$VG" "$DEVICE"; lvcreate -l 100%FREE -n "$LV" "$VG"; mkfs.ext4 "/dev/$VG/$LV"
REMOTE
}

add_controller_server() {
  local dir admin_password
  ensure_restic_controller; hp_restic_init
  ask_name 'Server connection id' photo-backup; SERVER_ID=$REPLY
  dir=$(hp_resource_dir server "$SERVER_ID"); [[ ! -e $dir ]] || die "Server connection already exists: $SERVER_ID"
  ask 'Display label' 'Photo backup server'; SERVER_LABEL=$REPLY
  ask_host 'Backup server IP address or hostname'; BACKUP_HOST=$REPLY
  ask_name 'Administrator username' root; ADMIN_USER=$REPLY
  ask_secret "Password for ${ADMIN_USER}@${BACKUP_HOST}"; admin_password=$REPLY
  write_controller_server_config
  encrypt_controller_secret "$dir/admin-password.cred" "homephotos-${SERVER_ID}-admin" "$admin_password"; unset admin_password
  if ! pin_controller_host_key "$SERVER_ID"; then
    rm -rf -- "$dir"; note 'Server addition cancelled before host-key trust was saved.'; return 1
  fi
  if ! remote_controller_exec "$SERVER_ID" 'set -Eeuo pipefail; printf "SSH administrator connection passed.\\n"'; then
    rm -rf -- "$dir"; note 'Server connection test failed; local configuration was removed.'; return 1
  fi
  note 'Server connection saved and tested. No storage, repository, or job was created.'
}

hp_resource_label() {
  local type=$1 id=$2
  case $type in
    server) load_controller_server "$id"; printf '%s — %s (%s)' "$SERVER_LABEL" "$BACKUP_HOST" "$id" ;;
    storage) load_controller_storage "$id"; printf '%s — %s (%s)' "$STORAGE_LABEL" "$REMOTE_MOUNTPOINT" "$id" ;;
    repository) load_controller_repository "$id"; printf '%s — %s (%s)' "$REPOSITORY_LABEL" "$REPOSITORY_SERVER_ID" "$id" ;;
    job) load_controller_job "$id"; printf '%s — %s (%s)' "$JOB_LABEL" "$JOB_REPOSITORY_ID" "$id" ;;
  esac
}

hp_select_resource() {
  local type=$1 dir=$2 suffix=$3 prompt=$4 ids=() entries=() id
  mapfile -t ids < <(hp_resource_ids "$dir" "$suffix")
  ((${#ids[@]})) || { note "No Restic ${type}s are configured."; return 1; }
  for id in "${ids[@]}"; do entries+=("$(hp_resource_label "$type" "$id")"); done
  choose_menu "$prompt" "${entries[@]}" 'Cancel'
  ((MENU_INDEX < ${#ids[@]})) || return 1
  HP_SELECTED_RESOURCE=${ids[$MENU_INDEX]}
}
select_server() { hp_select_resource server "$RESTIC_SERVERS_DIR" server.conf 'Select server connection'; }
select_storage() { hp_select_resource storage "$RESTIC_STORAGES_DIR" storage.conf 'Select remote storage'; }
select_repository() { hp_select_resource repository "$RESTIC_REPOSITORIES_DIR" repository.conf 'Select repository'; }
select_job() { hp_select_resource job "$RESTIC_JOBS_DIR" job.conf 'Select backup job'; }

hp_test_server() { remote_controller_exec "$1" 'set -Eeuo pipefail; test "$(id -u)" -eq 0; printf "SSH administrator connection passed.\n"'; }
hp_edit_server() {
  local id=$1 dir password
  load_controller_server "$id"; dir=$(hp_resource_dir server "$id")
  ask 'Display label' "$SERVER_LABEL"; SERVER_LABEL=$REPLY
  ask_host 'Backup server IP address or hostname' "$BACKUP_HOST"; BACKUP_HOST=$REPLY
  ask_name 'Administrator username' "$ADMIN_USER"; ADMIN_USER=$REPLY
  choose_menu 'Administrator credential' 'Keep current password' 'Replace password'
  if ((MENU_INDEX == 1)); then ask_secret 'New administrator password'; password=$REPLY; encrypt_controller_secret "$dir/admin-password.cred" "homephotos-${id}-admin" "$password"; unset password; fi
  write_controller_server_config; pin_controller_host_key "$id"; hp_test_server "$id"
}

hp_add_storage() {
  local mode=$1 server script output
  select_server || return; server=$HP_SELECTED_RESOURCE; load_controller_server "$server"
  ask_name 'Storage id' backup-disk; STORAGE_ID=$REPLY
  [[ ! -e $RESTIC_STORAGES_DIR/$STORAGE_ID ]] || die 'Storage id already exists.'
  ask 'Storage label' 'Backup disk'; STORAGE_LABEL=$REPLY
  ask_absolute_path 'Remote mount point' /mnt/photo-backup; REMOTE_MOUNTPOINT=$REPLY
  ask 'Remote block device' /dev/sdb1; STORAGE_DEVICE=$REPLY
  [[ $STORAGE_DEVICE =~ ^/dev/[A-Za-z0-9._/+:-]+$ ]] || die 'Invalid block device.'
  STORAGE_SERVER_ID=$server; STORAGE_KIND=direct
  case $mode in
    existing) MODE=existing; CONFIRMATION= ;;
    format) MODE=format; printf 'Type TYPE THE EXACT WHOLE DISK %s: ' "$STORAGE_DEVICE"; IFS= read -r CONFIRMATION; [[ $CONFIRMATION == "TYPE THE EXACT WHOLE DISK $STORAGE_DEVICE" ]] || die 'Confirmation did not match.' ;;
    lvm)
      ask_name 'Volume group' photo_backup; VG=$REPLY; ask_name 'Logical volume' restic; LV=$REPLY
      printf 'Type CREATE LVM %s/%s ON %s: ' "$VG" "$LV" "$STORAGE_DEVICE"; IFS= read -r LVM_CONFIRM
      script=$(printf 'DEVICE=%q\nVG=%q\nLV=%q\nLVM_CONFIRM=%q\n' "$STORAGE_DEVICE" "$VG" "$LV" "$LVM_CONFIRM"); script+=$'\n'; script+=$(hp_remote_storage_lvm_script)
      remote_controller_exec "$server" "$script"; STORAGE_DEVICE="/dev/$VG/$LV"; MODE=existing; STORAGE_KIND=lvm ;;
  esac
  script=$(printf 'DEVICE=%q\nMOUNTPOINT=%q\nMODE=%q\nCONFIRMATION=%q\n' "$STORAGE_DEVICE" "$REMOTE_MOUNTPOINT" "$MODE" "${CONFIRMATION:-}"); script+=$'\n'; script+=$(hp_remote_storage_direct_script)
  output=$(remote_controller_exec "$server" "$script"; remote_controller_exec "$server" "blkid -s UUID -o value '$STORAGE_DEVICE'")
  STORAGE_UUID=${output##*$'\n'}; [[ -n $STORAGE_UUID ]] || die 'Remote filesystem UUID was not returned.'
  write_controller_storage_config
}
hp_verify_storage() {
  local id=$1 script
  load_controller_storage "$id"
  script=$(printf 'MOUNTPOINT=%q\nEXPECTED=%q\n' "$REMOTE_MOUNTPOINT" "$STORAGE_UUID")
  script+=$'actual=$(findmnt -rn -M "$MOUNTPOINT" -o UUID); [[ -n $actual && $actual == "$EXPECTED" ]]\nprintf "Storage UUID verified: %s\\n" "$actual"\n'
  remote_controller_exec "$STORAGE_SERVER_ID" "$script"
}

hp_add_repository() {
  local password dir
  select_server || return; REPOSITORY_SERVER_ID=$HP_SELECTED_RESOURCE
  select_storage || return; REPOSITORY_STORAGE_ID=$HP_SELECTED_RESOURCE
  load_controller_storage "$REPOSITORY_STORAGE_ID"; [[ $STORAGE_SERVER_ID == "$REPOSITORY_SERVER_ID" ]] || die 'Storage belongs to a different server.'
  ask_name 'Repository id' family; REPOSITORY_ID=$REPLY; [[ ! -e $RESTIC_REPOSITORIES_DIR/$REPOSITORY_ID ]] || die 'Repository id already exists.'
  ask 'Repository label' 'Family photos'; REPOSITORY_LABEL=$REPLY; ask_name 'Restricted SFTP username' "restic_$REPOSITORY_ID"; SFTP_USER=$REPLY; ask_name 'Repository directory' "$REPOSITORY_ID"; REPOSITORY=$REPLY
  write_controller_repository_config; dir=$(hp_resource_dir repository "$REPOSITORY_ID")
  choose_menu 'Repository encryption password' 'Generate strong password' 'Enter password'
  if ((MENU_INDEX == 0)); then password=$(openssl rand -base64 36 | tr -d '\n'); else ask_secret 'Repository encryption password'; password=$REPLY; fi
  encrypt_controller_secret "$dir/repository-password.cred" "homephotos-${REPOSITORY_ID}-repository" "$password"; unset password
  if ! provision_controller_server "$REPOSITORY_ID" || ! restic_controller_command "$REPOSITORY_ID" init; then
    rm -rf -- "$dir"; note 'Repository setup failed; local repository configuration was removed.'; return 1
  fi
}
hp_test_repository() { restic_controller_command "$1" dry-run; }

hp_prompt_job_fields() {
  local source_input current=''
  [[ ${SOURCE_PATHS+x} ]] && current=$(source_paths_display)
  ask 'Job label' "${JOB_LABEL:-Photo backup}"; JOB_LABEL=$REPLY
  ask 'Source paths, comma-separated' "${current:-/mnt/photos}"; source_input=$REPLY; parse_source_paths "$source_input"
  ask_backup_time 'Daily backup time' "${BACKUP_TIME:-02:30}"; BACKUP_TIME=$REPLY; ask_backup_time 'Sunday maintenance time' "${MAINTENANCE_TIME:-03:30}"; MAINTENANCE_TIME=$REPLY
  ask_nonnegative_integer 'Daily snapshots' "${KEEP_DAILY:-7}"; KEEP_DAILY=$REPLY; ask_nonnegative_integer 'Weekly snapshots' "${KEEP_WEEKLY:-4}"; KEEP_WEEKLY=$REPLY
  ask_nonnegative_integer 'Monthly snapshots' "${KEEP_MONTHLY:-6}"; KEEP_MONTHLY=$REPLY; ask_nonnegative_integer 'Yearly snapshots' "${KEEP_YEARLY:-1}"; KEEP_YEARLY=$REPLY
  choose_menu 'Compression' 'Automatic' 'Maximum' 'Off'; case $MENU_INDEX in 0) COMPRESSION=auto;; 1) COMPRESSION=max;; *) COMPRESSION=off;; esac
  choose_menu 'Schedule' 'Enable' 'Disable'; ((MENU_INDEX == 0)) && ENABLED=yes || ENABLED=no
}
hp_add_job() { select_repository || return; JOB_REPOSITORY_ID=$HP_SELECTED_RESOURCE; ask_name 'Job id' nightly; JOB_ID=$REPLY; [[ ! -e $RESTIC_JOBS_DIR/$JOB_ID ]] || die 'Job id already exists.'; SOURCE_PATHS=(); hp_prompt_job_fields; write_controller_job_config; write_controller_jobs "$JOB_ID"; }
hp_edit_job() { local id=$1; load_controller_job "$id"; hp_prompt_job_fields; write_controller_job_config; write_controller_jobs "$id"; }

dry_run_controller_server() {
  local id=$1 path unit
  if [[ -f $RESTIC_JOBS_DIR/$id/job.conf ]]; then
    hp_resolve_job "$id"; hp_verify_storage "$REPOSITORY_STORAGE_ID"
    for path in "${SOURCE_PATHS[@]}"; do [[ -d $path ]] || die "Backup source does not exist: $path"; done
    for unit in homephotos-restic-job-${id}-{backup,maintenance}.{service,timer}; do systemctl cat "$unit" >/dev/null || die "Installed systemd unit is missing: $unit"; done
    restic_controller_command "$id" dry-run
  else
    load_controller_server "$id"; hp_test_server "$id"; restic_controller_command "$id" dry-run
  fi
}

hp_dry_run_all_jobs() { local id; while IFS= read -r id; do [[ -z $id ]] || dry_run_controller_server "$id"; done < <(hp_job_ids); }

hp_remote_block_inventory() {
  local server=$1 marker=$2 script
  script=$(printf '# %s\nMARKER=%q\n' "$marker" "$marker")
  script+=$'\n'
  script+=$'set -Eeuo pipefail\n'
  script+=$(cat <<'REMOTE_INVENTORY'
root_source=$(findmnt -rn -o SOURCE /)
root_disk=$(lsblk -s -nrpo NAME,TYPE "$root_source" | awk '$2 == "disk" { print $1; exit }')
while IFS= read -r line; do
  [[ $line =~ (^|[[:space:]])PATH=\"([^\"]*)\" ]] || continue
  path=${BASH_REMATCH[2]}
  [[ $line =~ (^|[[:space:]])TYPE=\"([^\"]*)\" ]] || continue
  type=${BASH_REMATCH[2]}
  case "$path:$type" in /dev/zram*:*|*:loop|*:rom|*:zram) continue;; esac
  if [[ -n $root_disk ]] && lsblk -s -nrpo NAME "$path" 2>/dev/null | grep -Fxq "$root_disk"; then
    continue
  fi
  if [[ $MARKER == HP_FORMAT_DISCOVERY ]]; then
    # Formatting is explicitly destructive. List every real whole disk except
    # the disk backing /, including disks with mounted partitions/filesystems.
    [[ $type == disk ]] || continue
  elif [[ $MARKER == HP_WHOLE_DISCOVERY ]]; then
    # LVM creation still requires a genuinely unused whole disk.
    [[ $type == disk ]] || continue
    [[ $(lsblk -nrpo TYPE "$path" | wc -l) -eq 1 ]] || continue
    [[ -z $(blkid "$path" 2>/dev/null) ]] || continue
  fi
  printf '%s\n' "$line"
done < <(lsblk -b -p -P -o PATH,TYPE,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT,UUID) | awk '
function value(key, line,    pattern,start,rest,end) {
  pattern=key "=\""; start=index(line,pattern); if (!start) return "";
  rest=substr(line,start+length(pattern)); end=index(rest,"\""); return substr(rest,1,end-1)
}
{ printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", value("PATH",$0),value("TYPE",$0),value("SIZE",$0),value("MODEL",$0),value("SERIAL",$0),value("FSTYPE",$0),value("MOUNTPOINT",$0),value("UUID",$0) }'
REMOTE_INVENTORY
)
  remote_controller_exec "$server" "$script"
}

hp_human_size() {
  local bytes=$1
  if [[ $bytes =~ ^[0-9]+$ ]]; then numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%sB' "$bytes"; else printf '%s' "$bytes"; fi
}

hp_list_remote_drives() {
  local server=$1 path type size model serial fstype mountpoint uuid
  printf 'Device\tType\tSize\tModel\tSerial\tFilesystem\tMount\tUUID\n'
  while IFS=$'\t' read -r path type size model serial fstype mountpoint uuid; do
    [[ -n $path ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$type" "$(hp_human_size "$size")" "${model:--}" "${serial:--}" "${fstype:--}" "${mountpoint:--}" "${uuid:--}"
  done < <(hp_remote_block_inventory "$server" HP_DRIVE_DISCOVERY)
}

hp_select_remote_block() {
  local server=$1 purpose=$2 line path type size model serial fstype mountpoint uuid marker=HP_DRIVE_DISCOVERY
  local paths=() types=() sizes=() models=() serials=() fstypes=() mounts=() uuids=() entries=()
  [[ $purpose != format ]] || marker=HP_FORMAT_DISCOVERY
  [[ $purpose != whole ]] || marker=HP_WHOLE_DISCOVERY
  [[ $purpose != filesystem ]] || marker=HP_PARTITION_DISCOVERY
  [[ $purpose != lvm ]] || marker=HP_LVM_DISCOVERY
  [[ $purpose != mounted ]] || marker=HP_MOUNTED_DISCOVERY
  while IFS= read -r line; do
    IFS='|' read -r path type size model serial fstype mountpoint uuid <<< "${line//$'\t'/|}"
    [[ -n $path ]] || continue
    case $purpose in
      format) [[ $type == disk && -z $fstype && -z $mountpoint ]] || continue;;
      filesystem) [[ ( $type == part || $type == lvm ) && -n $fstype ]] || continue;;
      lvm) [[ $type == lvm ]] || continue;;
      whole) [[ $type == disk && -z $fstype && -z $mountpoint ]] || continue;;
      mounted) [[ -n $fstype && $mountpoint == /* && $mountpoint != / ]] || continue;;
    esac
    paths+=("$path"); types+=("$type"); sizes+=("$size"); models+=("$model"); serials+=("$serial"); fstypes+=("$fstype"); mounts+=("$mountpoint"); uuids+=("$uuid")
    entries+=("$path — $(hp_human_size "$size") — ${model:--} — serial ${serial:--} — ${fstype:-unused whole drive}${mountpoint:+ — mounted $mountpoint}${uuid:+ — UUID $uuid}")
  done < <(hp_remote_block_inventory "$server" "$marker")
  ((${#paths[@]})) || { note "No eligible remote $purpose devices found."; return 1; }
  choose_menu "Select remote $purpose device" "${entries[@]}" 'Cancel'
  ((MENU_INDEX < ${#paths[@]})) || return 1
  HP_SELECTED_DEVICE=${paths[$MENU_INDEX]}; HP_SELECTED_TYPE=${types[$MENU_INDEX]}; HP_SELECTED_FSTYPE=${fstypes[$MENU_INDEX]}; HP_SELECTED_MOUNT=${mounts[$MENU_INDEX]}; HP_SELECTED_UUID=${uuids[$MENU_INDEX]}
}

hp_confirm_exact_device() {
  local device=$1 answer
  printf 'Type the exact device path %s to continue: ' "$device"
  IFS= read -r answer
  [[ $answer == "$device" ]] || { note 'Exact device confirmation did not match.'; return 1; }
}

hp_remote_format_script() { cat <<'REMOTE'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
missing_packages=()
command -v parted >/dev/null 2>&1 || missing_packages+=(parted)
command -v partprobe >/dev/null 2>&1 || missing_packages+=(parted)
command -v mkfs.ext4 >/dev/null 2>&1 || missing_packages+=(e2fsprogs)
command -v fuser >/dev/null 2>&1 || missing_packages+=(psmisc)
if ((${#missing_packages[@]})); then
  command -v apt-get >/dev/null 2>&1 || { printf 'Missing required packages: %s. apt-get is unavailable on the remote server.\n' "${missing_packages[*]}" >&2; exit 1; }
  apt-get update
  apt-get install -y "${missing_packages[@]}"
fi
[[ $DEVICE == "$CONFIRM_DEVICE" && $DEVICE == /dev/* ]]
[[ $(lsblk -dnro TYPE "$DEVICE") == disk ]]
root_source=$(findmnt -rn -o SOURCE /); root_chain=$(lsblk -s -nrpo NAME "$root_source")
! grep -Fxq "$DEVICE" <<< "$root_chain"
# Reinitialization is allowed for a confirmed non-root disk, including mounted
# partitions. Stop users and unmount every descendant before wiping signatures.
mapfile -t mounted_points < <(lsblk -nrpo MOUNTPOINT "$DEVICE" | awk 'NF && $1 != "/" {print length($1) "\t" $1}' | sort -rn | cut -f2-)
for mountpoint in "${mounted_points[@]}"; do
  [[ -n $mountpoint && $mountpoint != / ]] || continue
  fuser -km -- "$mountpoint" 2>/dev/null || true
  umount -- "$mountpoint" 2>/dev/null || umount -l -- "$mountpoint"
done
[[ -z $(lsblk -nr -o MOUNTPOINTS "$DEVICE" | tr -d '[:space:]') ]]
wipefs -a "$DEVICE"
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary ext4 1MiB 100%
partprobe "$DEVICE"; udevadm settle
partition=''
for attempt in 1 2 3 4 5; do
  partition=$(lsblk -nrpo PATH,PKNAME,TYPE | awk -v d="$DEVICE" '$2==d && $3=="part" {print $1; exit}')
  [[ -n $partition && -b $partition ]] && break
  udevadm settle; sleep 1
done
[[ -n $partition && -b $partition ]] || { printf 'The new partition did not appear for %s.\n' "$DEVICE" >&2; exit 1; }
mkfs.ext4 -F "$partition"
uuid=$(blkid -s UUID -o value "$partition")
[[ -n $uuid ]] || { printf 'The new ext4 filesystem has no UUID.\n' >&2; exit 1; }
printf 'Created ext4 partition %s UUID %s\n' "$partition" "$uuid"
REMOTE
}

hp_format_remote_drive() {
  local server=$1 script
  hp_select_remote_block "$server" format || return
  confirm 'Format and create ext4 partition on this drive?' || return
  hp_confirm_exact_device "$HP_SELECTED_DEVICE" || return
  confirm "FINAL WARNING: unmount and permanently erase all data on $HP_SELECTED_DEVICE?" || return
  script=$(printf 'DEVICE=%q\nCONFIRM_DEVICE=%q\n' "$HP_SELECTED_DEVICE" "$HP_SELECTED_DEVICE"); script+=$'\n'; script+=$(hp_remote_format_script)
  remote_controller_exec "$server" "$script"
}

hp_remote_mount_script() { cat <<'REMOTE'
set -Eeuo pipefail
[[ $DEVICE == /dev/* && $MOUNTPOINT == /* && $MOUNTPOINT != / && $MOUNTPOINT != *..* ]]
test -b "$DEVICE"
uuid=$(blkid -s UUID -o value "$DEVICE"); fstype=$(blkid -s TYPE -o value "$DEVICE")
[[ -n $uuid && -n $fstype ]]
mkdir -p "$MOUNTPOINT"; exec 9>/etc/fstab.homephotos.lock; flock -x 9
tmp=$(mktemp /etc/fstab.homephotos.XXXXXX); trap 'rm -f "$tmp"' EXIT
cp -p /etc/fstab "$tmp"
awk -v u="UUID=$uuid" -v m="$MOUNTPOINT" '$1 != u && $2 != m {print}' /etc/fstab > "$tmp"
printf 'UUID=%s %s %s defaults,nofail,x-systemd.device-timeout=10s 0 2\n' "$uuid" "$MOUNTPOINT" "$fstype" >> "$tmp"
mountpoint -q "$MOUNTPOINT" && umount "$MOUNTPOINT"
install -m 0644 "$tmp" /etc/fstab; systemctl daemon-reload; mount "$MOUNTPOINT"
actual=$(findmnt -rn -M "$MOUNTPOINT" -o UUID); [[ $actual == "$uuid" ]]
printf 'HP_MOUNT_RESULT\t%s\t%s\t%s\n' "$uuid" "$DEVICE" "$MOUNTPOINT"
REMOTE
}

hp_register_storage_result() {
  local server=$1 kind=$2 device=$3 uuid=$4 mountpoint=$5
  ask_name 'Storage id' backup-storage; STORAGE_ID=$REPLY
  [[ ! -e $RESTIC_STORAGES_DIR/$STORAGE_ID ]] || die "Storage id already exists: $STORAGE_ID"
  ask 'Storage label' 'Restic storage'; STORAGE_LABEL=$REPLY
  STORAGE_SERVER_ID=$server STORAGE_KIND=$kind STORAGE_DEVICE=$device STORAGE_UUID=$uuid REMOTE_MOUNTPOINT=$mountpoint
  write_controller_storage_config
}

hp_mount_and_register_device() {
  local server=$1 kind=$2 device=$3 default_mount=${4:-/mnt/restic} script line uuid mounted_device mountpoint
  ask_absolute_path 'Desired absolute mount point' "$default_mount"; mountpoint=$REPLY
  script=$(printf 'DEVICE=%q\nMOUNTPOINT=%q\n' "$device" "$mountpoint"); script+=$'\n'; script+=$(hp_remote_mount_script)
  uuid=; mounted_device=
  while IFS= read -r line; do
    [[ $line == HP_MOUNT_RESULT$'\t'* ]] && IFS=$'\t' read -r _ uuid mounted_device mountpoint <<< "$line"
  done < <(remote_controller_exec "$server" "$script")
  [[ -n $uuid && $mounted_device == "$device" && -n $mountpoint ]] || die 'Remote mount completed without verified UUID result.'
  hp_register_storage_result "$server" "$kind" "$mounted_device" "$uuid" "$mountpoint"
}

hp_mount_remote_partition() {
  local server=$1 kind=direct
  hp_select_remote_block "$server" filesystem || return
  [[ $HP_SELECTED_TYPE != lvm ]] || kind=lvm
  hp_mount_and_register_device "$server" "$kind" "$HP_SELECTED_DEVICE"
}

hp_remote_format_lvm_script() { cat <<'REMOTE'
set -Eeuo pipefail
[[ $DEVICE == "$CONFIRM_DEVICE" && $DEVICE == /dev/* ]]
[[ $(lsblk -dnro TYPE "$DEVICE") == lvm ]]
[[ -z $(lsblk -dnro FSTYPE "$DEVICE") ]]
[[ -z $(findmnt -rn -S "$DEVICE") ]]
mkfs.ext4 -F "$DEVICE"
uuid=$(blkid -s UUID -o value "$DEVICE")
[[ -n $uuid ]]
printf 'HP_LVM_FORMAT_RESULT\t%s\t%s\n' "$uuid" "$DEVICE"
REMOTE
}

hp_register_lvm_storage() {
  local server=$1 script line uuid formatted_device
  hp_select_remote_block "$server" lvm || return
  if [[ -z $HP_SELECTED_FSTYPE ]]; then
    choose_menu 'Format selected LVM logical volume as ext4?' 'Format as ext4' 'Cancel'
    ((MENU_INDEX == 0)) || return
    hp_confirm_exact_device "$HP_SELECTED_DEVICE" || return
    script=$(printf 'DEVICE=%q\nCONFIRM_DEVICE=%q\n' "$HP_SELECTED_DEVICE" "$HP_SELECTED_DEVICE"); script+=$'\n'; script+=$(hp_remote_format_lvm_script)
    while IFS= read -r line; do
      [[ $line == HP_LVM_FORMAT_RESULT$'\t'* ]] && IFS=$'\t' read -r _ uuid formatted_device <<< "$line"
    done < <(remote_controller_exec "$server" "$script")
    [[ -n $uuid && $formatted_device == "$HP_SELECTED_DEVICE" ]] || die 'LVM format completed without a verified UUID.'
  fi
  hp_mount_and_register_device "$server" lvm "$HP_SELECTED_DEVICE" /mnt/restic-lvm
}

hp_select_multiple_remote_blocks() {
  local server=$1 purpose=$2 minimum=$3 selected=() selected_mounts=() device
  while :; do
    hp_select_remote_block "$server" "$purpose" || break
    device=$HP_SELECTED_DEVICE
    if [[ " ${selected[*]} " == *" $device "* ]]; then note "$device is already selected."; continue; fi
    selected+=("$device"); selected_mounts+=("${HP_SELECTED_MOUNT:-}")
    choose_menu "Selected: ${selected[*]}" 'Add another' 'Finish selection'
    ((MENU_INDEX == 0)) || break
  done
  ((${#selected[@]} >= minimum)) || { note "Select at least $minimum devices."; return 1; }
  HP_SELECTED_DEVICES=("${selected[@]}"); HP_SELECTED_MOUNTS=("${selected_mounts[@]}")
}

hp_confirm_phrase() {
  local prompt=$1 expected=$2 answer
  printf '%s\nType exactly: %s\n> ' "$prompt" "$expected"; IFS= read -r answer
  [[ $answer == "$expected" ]] || { note 'Confirmation did not match.'; return 1; }
}

hp_create_remote_lvm() {
  local server=$1 vg lv phrase script quoted_devices
  hp_select_multiple_remote_blocks "$server" whole 2 || return
  ask_name 'LVM volume group' photos_vg; vg=$REPLY
  ask_name 'LVM logical volume' restic; lv=$REPLY
  phrase="CREATE LVM $vg/$lv ON ${HP_SELECTED_DEVICES[*]}"
  hp_confirm_phrase 'This erases every selected whole drive.' "$phrase" || return
  printf -v quoted_devices ' %q' "${HP_SELECTED_DEVICES[@]}"
  script=$(printf 'VG=%q\nLV=%q\nEXPECTED=%q\nCONFIRMATION=%q\nDEVICES=(%s )\n' "$vg" "$lv" "$phrase" "$phrase" "$quoted_devices"); script+=$'\n'
  script+=$'set -Eeuo pipefail\n[[ $CONFIRMATION == "$EXPECTED" && ${#DEVICES[@]} -ge 2 ]]\nroot_source=$(findmnt -rn -o SOURCE /); root_chain=$(lsblk -s -nrpo NAME "$root_source")\nfor d in "${DEVICES[@]}"; do [[ $d == /dev/* && $(lsblk -dnro TYPE "$d") == disk ]]; ! grep -Fxq "$d" <<< "$root_chain"; [[ -z $(lsblk -nr -o MOUNTPOINT "$d" | tr -d "[:space:]") ]]; done\napt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y lvm2 e2fsprogs\n'
  script+="pvcreate --$quoted_devices"$'\n'
  script+="vgcreate -- $(printf '%q' "$vg")$quoted_devices"$'\n'
  script+=$(printf 'lvcreate -l 100%%FREE -n %q %q\nmkfs.ext4 -F %q\n' "$lv" "$vg" "/dev/$vg/$lv")
  remote_controller_exec "$server" "$script" || return
  choose_menu 'LVM logical volume created and formatted.' 'Set mount point and register for Restic' 'Return without registering'
  ((MENU_INDEX == 0)) && hp_mount_and_register_device "$server" lvm "/dev/$vg/$lv" /mnt/restic-lvm
}

hp_select_mergerfs_sources() {
  local server=$1 device mountpoint script line uuid mounted_device source_count=0
  local source_devices=() source_mounts=()
  while :; do
    hp_select_remote_block "$server" filesystem || return 1
    device=$HP_SELECTED_DEVICE; mountpoint=$HP_SELECTED_MOUNT
    if [[ " ${source_devices[*]} " == *" $device "* ]]; then note "$device is already selected."; continue; fi
    if [[ -z $mountpoint ]]; then
      ask_absolute_path "Mount point for $device" "/mnt/restic-source-$source_count"; mountpoint=$REPLY
      script=$(printf 'DEVICE=%q\nMOUNTPOINT=%q\n' "$device" "$mountpoint"); script+=$'\n'; script+=$(hp_remote_mount_script)
      uuid=; mounted_device=
      while IFS= read -r line; do
        [[ $line == HP_MOUNT_RESULT$'\t'* ]] && IFS=$'\t' read -r _ uuid mounted_device mountpoint <<< "$line"
      done < <(remote_controller_exec "$server" "$script")
      [[ -n $uuid && $mounted_device == "$device" && -n $mountpoint ]] || die "Could not mount and verify mergerfs source $device."
    fi
    source_devices+=("$device"); source_mounts+=("$mountpoint"); source_count=$((source_count + 1))
    choose_menu "Selected mergerfs sources ($source_count): ${source_mounts[*]}" 'Add another' 'Finish selection'
    ((MENU_INDEX == 0)) || break
  done
  ((source_count >= 2)) || { note "Select at least 2 filesystems for mergerfs (selected: $source_count)."; return 1; }
  HP_SELECTED_DEVICES=("${source_devices[@]}"); HP_SELECTED_MOUNTS=("${source_mounts[@]}")
}

hp_remote_mergerfs_script() { cat <<'REMOTE'
set -Eeuo pipefail
[[ $CONFIRMATION == "$EXPECTED" && $SOURCES == *:* && $POOL == /* && $POOL != / ]]
echo 'mergerfs does not make one Restic repository failure-independent' >&2
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y mergerfs
mkdir -p "$POOL"
exec 9>/etc/fstab.homephotos.lock
flock -x 9
tmp=$(mktemp /etc/fstab.homephotos.XXXXXX)
trap 'rm -f "$tmp"' EXIT
awk -v m="$POOL" '$2 != m {print}' /etc/fstab > "$tmp"
printf '%s %s fuse.mergerfs defaults,nofail,allow_other,use_ino,category.create=mfs 0 0\n' "$SOURCES" "$POOL" >> "$tmp"
install -m 0644 "$tmp" /etc/fstab
systemctl daemon-reload
mount "$POOL"
findmnt -rn -M "$POOL" >/dev/null
REMOTE
}

hp_create_remote_mergerfs() {
  local server=$1 pool sources phrase script
  hp_select_mergerfs_sources "$server" || return
  ask_absolute_path 'mergerfs pool absolute mount point' /mnt/restic-pool; pool=$REPLY
  sources=$(IFS=:; printf '%s' "${HP_SELECTED_MOUNTS[*]}")
  phrase="CREATE MERGERFS $pool FROM $sources"
  hp_confirm_phrase 'mergerfs does not make one Restic repository failure-independent; loss of a source can damage that repository.' "$phrase" || return
  script=$(printf 'SOURCES=%q\nPOOL=%q\nEXPECTED=%q\nCONFIRMATION=%q\n' "$sources" "$pool" "$phrase" "$phrase")
  script+=$'\n'; script+=$(hp_remote_mergerfs_script)
  remote_controller_exec "$server" "$script"
}

hp_register_existing_mergerfs() {
  local server=$1 pool line kind mountpoint identity script
  ask_absolute_path 'Existing mergerfs pool mount point' /mnt/restic-pool; pool=$REPLY
  script=$(printf 'POOL=%q\n' "$pool"); script+=$'\n'
  script+=$'set -Eeuo pipefail\n[[ $POOL == /* && $POOL != / ]]\nfindmnt -rn -M "$POOL" -t fuse.mergerfs >/dev/null\nsources=$(findmnt -rn -M "$POOL" -o SOURCE)\n[[ $sources == *:* ]]\nprintf "HP_POOL_RESULT\\tmergerfs\\t%s\\t%s\\n" "$POOL" "$sources"\n'
  while IFS= read -r line; do
    [[ $line == HP_POOL_RESULT$'\t'* ]] && IFS=$'\t' read -r _ kind mountpoint identity <<< "$line"
  done < <(remote_controller_exec "$server" "$script")
  [[ $kind == mergerfs && -n $identity ]] || die 'Remote mergerfs pool verification failed.'
  hp_register_storage_result "$server" mergerfs "$identity" "mergerfs:$identity" "$mountpoint"
}

hp_mount_remote_merged_storage() {
  local server=$1
  choose_menu 'Register merged storage type' 'LVM logical volume' 'mergerfs pool' 'Cancel'
  case $MENU_INDEX in
    0) hp_mount_remote_partition "$server";;
    1) hp_register_existing_mergerfs "$server";;
    *) return;;
  esac
}

hp_add_storage_registration() {
  local server
  select_server || return; server=$HP_SELECTED_RESOURCE
  choose_menu 'Register Restic backup storage type' 'Direct partition' 'LVM logical volume' 'Existing mergerfs pool' 'Cancel'
  case $MENU_INDEX in
    0) hp_mount_remote_partition "$server";;
    1) hp_register_lvm_storage "$server";;
    2) hp_register_existing_mergerfs "$server";;
    *) return;;
  esac
}
hp_update_storage_registration() {
  local id=$1
  load_controller_storage "$id"
  ask 'Storage label' "$STORAGE_LABEL"; STORAGE_LABEL=$REPLY
  ask_absolute_path 'Registered mount point' "$REMOTE_MOUNTPOINT"; REMOTE_MOUNTPOINT=$REPLY
  write_controller_storage_config
}
hp_storage_registration_label() {
  load_controller_storage "$1"
  printf '%s — server %s — %s — %s — UUID %s — %s (%s)' "$STORAGE_LABEL" "$STORAGE_SERVER_ID" "$STORAGE_KIND" "$STORAGE_DEVICE" "$STORAGE_UUID" "$REMOTE_MOUNTPOINT" "$STORAGE_ID"
}
hp_restic_storage_registrations_menu() {
  local id ids=() labels=()
  while :; do
    mapfile -t ids < <(hp_resource_ids "$RESTIC_STORAGES_DIR" storage.conf); labels=()
    for id in "${ids[@]}"; do labels+=("$(hp_storage_registration_label "$id")"); done
    choose_menu 'Restic backup registration management' "${labels[@]}" 'Add registration' 'Update registration' 'Delete registration (dependency-safe; keep data)' 'Back'
    case $MENU_INDEX in
      0) ((${#ids[@]})) && : || hp_action hp_add_storage_registration;;
      *)
        # Resource rows are informational and deliberately selectable; actions remain fixed after them.
        if ((MENU_INDEX < ${#ids[@]})); then continue; fi
        case $((MENU_INDEX-${#ids[@]})) in
          0) hp_action hp_add_storage_registration;;
          1) select_storage && { id=$HP_SELECTED_RESOURCE; hp_action hp_update_storage_registration "$id"; };;
          2) select_storage && { id=$HP_SELECTED_RESOURCE; hp_action hp_delete_storage "$id"; };;
          *) return;;
        esac;;
    esac
  done
}

hp_restic_servers_menu() { local id; while :; do choose_menu 'Restic · Server connections' 'Add/test server connection' 'Edit/pin/test connection' 'Test connection' 'Delete server (dependencies required)' 'Back'; case $MENU_INDEX in 0) hp_action add_controller_server;; 1) select_server && { id=$HP_SELECTED_RESOURCE; hp_action hp_edit_server "$id"; };; 2) select_server && { id=$HP_SELECTED_RESOURCE; hp_action hp_test_server "$id"; };; 3) select_server && { id=$HP_SELECTED_RESOURCE; hp_action hp_delete_server "$id"; };; *) return;; esac; done; }
hp_restic_drives_menu() {
  local server=$1
  while :; do
    choose_menu "Drives management — $server" 'List drives' 'Format drive' 'Set mount point for partition' 'Back'
    case $MENU_INDEX in
      0) hp_action hp_list_remote_drives "$server";;
      1) hp_action hp_format_remote_drive "$server";;
      2) hp_action hp_mount_remote_partition "$server";;
      *) return;;
    esac
  done
}

hp_restic_drive_merging_menu() {
  local server=$1
  while :; do
    choose_menu "Drives merging management — $server" 'LVM' 'mergerfs' 'Set mount point' 'Back'
    case $MENU_INDEX in
      0) hp_action hp_create_remote_lvm "$server";;
      1) hp_action hp_create_remote_mergerfs "$server";;
      2) hp_action hp_mount_remote_merged_storage "$server";;
      *) return;;
    esac
  done
}

hp_restic_storages_menu() {
  local server
  while :; do
    choose_menu 'Restic · Remote storage' 'Drives management' 'Drives merging management' 'Restic backup registration management' 'Back'
    case $MENU_INDEX in
      0) select_server && { server=$HP_SELECTED_RESOURCE; hp_restic_drives_menu "$server"; };;
      1) select_server && { server=$HP_SELECTED_RESOURCE; hp_restic_drive_merging_menu "$server"; };;
      2) hp_restic_storage_registrations_menu;;
      *) return;;
    esac
  done
}
hp_restic_repositories_menu() { local id; while :; do choose_menu 'Restic · Repositories' 'Create restricted SFTP repository' 'Test repository access' 'Show recovery credentials' 'Delete access (keep remote data)' 'Back'; case $MENU_INDEX in 0) hp_action hp_add_repository;; 1) select_repository && { id=$HP_SELECTED_RESOURCE; hp_action hp_test_repository "$id"; };; 2) select_repository && { id=$HP_SELECTED_RESOURCE; hp_action show_controller_recovery_credentials "$id"; };; 3) select_repository && { id=$HP_SELECTED_RESOURCE; hp_action hp_delete_repository "$id"; };; *) return;; esac; done; }
hp_run_job_background() {
  local id=$1 unit="homephotos-restic-job-${1}-backup.service"
  load_controller_job "$id"
  ((${#SOURCE_PATHS[@]} > 0)) || die 'Backup job has no source paths configured. Edit the job and add at least one source before running it.'
  write_controller_jobs "$id"
  systemctl start --no-block "$unit"
  note "Backup job '$id' is running in the background. Check it with: systemctl status $unit"
}

hp_view_job_background() {
  local id=$1 unit="homephotos-restic-job-${1}-backup.service"
  load_controller_job "$id"
  printf '\nBackground backup status — %s (%s)\n\n' "$JOB_LABEL" "$id"
  systemctl show "$unit" \
    --property=Id,ActiveState,SubState,Result,ExecMainStatus,ExecMainStartTimestamp,ExecMainExitTimestamp \
    --no-pager
  printf '\nRecent output (last 50 lines)\n\n'
  journalctl -u "$unit" -n 50 --no-pager
  printf '\nFollow live output from a terminal:\n  journalctl -fu %s\n' "$unit"
}

hp_running_job_ids() {
  local id unit
  while IFS= read -r id; do
    unit="homephotos-restic-job-${id}-backup.service"
    systemctl is-active --quiet "$unit" && printf '%s\n' "$id"
  done < <(hp_job_ids)
}

hp_select_running_job() {
  local ids=() entries=() id
  mapfile -t ids < <(hp_running_job_ids)
  ((${#ids[@]})) || { note 'No backup task is currently running.'; return 1; }
  for id in "${ids[@]}"; do entries+=("$(hp_resource_label job "$id")"); done
  choose_menu 'Select running backup task' "${entries[@]}" 'Cancel'
  ((MENU_INDEX < ${#ids[@]})) || return 1
  HP_SELECTED_RESOURCE=${ids[$MENU_INDEX]}
}

hp_stop_job_background() {
  local id=$1 unit="homephotos-restic-job-${1}-backup.service"
  systemctl is-active --quiet "$unit" || die "Backup job '$id' is not running."
  systemctl stop "$unit"
  note "Backup job '$id' stopped. Its schedule remains enabled."
}

hp_restic_jobs_menu() {
  local id running
  while :; do
    running=$(hp_running_job_ids)
    if [[ -n $running ]]; then
      choose_menu 'Restic · Backup jobs and settings' 'Add job' 'Edit sources/schedule/maintenance/retention/compression/enabled' 'Run backup now' 'Run backup now in background' 'View background backup task' 'Stop running backup task' 'View snapshots' 'Delete job' 'Back'
      case $MENU_INDEX in
        0) hp_action hp_add_job;;
        1) select_job && { id=$HP_SELECTED_RESOURCE; hp_action hp_edit_job "$id"; };;
        2) select_job && { id=$HP_SELECTED_RESOURCE; hp_action restic_controller_command "$id" backup; };;
        3) select_job && { id=$HP_SELECTED_RESOURCE; hp_action hp_run_job_background "$id"; };;
        4) select_job && { id=$HP_SELECTED_RESOURCE; hp_action hp_view_job_background "$id"; };;
        5) hp_select_running_job && { id=$HP_SELECTED_RESOURCE; hp_action hp_stop_job_background "$id"; };;
        6) select_job && { id=$HP_SELECTED_RESOURCE; hp_action restic_controller_command "$id" snapshots; };;
        7) select_job && { id=$HP_SELECTED_RESOURCE; hp_action hp_delete_job "$id"; };;
        *) return;;
      esac
    else
      choose_menu 'Restic · Backup jobs and settings' 'Add job' 'Edit sources/schedule/maintenance/retention/compression/enabled' 'Run backup now' 'Run backup now in background' 'View background backup task' 'View snapshots' 'Delete job' 'Back'
      case $MENU_INDEX in
        0) hp_action hp_add_job;;
        1) select_job && { id=$HP_SELECTED_RESOURCE; hp_action hp_edit_job "$id"; };;
        2) select_job && { id=$HP_SELECTED_RESOURCE; hp_action restic_controller_command "$id" backup; };;
        3) select_job && { id=$HP_SELECTED_RESOURCE; hp_action hp_run_job_background "$id"; };;
        4) select_job && { id=$HP_SELECTED_RESOURCE; hp_action hp_view_job_background "$id"; };;
        5) select_job && { id=$HP_SELECTED_RESOURCE; hp_action restic_controller_command "$id" snapshots; };;
        6) select_job && { id=$HP_SELECTED_RESOURCE; hp_action hp_delete_job "$id"; };;
        *) return;;
      esac
    fi
  done
}
restic_controller_menu() { hp_restic_init; while :; do choose_menu 'Restic resource management' 'Server connections' 'Remote storage' 'Repositories' 'Backup jobs/settings' 'Dry-run all jobs' 'Migrate legacy combined profile' 'Back'; case $MENU_INDEX in 0) hp_restic_servers_menu;; 1) hp_restic_storages_menu;; 2) hp_restic_repositories_menu;; 3) hp_restic_jobs_menu;; 4) hp_action hp_dry_run_all_jobs;; 5) ask_name 'Legacy profile id' old; hp_action hp_migrate_legacy_profile "$REPLY";; *) return;; esac; done; }

# Keeping the functions sourceable makes it possible to test hardware-detection
# helpers without starting the interactive installer.
if [ "${PHOTOSYNC_SETUP_LIBRARY:-0}" != 1 ]; then
  main "$@"
fi
