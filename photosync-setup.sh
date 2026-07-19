#!/usr/bin/env bash
# Interactive setup for a small Debian photo-sync primary or backup server.
# Intended for a local terminal, run as root.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME=${0##*/}
FSTAB=/etc/fstab
SMB_CONF=/etc/samba/smb.conf
SMB_MANAGED_CONF=/etc/samba/photosync-setup.conf
RESTIC_CONTROLLER_DIR=/etc/photosync-restic-controller
RESTIC_SERVERS_DIR=$RESTIC_CONTROLLER_DIR/servers
RESTIC_ARCHIVE_DIR=/var/backups/photosync-restic-controller
RESTIC_CONTROLLER_KEY=/root/.ssh/photosync-restic-controller-ed25519
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
  [ "${#options[@]}" -gt 0 ] || die "Internal error: menu has no choices."

  while :; do
    printf '\033[2J\033[H'
    printf '%s\n\n' "$title"
    printf 'Use Up/Down arrows, then Enter.\n\n'
    for i in "${!options[@]}"; do
      marker=' '
      [ "$i" -eq "$selected" ] && marker='>'
      printf ' %s %s\n' "$marker" "${options[$i]}"
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

format_ext4_disk() {
  local disk=$1 label=$2
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
  [[ $mountpoint = /* && $mountpoint != / ]] || die "Mount point must be an absolute path other than /."
  uuid=$(blkid -s UUID -o value "$device")
  fstype=$(blkid -s TYPE -o value "$device")
  [ -n "$uuid" ] && [ -n "$fstype" ] || die "Could not read filesystem UUID/type from $device."
  [ "$fstype" = ext4 ] || die "This script currently mounts only ext4 filesystems for server storage."

  if findmnt -rn --target "$mountpoint" >/dev/null; then
    local current_source
    current_source=$(findmnt -nr -o SOURCE --target "$mountpoint")
    [ "$current_source" = "$device" ] || die "$mountpoint is already mounted from $current_source."
    MOUNTPOINT=$mountpoint
    return 0
  fi

  if grep -Eq "^[[:space:]]*UUID=[^[:space:]]+[[:space:]]+$mountpoint[[:space:]]" "$FSTAB"; then
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
  findmnt -rn --target "$mountpoint" >/dev/null || die "Failed to mount $mountpoint."
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
  command_exists systemd-creds || die 'systemd-creds is required to encrypt stored administrator and repository passwords.'
  install -d -m 0700 -o root -g root "$RESTIC_CONTROLLER_DIR" "$RESTIC_SERVERS_DIR" "$RESTIC_ARCHIVE_DIR" /root/.ssh
  if [ ! -f "$RESTIC_CONTROLLER_KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$RESTIC_CONTROLLER_KEY"
    note "Created controller SSH key: ${RESTIC_CONTROLLER_KEY}.pub"
  fi
  install -m 0700 -o root -g root "$(readlink -f "$0")" "$RESTIC_INSTALL_PATH"
}

controller_server_dir() {
  valid_name "$1" || die "Invalid Restic server id: $1"
  printf '%s/%s\n' "$RESTIC_SERVERS_DIR" "$1"
}

encrypt_controller_secret() {
  local output=$1 credential_name=$2 secret=$3 temp
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
  systemd-creds decrypt "$path" - 2>/dev/null
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
  while IFS= read -r item; do
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
  SOURCE_PATHS=()
  # Root-owned controller profiles are executable shell assignments so arrays
  # and paths containing spaces remain lossless.
  # shellcheck disable=SC1090
  . "$dir/server.conf"
}

controller_server_ids() {
  local config
  [ -d "$RESTIC_SERVERS_DIR" ] || return 0
  for config in "$RESTIC_SERVERS_DIR"/*/server.conf; do
    [ -f "$config" ] || continue
    basename "$(dirname "$config")"
  done | sort
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
    -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$dir/known_hosts" \
    "$target" "printf '%s' '$encoded' | base64 -d | bash"
  status=$?
  set -e
  unset admin_password
  return "$status"
}

provision_controller_server() {
  local id=$1 public_key_b64 remote_script
  load_controller_server "$id"
  public_key_b64=$(base64 -w 0 "${RESTIC_CONTROLLER_KEY}.pub")
  remote_script=$(printf 'SERVER_ID=%q\nSFTP_USER=%q\nMOUNTPOINT=%q\nREPOSITORY=%q\nPUBLIC_KEY_B64=%q\n' \
    "$SERVER_ID" "$SFTP_USER" "$REMOTE_MOUNTPOINT" "$REPOSITORY" "$public_key_b64")
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
  remote_controller_exec "$id" "$remote_script" || die "Remote provisioning failed for $id."
}

restic_controller_command() {
  local id=$1 action=$2 dir repository_url password_command sftp_command
  shift 2
  load_controller_server "$id"
  dir=$(controller_server_dir "$id")
  repository_url="sftp:${SFTP_USER}@${BACKUP_HOST}:/${REPOSITORY}"
  password_command="systemd-creds decrypt '$dir/repository-password.cred' -"
  # Restic tokenizes sftp.command itself. Attach each -o value so an option
  # cannot be separated from its argument by that tokenizer.
  sftp_command="ssh -i $RESTIC_CONTROLLER_KEY -oBatchMode=yes -oConnectTimeout=15 -oStrictHostKeyChecking=yes -oUserKnownHostsFile=$dir/known_hosts ${SFTP_USER}@${BACKUP_HOST} -s sftp"
  case "$action" in
    init)
      restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" cat config >/dev/null 2>&1 || \
        restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" init
      ;;
    backup)
      restic -r "$repository_url" --password-command "$password_command" -o "sftp.command=$sftp_command" \
        backup --compression "$COMPRESSION" --tag "photosync-$SERVER_ID" "${SOURCE_PATHS[@]}" "$@"
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
  install -m 0700 -o root -g root "$(readlink -f "$0")" "$RESTIC_INSTALL_PATH"
  service="/etc/systemd/system/photosync-restic-${id}-backup.service"
  timer="/etc/systemd/system/photosync-restic-${id}-backup.timer"
  maintenance_service="/etc/systemd/system/photosync-restic-${id}-maintenance.service"
  maintenance_timer="/etc/systemd/system/photosync-restic-${id}-maintenance.timer"
  {
    printf '[Unit]\nDescription=Restic backup to %s\nAfter=network-online.target\nWants=network-online.target\n' "$SERVER_LABEL"
    printf '[Service]\nType=oneshot\nExecStart=%s restic-run %s\n' "$RESTIC_INSTALL_PATH" "$id"
  } > "$service"
  {
    printf '[Unit]\nDescription=Daily Restic backup to %s\n' "$SERVER_LABEL"
    printf '[Timer]\nOnCalendar=*-*-* %s:00\nPersistent=true\nRandomizedDelaySec=5m\n' "$BACKUP_TIME"
    printf '[Install]\nWantedBy=timers.target\n'
  } > "$timer"
  {
    printf '[Unit]\nDescription=Restic retention and integrity check for %s\nAfter=network-online.target\nWants=network-online.target\n' "$SERVER_LABEL"
    printf '[Service]\nType=oneshot\nExecStart=%s restic-maintenance %s\n' "$RESTIC_INSTALL_PATH" "$id"
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
  local id=$1 dir admin_password repository_password
  load_controller_server "$id"
  confirm "Display recovery credentials for $SERVER_LABEL on screen?" || return 0
  dir=$(controller_server_dir "$id")
  admin_password=$(decrypt_controller_secret "$dir/admin-password.cred")
  repository_password=$(decrypt_controller_secret "$dir/repository-password.cred")
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
      0) show_controller_server_info "$id"; press_enter_to_continue ;;
      1) dry_run_controller_server "$id"; press_enter_to_continue ;;
      2) restic_controller_command "$id" backup; press_enter_to_continue ;;
      3) restic_controller_command "$id" snapshots; press_enter_to_continue ;;
      4) edit_controller_connection "$id" ;;
      5) edit_controller_backup_settings "$id" ;;
      6) ensure_remote_backup_storage "$id"; provision_controller_server "$id"; write_controller_jobs "$id"; press_enter_to_continue ;;
      7) show_controller_recovery_credentials "$id" ;;
      8) delete_controller_server "$id"; return 0 ;;
      9) return 0 ;;
      10) exit 0 ;;
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
  ensure_restic_controller
  while :; do
    choose_menu 'Restic backup management (runs from this primary server)' \
      'Add a Restic backup server' \
      'List and manage Restic backup servers' \
      'Dry run all Restic backup servers' \
      'Go back' \
      'Quit'
    case "$MENU_INDEX" in
      0) add_controller_server ;;
      1) list_and_manage_controller_servers ;;
      2) dry_run_all_controller_servers ;;
      3) return 0 ;;
      4) exit 0 ;;
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

Without an argument, the primary-only management menu opens. Backup servers
are installed and managed remotely from this primary server.
EOF
}

main() {
  local role=${1-} server_id=${2-}
  case "$role" in
    -h|--help|help) usage; exit 0 ;;
  esac
  require_root
  case "$role" in
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
    '') primary_menu; exit 0 ;;
    primary|add-samba|list-samba|change-samba-password|delete-samba) ;;
    *) die "Unknown role: $role. Use primary, add-samba, list-samba, change-samba-password, delete-samba, or --help." ;;
  esac

  case "$role" in
    primary) setup_primary ;;
    add-samba) add_phone_backup_share ;;
    list-samba) list_samba_shares ;;
    change-samba-password) change_samba_password ;;
    delete-samba) delete_samba_share ;;
  esac
}

# Keeping the functions sourceable makes it possible to test hardware-detection
# helpers without starting the interactive installer.
if [ "${PHOTOSYNC_SETUP_LIBRARY:-0}" != 1 ]; then
  main "$@"
fi
