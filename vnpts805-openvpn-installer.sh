#!/bin/sh
set -eu

# Interactive, resumable OpenVPN server installer for Debian 11 on S805 TV boxes.
# Run as root: sh vnpts805-openvpn-installer.sh

EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_CONF="/etc/openvpn/server.conf"
OVPNMAN="/usr/local/bin/ovpnman"
CLIENT_OUTDIR="/root/ovpn-clients"
LOG_FILE="/var/log/openvpn-server.log"
STATUS_FILE="/var/log/openvpn-status.log"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

need_root() {
  [ "$(id -u)" = "0" ] || die "Run this script as root."
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

setup_terminal() {
  [ -t 0 ] || return 0
  # This TV box/terminal commonly sends ^H for Backspace. Do not force ^?
  # here; that makes Backspace appear literally as ^H^H^H in prompts.
  # echoe makes the terminal visibly erase the old character instead of only
  # moving the cursor left and leaving stale text on screen.
  stty erase '^H' echoe echok -echoprt 2>/dev/null || true
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
  printf "\n[Q] %s\n[Answer] [%s]: " "$prompt" "$default" >&2
  read -r ans || ans=""
  ans="$(clean_answer "$ans")"
  [ -n "$ans" ] || ans="$default"
  printf "%s" "$ans"
}

ask_detail() {
  prompt="$1"
  detail="$2"
  default="$3"
  printf "\n[Q] %s\n[More detail] %s\n[Answer] [%s]: " "$prompt" "$detail" "$default" >&2
  read -r ans || ans=""
  ans="$(clean_answer "$ans")"
  [ -n "$ans" ] || ans="$default"
  printf "%s" "$ans"
}

ask_yn() {
  prompt="$1"
  default="$2"
  case "$default" in
    y|Y|yes|YES|Yes) suffix="Y/n"; default="y" ;;
    n|N|no|NO|No) suffix="y/N"; default="n" ;;
    *) suffix="$default" ;;
  esac
  while :; do
    printf "\n[Q] %s\n[Answer] (%s): " "$prompt" "$suffix" >&2
    read -r ans || ans=""
    ans="$(clean_answer "$ans")"
    [ -n "$ans" ] || ans="$default"
    case "$ans" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) echo "Please answer y or n." >&2 ;;
    esac
  done
}

ask_yn_detail() {
  prompt="$1"
  detail="$2"
  default="$3"
  case "$default" in
    y|Y|yes|YES|Yes) suffix="Y/n"; default="y" ;;
    n|N|no|NO|No) suffix="y/N"; default="n" ;;
    *) suffix="$default" ;;
  esac
  while :; do
    printf "\n[Q] %s\n[More detail] %s\n[Answer] (%s): " "$prompt" "$detail" "$suffix" >&2
    read -r ans || ans=""
    ans="$(clean_answer "$ans")"
    [ -n "$ans" ] || ans="$default"
    case "$ans" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) echo "Please answer y or n." >&2 ;;
    esac
  done
}

first_file() {
  for f in "$@"; do
    [ -f "$f" ] && { printf "%s" "$f"; return 0; }
  done
  return 1
}

first_dir() {
  for d in "$@"; do
    [ -d "$d" ] && { printf "%s" "$d"; return 0; }
  done
  return 1
}

parse_conf_value() {
  file="$1"
  key="$2"
  [ -f "$file" ] || return 1
  awk -v k="$key" '$1 == k && NF == 2 {print $2; exit}' "$file"
}

parse_server_netmask() {
  file="$1"
  [ -f "$file" ] || return 1
  awk '$1 == "server" {print $2 " " $3; exit}' "$file"
}

infer_default_iface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

infer_lan_cidr() {
  iface="$1"
  [ -n "$iface" ] || return 1
  ip -4 route show dev "$iface" proto kernel scope link 2>/dev/null | awk '{print $1; exit}'
}

cidr_prefix() {
  printf "%s" "$1" | awk -F/ '{print $2}'
}

cidr_network() {
  printf "%s" "$1" | awk -F/ '{print $1}'
}

cidr_to_netmask() {
  p="$1"
  case "$p" in
    8) echo "255.0.0.0" ;;
    9) echo "255.128.0.0" ;;
    10) echo "255.192.0.0" ;;
    11) echo "255.224.0.0" ;;
    12) echo "255.240.0.0" ;;
    13) echo "255.248.0.0" ;;
    14) echo "255.252.0.0" ;;
    15) echo "255.254.0.0" ;;
    16) echo "255.255.0.0" ;;
    17) echo "255.255.128.0" ;;
    18) echo "255.255.192.0" ;;
    19) echo "255.255.224.0" ;;
    20) echo "255.255.240.0" ;;
    21) echo "255.255.248.0" ;;
    22) echo "255.255.252.0" ;;
    23) echo "255.255.254.0" ;;
    24) echo "255.255.255.0" ;;
    25) echo "255.255.255.128" ;;
    26) echo "255.255.255.192" ;;
    27) echo "255.255.255.224" ;;
    28) echo "255.255.255.240" ;;
    29) echo "255.255.255.248" ;;
    30) echo "255.255.255.252" ;;
    31) echo "255.255.255.254" ;;
    32) echo "255.255.255.255" ;;
    *) echo "255.255.255.0" ;;
  esac
}

netmask_to_prefix() {
  m="$1"
  case "$m" in
    255.0.0.0) echo "8" ;;
    255.128.0.0) echo "9" ;;
    255.192.0.0) echo "10" ;;
    255.224.0.0) echo "11" ;;
    255.240.0.0) echo "12" ;;
    255.248.0.0) echo "13" ;;
    255.252.0.0) echo "14" ;;
    255.254.0.0) echo "15" ;;
    255.255.0.0) echo "16" ;;
    255.255.128.0) echo "17" ;;
    255.255.192.0) echo "18" ;;
    255.255.224.0) echo "19" ;;
    255.255.240.0) echo "20" ;;
    255.255.248.0) echo "21" ;;
    255.255.252.0) echo "22" ;;
    255.255.254.0) echo "23" ;;
    255.255.255.0) echo "24" ;;
    255.255.255.128) echo "25" ;;
    255.255.255.192) echo "26" ;;
    255.255.255.224) echo "27" ;;
    255.255.255.240) echo "28" ;;
    255.255.255.248) echo "29" ;;
    255.255.255.252) echo "30" ;;
    255.255.255.254) echo "31" ;;
    255.255.255.255) echo "32" ;;
    *) echo "24" ;;
  esac
}

sed_escape() {
  printf "%s" "$1" | sed 's/[\/&|]/\\&/g'
}

valid_port() {
  p="$1"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$p" -ge 1 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null ;;
  esac
}

valid_proto() {
  case "$1" in udp|tcp) return 0 ;; *) return 1 ;; esac
}

normalize_ipv4_cidr() {
  cidr="$1"
  awk -v cidr="$cidr" '
    function fail() { exit 1 }
    BEGIN {
      if (cidr !~ /^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\/[0-9][0-9]*$/) fail()
      split(cidr, parts, "/")
      ip = parts[1]
      prefix = parts[2] + 0
      if (prefix < 8 || prefix > 30) fail()
      split(ip, oct, ".")
      for (i = 1; i <= 4; i++) {
        if (oct[i] !~ /^[0-9][0-9]*$/) fail()
        oct[i] += 0
        if (oct[i] < 0 || oct[i] > 255) fail()
        net[i] = oct[i]
      }

      full = int(prefix / 8)
      rem = prefix % 8
      if (rem == 0) {
        start = full + 1
      } else {
        start = full + 2
        partial = full + 1
        block = 2 ^ (8 - rem)
        net[partial] = int(net[partial] / block) * block
      }
      for (i = start; i <= 4; i++) net[i] = 0

      srv[1] = net[1]; srv[2] = net[2]; srv[3] = net[3]; srv[4] = net[4] + 1
      for (i = 4; i >= 2; i--) {
        if (srv[i] > 255) {
          srv[i] = 0
          srv[i - 1]++
        }
      }

      printf "%d.%d.%d.%d %d %d.%d.%d.%d\n", net[1], net[2], net[3], net[4], prefix, srv[1], srv[2], srv[3], srv[4]
    }
  '
}

validate_server_conf_basic() {
  file="$1"
  [ -f "$file" ] || return 1

  # Prompt text accidentally captured into the config always contains patterns like [1194]:.
  if grep -q '\[[^]]*\]:' "$file" 2>/dev/null; then
    return 1
  fi

  port="$(awk '$1 == "port" {if (NF == 2) print $2; else print "BAD"; exit}' "$file")"
  proto="$(awk '$1 == "proto" {if (NF == 2) print $2; else print "BAD"; exit}' "$file")"
  server_net="$(awk '$1 == "server" {if (NF == 3) print $2; else print "BAD"; exit}' "$file")"
  server_mask="$(awk '$1 == "server" {if (NF == 3) print $3; else print "BAD"; exit}' "$file")"

  valid_port "$port" || return 1
  valid_proto "$proto" || return 1
  [ -n "$server_net" ] && [ "$server_net" != "BAD" ] || return 1
  [ -n "$server_mask" ] && [ "$server_mask" != "BAD" ] || return 1
  normalize_ipv4_cidr "$server_net/$(netmask_to_prefix "$server_mask")" >/dev/null 2>&1 || return 1

  return 0
}

ask_vpn_subnet() {
  default_cidr="$1"
  while :; do
    raw="$(ask "VPN client subnet in CIDR form" "$default_cidr")"; echo >&2
    case "$raw" in
      */*) cidr="$raw" ;;
      *)
        prefix="$(ask "CIDR prefix for $raw" "24")"; echo >&2
        cidr="$raw/$prefix"
        ;;
    esac

    normalized="$(normalize_ipv4_cidr "$cidr" 2>/dev/null || true)"
    if [ -z "$normalized" ]; then
      echo "Please enter a valid IPv4 subnet such as 172.16.119.0/24. Prefix must be /8 through /30." >&2
      continue
    fi

    set -- $normalized
    net="$1"
    prefix="$2"
    server_ip="$3"
    netmask="$(cidr_to_netmask "$prefix")"

    if [ "$cidr" != "$net/$prefix" ]; then
      echo "Using network $net/$prefix. The OpenVPN server tunnel IP will be $server_ip." >&2
    else
      echo "The OpenVPN server tunnel IP will be $server_ip." >&2
    fi

    printf "%s %s %s %s" "$net" "$netmask" "$server_ip" "$prefix"
    return 0
  done
}

route_exists() {
  net="$1"
  prefix="$2"
  printf "%s" "$PUSH_ROUTES" | awk -v want="$net $prefix" '$0 == want {found=1} END {exit found ? 0 : 1}'
}

add_push_route() {
  net="$1"
  prefix="$2"
  if route_exists "$net" "$prefix"; then
    echo "That route is already in the list, so it was not added again: $net/$prefix" >&2
    return 1
  fi
  PUSH_ROUTES="${PUSH_ROUTES}${net} ${prefix}
"
  echo "Added route for VPN clients: $net/$prefix" >&2
  return 0
}

ask_route_cidr() {
  prompt="$1"
  default_cidr="$2"
  while :; do
    raw="$(ask "$prompt" "$default_cidr")"; echo >&2
    if [ -z "$raw" ]; then
      echo "Please enter a network such as 10.0.0.0/16 or 192.168.1.0/24." >&2
      continue
    fi
    case "$raw" in
      */*) cidr="$raw" ;;
      *)
        prefix="$(ask "CIDR prefix for $raw" "24")"; echo >&2
        cidr="$raw/$prefix"
        ;;
    esac

    normalized="$(normalize_ipv4_cidr "$cidr" 2>/dev/null || true)"
    if [ -z "$normalized" ]; then
      echo "Please enter a valid IPv4 network such as 10.0.0.0/16 or 192.168.1.0/24." >&2
      continue
    fi

    set -- $normalized
    net="$1"
    prefix="$2"
    if [ "$cidr" != "$net/$prefix" ]; then
      echo "Using network route $net/$prefix." >&2
    fi
    printf "%s %s" "$net" "$prefix"
    return 0
  done
}

ensure_packages() {
  if ! cmd_exists openvpn || ! cmd_exists make-cadir || ! cmd_exists iptables; then
    info "Installing required packages."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn easy-rsa iptables iptables-persistent
  else
    info "OpenVPN, Easy-RSA, and iptables appear to be installed."
    if ask_yn "Install/refresh iptables-persistent package too?" "n"; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent || warn "iptables-persistent install failed; continuing."
    fi
  fi
}

ensure_tun() {
  info "Checking /dev/net/tun."
  if [ ! -c /dev/net/tun ]; then
    warn "/dev/net/tun is missing; trying to create the device node."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun 2>/dev/null || true
  fi

  [ -c /dev/net/tun ] || die "/dev/net/tun is still missing. Your Android kernel may not have TUN support."

  if openvpn --mktun --dev tun-test-installer >/tmp/openvpn-tun-test.log 2>&1; then
    openvpn --rmtun --dev tun-test-installer >/dev/null 2>&1 || true
    info "TUN device works."
  else
    cat /tmp/openvpn-tun-test.log >&2 || true
    die "OpenVPN cannot create a TUN interface. Kernel CONFIG_TUN or tun.ko is probably missing."
  fi
}

prepare_easyrsa() {
  existing="$(first_dir "$EASYRSA_DIR" "$HOME/openvpn-ca" "/root/openvpn-ca" 2>/dev/null || true)"

  if [ -n "$existing" ] && [ "$existing" != "$EASYRSA_DIR" ]; then
    info "Found existing Easy-RSA directory: $existing"
    if [ ! -d "$EASYRSA_DIR" ]; then
      if ask_yn "Copy this existing CA/key material into $EASYRSA_DIR?" "y"; then
        mkdir -p "$EASYRSA_DIR"
        cp -a "$existing/." "$EASYRSA_DIR/"
      fi
    fi
  fi

  if [ -d "$EASYRSA_DIR/pki" ]; then
    if ask_yn "Existing Easy-RSA PKI found. Keep it and continue?" "y"; then
      :
    else
      ts="$(date +%Y%m%d-%H%M%S)"
      mv "$EASYRSA_DIR" "$EASYRSA_DIR.backup-$ts"
      mkdir -p "$EASYRSA_DIR"
    fi
  fi

  if [ ! -x "$EASYRSA_DIR/easyrsa" ]; then
    if cmd_exists make-cadir; then
      rm -rf "$EASYRSA_DIR.tmp-new"
      make-cadir "$EASYRSA_DIR.tmp-new"
      mkdir -p "$EASYRSA_DIR"
      cp -a "$EASYRSA_DIR.tmp-new/." "$EASYRSA_DIR/"
      rm -rf "$EASYRSA_DIR.tmp-new"
    elif [ -x /usr/share/easy-rsa/easyrsa ]; then
      mkdir -p "$EASYRSA_DIR"
      cp -a /usr/share/easy-rsa/. "$EASYRSA_DIR/"
    else
      die "Cannot locate Easy-RSA files."
    fi
  fi

  cd "$EASYRSA_DIR"

  [ -d pki ] || ./easyrsa init-pki
  if [ ! -f pki/ca.crt ]; then
    info "Creating CA certificate. You may be asked for CA details."
    ./easyrsa build-ca
  else
    info "CA certificate already exists."
  fi

  if [ ! -f pki/issued/server.crt ] || [ ! -f pki/private/server.key ]; then
    info "Creating server certificate."
    ./easyrsa gen-req server nopass
    ./easyrsa sign-req server server
  else
    info "Server certificate already exists."
  fi

  if [ ! -f pki/dh.pem ]; then
    info "Generating DH parameters. This can be slow on S805."
    ./easyrsa gen-dh
  else
    info "DH parameters already exist."
  fi

  if [ ! -f ta.key ]; then
    info "Generating tls-auth key."
    openvpn --genkey secret ta.key
  else
    info "tls-auth key already exists."
  fi

  mkdir -p /etc/openvpn
  cp pki/ca.crt /etc/openvpn/ca.crt
  cp pki/issued/server.crt /etc/openvpn/server.crt
  cp pki/private/server.key /etc/openvpn/server.key
  cp pki/dh.pem /etc/openvpn/dh.pem
  cp ta.key /etc/openvpn/ta.key

  if [ -f pki/crl.pem ]; then
    cp pki/crl.pem /etc/openvpn/crl.pem
    chmod 644 /etc/openvpn/crl.pem
  else
    ./easyrsa gen-crl || true
    [ -f pki/crl.pem ] && cp pki/crl.pem /etc/openvpn/crl.pem && chmod 644 /etc/openvpn/crl.pem
  fi
}

write_server_conf() {
  old_port="$(parse_conf_value "$SERVER_CONF" port 2>/dev/null || true)"
  old_proto="$(parse_conf_value "$SERVER_CONF" proto 2>/dev/null || true)"
  old_cipher="$(parse_conf_value "$SERVER_CONF" cipher 2>/dev/null || true)"
  old_auth="$(parse_conf_value "$SERVER_CONF" auth 2>/dev/null || true)"
  old_server="$(parse_server_netmask "$SERVER_CONF" 2>/dev/null || true)"

  default_iface="$(infer_default_iface || true)"
  default_lan="$(infer_lan_cidr "$default_iface" || true)"
  default_lan_net="$(cidr_network "$default_lan")"
  default_lan_mask="$(cidr_to_netmask "$(cidr_prefix "$default_lan")")"

  case "$old_port" in
    ''|*[!0-9]*) old_port="60412" ;;
    *) [ "$old_port" -ge 1 ] 2>/dev/null && [ "$old_port" -le 65535 ] 2>/dev/null || old_port="60412" ;;
  esac
  case "$old_proto" in
    udp|tcp) : ;;
    *) old_proto="udp" ;;
  esac

  default_vpn_net="10.9.10.0"
  default_vpn_mask="255.255.255.0"
  if [ -n "$old_server" ]; then
    old_vpn_net="$(printf "%s" "$old_server" | awk '{print $1}')"
    old_vpn_mask="$(printf "%s" "$old_server" | awk '{print $2}')"
    old_vpn_prefix="$(netmask_to_prefix "$old_vpn_mask")"
    old_vpn_normalized="$(normalize_ipv4_cidr "$old_vpn_net/$old_vpn_prefix" 2>/dev/null || true)"
    if [ -n "$old_vpn_normalized" ]; then
      set -- $old_vpn_normalized
      default_vpn_net="$1"
      default_vpn_mask="$(cidr_to_netmask "$2")"
    fi
  fi

  if [ -f "$SERVER_CONF" ]; then
    if validate_server_conf_basic "$SERVER_CONF"; then
      replace_prompt="Replace $SERVER_CONF?"
    else
      warn "$SERVER_CONF is invalid or contains captured prompt text. OpenVPN cannot start with it."
      replace_prompt="Replace invalid $SERVER_CONF now?"
    fi

    if ask_yn "$replace_prompt" "y"; then
      ts="$(date +%Y%m%d-%H%M%S)"
      cp "$SERVER_CONF" "$SERVER_CONF.backup-$ts"
    else
      if validate_server_conf_basic "$SERVER_CONF"; then
        info "Keeping existing server config."
        return 0
      fi
      die "Cannot continue with invalid $SERVER_CONF. Re-run and answer Y to replace it."
    fi
  fi

  PORT="$(ask "OpenVPN listen port" "$old_port")"; echo
  PROTO="$(ask "Protocol, udp or tcp" "$old_proto")"; echo
  CIPHER="${old_cipher:-AES-256-GCM}"
  AUTH="${old_auth:-SHA256}"
  info "Using cipher: $CIPHER"
  info "Using auth digest: $AUTH"

  default_vpn_cidr="$default_vpn_net/$(netmask_to_prefix "$default_vpn_mask")"
  set -- $(ask_vpn_subnet "$default_vpn_cidr")
  VPN_NET="$1"
  VPN_MASK="$2"
  VPN_SERVER_IP="$3"

  TOPOLOGY="$(ask "Topology" "subnet")"; echo

  if [ -n "$default_iface" ]; then
    nat_detail="The NAT interface is the network port this box uses to reach your router or the internet. For most TV boxes, the detected value is correct. Choose Y unless you know traffic should leave through another interface."
    if ask_yn_detail "Use detected default interface $default_iface for NAT?" "$nat_detail" "y"; then
      NAT_IFACE="$default_iface"
    else
      NAT_IFACE="$(ask_detail "Internet-facing interface for NAT" "Enter the interface name that connects this box to your router or internet, for example eth0 or wlan0." "$default_iface")"; echo
    fi
  else
    NAT_IFACE="$(ask_detail "Internet-facing interface for NAT" "Enter the interface name that connects this box to your router or internet, for example eth0 or wlan0." "eth0")"; echo
  fi

  PUSH_ROUTES=""
  route_push_detail="Routes can be placed inside each client profile, or pushed by the server. This installer uses server-pushed routes, which means you manage routes once on this box and clients receive them when they connect or reconnect."
  if [ -n "$default_lan" ] && [ "$default_lan" != "default" ] && [ -n "$default_lan_net" ]; then
    lan_detail="This lets VPN clients reach devices on your home or office network, not only the VPN server itself. Choose Y if remote clients should access local machines such as routers, NAS, cameras, printers, or servers. $route_push_detail"
    if ask_yn_detail "Push detected LAN route $default_lan to VPN clients?" "$lan_detail" "y"; then
      add_push_route "$default_lan_net" "$(cidr_prefix "$default_lan")" || true
    else
      if ask_yn_detail "Push a different LAN route to VPN clients?" "Choose Y only if remote VPN clients should reach a different local network. You can enter it in CIDR form, for example 192.168.1.0/24. $route_push_detail" "n"; then
        set -- $(ask_route_cidr "LAN route to push to VPN clients, in CIDR form" "$default_lan")
        add_push_route "$1" "$2" || true
      fi
    fi
  else
    if ask_yn_detail "Push a LAN route to VPN clients?" "Choose Y if VPN clients should access devices on a local network behind this box. You can enter it in CIDR form, for example 192.168.1.0/24. $route_push_detail" "n"; then
      set -- $(ask_route_cidr "LAN route to push to VPN clients, in CIDR form" "")
      add_push_route "$1" "$2" || true
    fi
  fi

  while ask_yn_detail "Add another route that will be pushed to VPN clients?" "Use this only when you have another separate local network that VPN clients must reach. Duplicates are detected and skipped. These are server-pushed routes, so you do not need to edit every client profile." "n"; do
    set -- $(ask_route_cidr "Additional LAN route in CIDR form" "")
    add_push_route "$1" "$2" || true
  done

  if ask_yn "Allow VPN clients to talk to each other?" "y"; then CLIENT_TO_CLIENT="yes"; else CLIENT_TO_CLIENT="no"; fi
  if ask_yn "Route all client internet traffic through this box?" "n"; then REDIRECT_GATEWAY="yes"; else REDIRECT_GATEWAY="no"; fi
  DNS1="$(ask "DNS server pushed to clients" "1.1.1.1")"; echo
  DNS2="$(ask "Second DNS server pushed to clients, or empty" "8.8.8.8")"; echo
  VERB="$(ask "OpenVPN verbosity" "6")"; echo

  {
    echo "port $PORT"
    echo "proto $PROTO"
    echo "dev tun"
    echo
    echo "ca ca.crt"
    echo "cert server.crt"
    echo "key server.key"
    echo "dh dh.pem"
    echo "tls-auth ta.key 0"
    echo
    echo "# OpenVPN server tunnel IP: $VPN_SERVER_IP"
    echo "server $VPN_NET $VPN_MASK"
    echo "topology $TOPOLOGY"
    echo
    printf "%s" "$PUSH_ROUTES" | while read route_net route_prefix; do
      [ -n "$route_net" ] || continue
      echo "push \"route $route_net $(cidr_to_netmask "$route_prefix")\""
    done
    [ "$REDIRECT_GATEWAY" = "yes" ] && echo "push \"redirect-gateway def1 bypass-dhcp\""
    [ -n "$DNS1" ] && echo "push \"dhcp-option DNS $DNS1\""
    [ -n "$DNS2" ] && echo "push \"dhcp-option DNS $DNS2\""
    echo
    [ "$CLIENT_TO_CLIENT" = "yes" ] && echo "client-to-client"
    echo "keepalive 10 120"
    echo
    echo "cipher $CIPHER"
    echo "auth $AUTH"
    echo
    echo "persist-key"
    echo "persist-tun"
    echo
    [ -f /etc/openvpn/crl.pem ] && echo "crl-verify crl.pem"
    echo
    echo "verb $VERB"
    echo "log-append $LOG_FILE"
    echo "status $STATUS_FILE 5"
    if [ "$PROTO" = "udp" ]; then
      echo "explicit-exit-notify 3"
    fi
    echo "reneg-sec 14400"
  } > "$SERVER_CONF"

  chmod 600 /etc/openvpn/server.key
  chmod 644 "$SERVER_CONF"
}

ensure_forwarding_and_nat() {
  info "Configuring IP forwarding and NAT."

  if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf 2>/dev/null; then
    printf "\nnet.ipv4.ip_forward=1\n" >> /etc/sysctl.conf
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null || echo 1 > /proc/sys/net/ipv4/ip_forward

  iface="${NAT_IFACE:-}"
  if [ -z "$iface" ]; then
    detected_iface="$(infer_default_iface || true)"
    if [ -n "$detected_iface" ]; then
      if ask_yn "Use detected default interface $detected_iface for NAT?" "y"; then
        iface="$detected_iface"
      else
        iface="$(ask "Internet-facing interface for NAT" "$detected_iface")"; echo
      fi
    else
      iface="$(ask "Internet-facing interface for NAT" "eth0")"; echo
    fi
  fi

  vpn_net="$(awk '$1 == "server" {print $2; exit}' "$SERVER_CONF")"
  vpn_mask="$(awk '$1 == "server" {print $3; exit}' "$SERVER_CONF")"
  vpn_cidr="$vpn_net/$(netmask_to_prefix "$vpn_mask")"

  if ! iptables -t nat -C POSTROUTING -s "$vpn_cidr" -o "$iface" -j MASQUERADE >/dev/null 2>&1; then
    iptables -t nat -A POSTROUTING -s "$vpn_cidr" -o "$iface" -j MASQUERADE
  fi

  if cmd_exists netfilter-persistent; then
    netfilter-persistent save || warn "Could not save iptables rules with netfilter-persistent."
  elif cmd_exists iptables-save; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 || warn "Could not save iptables rules."
  fi
}

install_ovpnman() {
  if [ -f "$OVPNMAN" ]; then
    ovpnman_detail="ovpnman is the client management command installed at $OVPNMAN. It creates, lists, and revokes client .ovpn profiles using commands like: ovpnman add client1. Choose Y to update it to the version bundled with this installer."
    if ! ask_yn_detail "Replace existing $OVPNMAN?" "$ovpnman_detail" "y"; then
      info "Keeping existing ovpnman."
      return 0
    fi
  fi

  remote_guess="$(hostname -I 2>/dev/null | awk '{print $1}')"
  remote_detail="This value is written into client .ovpn files as the OpenVPN remote endpoint. Use a public IP, DDNS/domain name, or hostname clients can resolve. Use LAN IP only for LAN-only clients."
  remote_host="$(ask_detail "Client remote endpoint, hostname/domain/DDNS/public IP/LAN IP" "$remote_detail" "${remote_guess:-CHANGE_ME}")"; echo
  remote_port="$(parse_conf_value "$SERVER_CONF" port 2>/dev/null || true)"
  remote_proto="$(parse_conf_value "$SERVER_CONF" proto 2>/dev/null || true)"
  cipher="$(parse_conf_value "$SERVER_CONF" cipher 2>/dev/null || true)"
  auth="$(parse_conf_value "$SERVER_CONF" auth 2>/dev/null || true)"
  valid_port "$remote_port" || remote_port="60412"
  valid_proto "$remote_proto" || remote_proto="udp"
  [ -n "$cipher" ] || cipher="AES-256-GCM"
  [ -n "$auth" ] || auth="SHA256"

  mkdir -p "$(dirname "$OVPNMAN")"
  cat > "$OVPNMAN" <<'OVPNMAN_EOF'
#!/bin/sh
set -eu

ACTION="${1:-}"
NAME="${2:-}"

EASYRSA_DIR="/etc/openvpn/easy-rsa"
OUTDIR="/root/ovpn-clients"
SERVER_CONF="/etc/openvpn/server.conf"

REMOTE_HOST="__REMOTE_HOST__"
REMOTE_PORT="__REMOTE_PORT__"
REMOTE_PROTO="__REMOTE_PROTO__"
DEFAULT_CIPHER="__CIPHER__"
DEFAULT_AUTH="__AUTH__"

die() { echo "ERROR: $*" >&2; exit 1; }
need_name() { [ -n "$NAME" ] || die "Usage: ovpnman $ACTION <client-name>"; }

ensure() {
  [ "$(id -u)" = "0" ] || die "Run as root."
  [ -d "$EASYRSA_DIR" ] || die "Missing $EASYRSA_DIR"
  [ -x "$EASYRSA_DIR/easyrsa" ] || die "Missing $EASYRSA_DIR/easyrsa"
  mkdir -p "$OUTDIR"
  chmod 700 "$OUTDIR"
}

server_value() {
  key="$1"
  awk -v k="$key" '$1 == k && NF == 2 {print $2; exit}' "$SERVER_CONF" 2>/dev/null || true
}

refresh_runtime_defaults() {
  p="$(server_value port)"
  pr="$(server_value proto)"
  c="$(server_value cipher)"
  a="$(server_value auth)"
  [ -n "$p" ] && REMOTE_PORT="$p"
  [ -n "$pr" ] && REMOTE_PROTO="$pr"
  [ -n "$c" ] && DEFAULT_CIPHER="$c"
  [ -n "$a" ] && DEFAULT_AUTH="$a"
}

clean_stale_client() {
  [ -n "$NAME" ] || return 0
  cd "$EASYRSA_DIR"
  if [ ! -f "pki/issued/$NAME.crt" ]; then
    rm -f "pki/reqs/$NAME.req" "pki/private/$NAME.key"
  fi
  rm -f "$OUTDIR/$NAME.ovpn.tmp"
}

client_index_state() {
  [ -f "$EASYRSA_DIR/pki/index.txt" ] || return 0
  awk -F'\t' -v cn="/CN=$NAME" '
    index($0, cn) {
      if ($1 == "V") active = 1
      if ($1 == "R") revoked = 1
      if ($1 == "E") expired = 1
    }
    END {
      if (active) print "valid"
      else if (revoked) print "revoked"
      else if (expired) print "expired"
    }
  ' "$EASYRSA_DIR/pki/index.txt"
}

archive_stale_profile() {
  [ -f "$OUTDIR/$NAME.ovpn" ] || return 0
  ts="$(date +%Y%m%d-%H%M%S)"
  mv "$OUTDIR/$NAME.ovpn" "$OUTDIR/$NAME.ovpn.stale-$ts"
  echo "Archived stale profile: $OUTDIR/$NAME.ovpn.stale-$ts" >&2
}

cleanup_interrupted() {
  echo
  echo "Interrupted. Cleaning partial files for $NAME." >&2
  clean_stale_client || true
  exit 130
}

restart_openvpn() {
  service openvpn restart >/dev/null 2>&1 && return 0
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart openvpn@server >/dev/null 2>&1 && return 0
    systemctl restart openvpn >/dev/null 2>&1 && return 0
  fi
  return 1
}

list_clients() {
  ensure
  [ -d "$EASYRSA_DIR/pki/issued" ] || exit 0
  ls -1 "$EASYRSA_DIR/pki/issued" 2>/dev/null | sed -n 's/\.crt$//p' | grep -v '^server$' | sort || true
}

add_client() {
  need_name
  ensure
  refresh_runtime_defaults
  trap cleanup_interrupted INT TERM HUP

  cd "$EASYRSA_DIR"

  [ -f "pki/ca.crt" ] || die "Missing pki/ca.crt."
  [ -f "ta.key" ] || die "Missing ta.key."

  state="$(client_index_state)"
  if [ -f "$OUTDIR/$NAME.ovpn" ]; then
    if [ "$state" = "valid" ] && [ -f "pki/issued/$NAME.crt" ]; then
      die "Already exists: $OUTDIR/$NAME.ovpn"
    fi
    archive_stale_profile
  fi

  clean_stale_client
  ./easyrsa build-client-full "$NAME" nopass

  tmp="$OUTDIR/$NAME.ovpn.tmp"
  final="$OUTDIR/$NAME.ovpn"
  cat > "$tmp" <<EOF2
client
dev tun
proto $REMOTE_PROTO
remote $REMOTE_HOST $REMOTE_PORT

nobind
persist-key
persist-tun

remote-cert-tls server
key-direction 1

cipher $DEFAULT_CIPHER
auth $DEFAULT_AUTH
verb 3

<ca>
$(cat pki/ca.crt)
</ca>

<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "pki/issued/$NAME.crt")
</cert>

<key>
$(cat "pki/private/$NAME.key")
</key>

<tls-auth>
$(cat ta.key)
</tls-auth>
EOF2

  mv "$tmp" "$final"
  chmod 600 "$final"
  trap - INT TERM HUP
  echo "$final"
}

revoke_client() {
  need_name
  ensure
  cd "$EASYRSA_DIR"

  state="$(client_index_state)"

  if [ "$state" = "valid" ] && [ -f "pki/issued/$NAME.crt" ]; then
    ./easyrsa revoke "$NAME"
  elif [ "$state" = "revoked" ]; then
    echo "$NAME is already marked revoked; regenerating CRL." >&2
  else
    die "No active or revoked certificate record for $NAME."
  fi

  if ! ./easyrsa gen-crl; then
    echo "ERROR: CRL generation failed. The certificate may already be revoked, but /etc/openvpn/crl.pem was not updated." >&2
    echo "Fix the CA passphrase problem and run again: ovpnman revoke $NAME" >&2
    exit 1
  fi

  cp pki/crl.pem /etc/openvpn/crl.pem
  chmod 644 /etc/openvpn/crl.pem

  grep -qE '^[[:space:]]*crl-verify[[:space:]]+crl\.pem[[:space:]]*$' "$SERVER_CONF" 2>/dev/null || \
    echo 'crl-verify crl.pem' >> "$SERVER_CONF"

  rm -f "$OUTDIR/$NAME.ovpn" "$OUTDIR/$NAME.ovpn.tmp" 2>/dev/null || true
  restart_openvpn || true
  echo "revoked: $NAME"
}

show_config() {
  ensure
  refresh_runtime_defaults
  echo "EASYRSA_DIR=$EASYRSA_DIR"
  echo "OUTDIR=$OUTDIR"
  echo "REMOTE_HOST=$REMOTE_HOST"
  echo "REMOTE_PORT=$REMOTE_PORT"
  echo "REMOTE_PROTO=$REMOTE_PROTO"
  echo "CIPHER=$DEFAULT_CIPHER"
  echo "AUTH=$DEFAULT_AUTH"
}

case "$ACTION" in
  list) list_clients ;;
  add) add_client ;;
  revoke) revoke_client ;;
  config) show_config ;;
  *)
    echo "Usage:"
    echo "  ovpnman list"
    echo "  ovpnman add <client-name>"
    echo "  ovpnman revoke <client-name>"
    echo "  ovpnman config"
    exit 1
    ;;
esac
OVPNMAN_EOF

  remote_host_esc="$(sed_escape "$remote_host")"
  remote_port_esc="$(sed_escape "$remote_port")"
  remote_proto_esc="$(sed_escape "$remote_proto")"
  cipher_esc="$(sed_escape "$cipher")"
  auth_esc="$(sed_escape "$auth")"

  sed -i \
    -e "s|__REMOTE_HOST__|$remote_host_esc|g" \
    -e "s|__REMOTE_PORT__|$remote_port_esc|g" \
    -e "s|__REMOTE_PROTO__|$remote_proto_esc|g" \
    -e "s|__CIPHER__|$cipher_esc|g" \
    -e "s|__AUTH__|$auth_esc|g" \
    "$OVPNMAN"
  chmod 755 "$OVPNMAN"
}

restart_service() {
  info "Starting/restarting OpenVPN."
  if service openvpn restart; then
    :
  elif cmd_exists systemctl && systemctl restart openvpn@server; then
    :
  else
    warn "Service restart failed. Trying a short daemonized config test."
    rm -f /tmp/openvpn-installer-test.pid /tmp/openvpn-installer-test.log
    if openvpn --config "$SERVER_CONF" --daemon openvpn-installer-test --writepid /tmp/openvpn-installer-test.pid --log /tmp/openvpn-installer-test.log; then
      sleep 3
      if [ -f /tmp/openvpn-installer-test.pid ]; then
        kill "$(cat /tmp/openvpn-installer-test.pid)" >/dev/null 2>&1 || true
      fi
      warn "OpenVPN can start manually, but the init service failed. Check /etc/init.d/openvpn on this box."
    else
      warn "Manual OpenVPN start failed too. Last test log:"
      tail -n 60 /tmp/openvpn-installer-test.log 2>/dev/null || true
    fi
  fi
}

show_status() {
  echo
  info "OpenVPN service status:"
  service openvpn status 2>/dev/null || true
  echo
  info "Tunnel interfaces:"
  ip addr show 2>/dev/null | awk '/^[0-9]+: tun/ {print; getline; print}' || true
  echo
  info "Useful commands:"
  echo "  ovpnman add client1"
  echo "  ovpnman list"
  echo "  ovpnman revoke client1"
  echo "  tail -f $LOG_FILE"
}

main() {
  need_root
  setup_terminal
  ensure_packages
  ensure_tun
  prepare_easyrsa
  write_server_conf
  ensure_forwarding_and_nat
  install_ovpnman
  restart_service
  show_status
}

main "$@"
