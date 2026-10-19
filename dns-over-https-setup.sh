#!/bin/bash
# Public, single-instance Debian installer. No environment-variable configuration.
# Managed by dns-over-https-setup v2
# Explicit library mode defines functions only; it does not probe or mutate the host.

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ask() {
    local answer
    printf '%s%s: ' "$1" "${2:+ [$2]}" >&2
    IFS= read -r answer || fail 'Input ended; cancelled.'
    printf '%s' "${answer:-${2:-}}"
}
confirm() { [[ $(ask "$1 (type yes)" no) == yes ]]; }

# Python 3 standard library only. Never eval/source administrator configuration.
helper() {
    python3 - "$@" <<'PY'
import sys, re, ipaddress, pathlib, json, hashlib, tarfile, os, ssl, socket, struct, secrets, http.client
op, *a = sys.argv[1:]
def require(ok, why):
    if not ok: raise ValueError(why)
def port(s):
    require(re.fullmatch(r'[1-9][0-9]{0,4}', s) and 1024 <= int(s) <= 65535,
            'port must be a canonical integer in 1024..65535')
def path(s):
    require(re.fullmatch(r'/[A-Za-z0-9_./-]+', s) and '..' not in pathlib.PurePosixPath(s).parts,
            'use an absolute path without whitespace, shell metacharacters or ..')
try:
    if op == 'domain':
        require(len(a[0]) <= 253 and re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?', a[0]),
                'hostname must be a lowercase fully qualified DNS name')
    elif op == 'port': port(a[0])
    elif op == 'path': path(a[0])
    elif op == 'upstream':
        s=a[0]
        if s.startswith('['):
            m=re.fullmatch(r'\[([^]]+)\]:([1-9][0-9]{0,4})',s)
            require(m is not None, 'IPv6 upstream must be [address]:port')
            host,p=m.groups(); require(ipaddress.ip_address(host).version==6,'expected IPv6')
        else:
            host,p=s.rsplit(':',1); require(ipaddress.ip_address(host).version==4,'expected IPv4')
        require('%' not in host and re.fullmatch(r'[1-9][0-9]{0,4}',p) and 1<=int(p)<=65535,'invalid upstream port')
    elif op == 'cidrs':
        require(bool(a[0].split()), 'at least one allowed CIDR is required')
        for s in a[0].split():
            require('/' in s and '%' not in s,'explicit CIDR prefix is required')
            n=ipaddress.ip_network(s, strict=True)
            require(n.prefixlen > 0,'world-open /0 ACL is not allowed')
    elif op == 'release':
        require(re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+',a[0]),'use an explicit stable release tag vX.Y.Z')
    elif op == 'digest':
        data=json.loads(pathlib.Path(a[0]).read_text()); name=a[1]
        require(data.get('tag_name')==a[2] and not data.get('draft') and not data.get('prerelease'),'release mismatch')
        assets=[x for x in data['assets'] if x['name']==name]
        require(len(assets)==1,'release asset missing or ambiguous')
        x=assets[0]; d=x.get('digest','')
        require(re.fullmatch(r'sha256:[0-9a-f]{64}',d),'release has no published SHA256 digest; refusing unverified binary')
        require(x['browser_download_url']==f'https://github.com/AdguardTeam/dnsproxy/releases/download/{a[2]}/{name}', 'unexpected asset URL')
        require(hashlib.sha256(pathlib.Path(a[3]).read_bytes()).hexdigest()==d[7:],'published SHA256 mismatch')
    elif op == 'extract':
        # Extract only a single regular executable, never archive symlinks or paths.
        with tarfile.open(a[0],'r:gz') as t:
            members=[m for m in t.getmembers() if pathlib.PurePosixPath(m.name).name=='dnsproxy' and m.isfile()]
            require(len(members)==1 and members[0].size<100_000_000,'missing/ambiguous/oversized executable')
            with t.extractfile(members[0]) as src, open(a[1],'wb') as dst: dst.write(src.read())
        os.chmod(a[1],0o755)
    elif op == 'conflicts':
        text=pathlib.Path(a[0]).read_text(); domain=a[1]; managed=pathlib.Path(a[2]).resolve()
        # nginx -T labels each effective included file. Tokenize comments and quoted
        # names; decline regex names conservatively rather than interpreting PCRE.
        import shlex, fnmatch
        sections=re.split(r'^# configuration file (.+):\s*$',text,flags=re.M)
        conflicts=[]; managed_names=0
        require(len(sections)>1,'nginx -T returned no parseable effective files')
        for i in range(1,len(sections),2):
            filename,body=sections[i:i+2]
            lexer=shlex.shlex(body,posix=True,punctuation_chars=';{}')
            lexer.whitespace_split=True; lexer.commenters='#'
            tokens=[]
            for token in lexer:
                if token and all(c in ';{}' for c in token): tokens.extend(token)
                else: tokens.append(token)
            j=0
            while j<len(tokens):
                if tokens[j]!='server_name': j+=1; continue
                end=j+1
                while end<len(tokens) and tokens[end]!=';': end+=1
                require(end<len(tokens),'cannot parse server_name in '+filename)
                for name in tokens[j+1:end]:
                    n=name.lower()
                    match=n.startswith('~') or n==domain or (n.startswith('.') and (domain==n[1:] or domain.endswith(n))) or ('*' in n and fnmatch.fnmatchcase(domain,n))
                    if match:
                        if pathlib.Path(filename).resolve()==managed and '# Managed by dns-over-https-setup v2' in body and n==domain:
                            managed_names+=1
                        else: conflicts.append(f'{filename}: server_name {name}')
                j=end+1
        require(managed_names<=1,'managed site declares hostname more than once')
        require(not conflicts,'hostname conflicts in effective nginx configuration:\n  '+'\n  '.join(conflicts)+'\nAdministrator must resolve these explicitly; no vhost was edited.')
    elif op == 'previous':
        f=pathlib.Path(a[0])
        if f.exists():
            values=[line[7:] for line in f.read_text().splitlines() if line.startswith('domain=')]
            require(len(values)==1 and values[0]==a[1], 'existing single-instance hostname differs or config is malformed; migrate manually before rerunning')
    elif op == 'probe':
        domain,connect,p,query=a; p=int(p)
        tid=secrets.randbelow(65536)
        qname=b''.join(bytes([len(x)])+x.encode('ascii') for x in query.split('.'))+b'\0'
        question=qname+struct.pack('!HH',1,1)
        wire=struct.pack('!HHHHHH',tid,0x0100,1,0,0,0)+question
        # Connect locally but validate the public certificate and SNI hostname.
        context=ssl.create_default_context()
        with socket.create_connection((connect,p),timeout=5) as raw:
            with context.wrap_socket(raw,server_hostname=domain) as sock:
                sock.settimeout(5)
                request=(f'POST /dns-query HTTP/1.1\r\nHost: {domain}\r\nContent-Type: application/dns-message\r\nAccept: application/dns-message\r\nContent-Length: {len(wire)}\r\nConnection: close\r\n\r\n').encode()+wire
                sock.sendall(request); response=http.client.HTTPResponse(sock); response.begin()
                require(response.status==200,f'DoH HTTP status {response.status}')
                require(response.getheader('Content-Type','').split(';')[0].strip().lower()=='application/dns-message','wrong DoH content type')
                body=response.read(65536)
        require(12<=len(body)<=65535,'invalid DNS message length')
        ident,flags,qd,an,ns,ar=struct.unpack('!HHHHHH',body[:12])
        require(ident==tid and flags&0x8000 and not flags&0x7800 and not flags&0x0200 and flags&15==0 and qd==1 and an>0,'DNS error, truncated response or no answer')
        def name_at(offset, seen=None):
            seen=set() if seen is None else seen; labels=[]; end=None
            while True:
                require(offset<len(body) and offset not in seen,'invalid DNS name'); seen.add(offset)
                n=body[offset]; offset+=1
                if n&0xc0==0xc0:
                    require(offset<len(body),'truncated pointer'); ptr=((n&63)<<8)|body[offset]
                    tail,_=name_at(ptr,seen); labels+=tail; end=offset+1; break
                require(n<=63 and offset+n<=len(body),'invalid DNS label')
                if not n: break
                labels.append(body[offset:offset+n].lower()); offset+=n
            return labels, end or offset
        labels,off=name_at(12)
        require(labels==[s.encode().lower() for s in query.split('.')],'DNS question mismatch')
        require(body[off:off+4]==struct.pack('!HH',1,1),'DNS question type mismatch'); off+=4
        answers=[]
        for index in range(an+ns+ar):
            _,off=name_at(off); require(off+10<=len(body),'truncated DNS record')
            typ,cls,ttl,size=struct.unpack('!HHIH',body[off:off+10]); off+=10
            require(off+size<=len(body),'truncated DNS data')
            if index<an: answers.append((typ,cls,size))
            off+=size
        require(off==len(body) and (1,1,4) in answers,'missing A answer or trailing DNS data')
    else: raise ValueError('unknown helper operation')
except Exception as e:
    print(f'ERROR: {op}: {e}',file=sys.stderr); sys.exit(1)
PY
}

validate_domain() { helper domain "$1"; }
validate_port() { helper port "$1"; }
validate_ip_port() { helper upstream "$1"; }
validate_cidrs() { helper cidrs "$1"; }

download() {
    timeout 100 curl --fail --silent --show-error --location --max-redirs 4 \
        --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 90 \
        --retry 1 --max-filesize 100000000 "$1" -o "$2"
}

check_os() {
    local ID VERSION_ID
    [[ -r /etc/os-release ]] || fail 'Cannot determine OS.'
    . /etc/os-release
    [[ $ID == debian && ${VERSION_ID%%.*} =~ ^[0-9]+$ && ${VERSION_ID%%.*} -ge 11 ]] || fail 'Debian 11 or later is required.'
}
check_dependencies() {
    local cmd
    for cmd in python3 nginx openssl curl timeout flock mktemp install cp mv readlink realpath stat cmp sha256sum dpkg service update-rc.d start-stop-daemon pidof sed grep dirname mkdir rm ln sleep touch chmod; do
        command -v "$cmd" >/dev/null || fail "Missing $cmd. See DNS-OVER-HTTPS.md for prerequisites."
    done
    nginx -t || fail 'Fix existing nginx configuration first.'
    [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]] || fail 'Debian sites-available/sites-enabled layout is required.'
}

check_conflicts() {
    nginx -T >"$work/nginx.effective" 2>"$work/nginx.diagnostics" || fail 'nginx -T failed; fix existing configuration.'
    # Warnings can mean nginx already ignored a duplicate server. Never continue.
    if [[ -s $work/nginx.diagnostics ]]; then
        if /bin/grep -Ei 'conflicting server name|\[warn\]|\[emerg\]' "$work/nginx.diagnostics" >&2; then
            fail 'Resolve nginx warnings/conflicting names before continuing (nginx -T).'
        fi
    fi
    helper conflicts "$work/nginx.effective" "$domain" "$site" || fail 'Resolve the named nginx conflicts before rerunning. No unrelated site will be removed.'
}

choose_binary() {
    bin=$(command -v dnsproxy || true)
    if [[ -n $bin ]]; then
        bin=$(realpath "$bin"); helper path "$bin"
        printf 'Preserving installed dnsproxy: %s\n' "$bin"
        if ! confirm 'Download and replace this executable with an explicitly pinned release?'; then
            timeout 10 "$bin" --version || fail 'Installed dnsproxy cannot execute on this kernel/CPU.'
            return
        fi
        [[ $bin == /usr/local/bin/dnsproxy ]] || fail 'Refusing to replace a package-owned/custom path. Manage that executable separately.'
    else
        bin=/usr/local/bin/dnsproxy
    fi
    version=$(ask 'Explicit dnsproxy release tag (vX.Y.Z; no latest/default)')
    helper release "$version"
    local arch asset base
    arch=$(dpkg --print-architecture)
    case $arch in
        amd64) arch=amd64 ;; arm64) arch=arm64 ;; armhf) arch=arm7 ;;
        armel) arch=arm5 ;; i386) arch=386 ;; *) fail "Unsupported architecture: $arch" ;;
    esac
    asset="dnsproxy-linux-${arch}-${version}.tar.gz"
    base="https://github.com/AdguardTeam/dnsproxy/releases/download/$version"
    download "https://api.github.com/repos/AdguardTeam/dnsproxy/releases/tags/$version" "$work/release.json"
    download "$base/$asset" "$work/release.tar.gz"
    helper digest "$work/release.json" "$asset" "$version" "$work/release.tar.gz"
    helper extract "$work/release.tar.gz" "$work/dnsproxy"
    timeout 10 "$work/dnsproxy" --version || fail 'Staged executable is incompatible with this CPU/kernel. Original binary is unchanged; choose a compatible release.'
    candidate="$work/dnsproxy"
}

validate_certificate() {
    [[ -s $cert && -s $key ]] || fail 'Certificate or key does not exist.'
    timeout 10 openssl x509 -in "$cert" -noout -checkend 604800 || fail 'Certificate expires within seven days.'
    timeout 10 openssl x509 -in "$cert" -noout -checkhost "$domain" >"$work/checkhost" || fail 'Certificate does not cover hostname.'
    /bin/grep -qF "Hostname $domain does match certificate" "$work/checkhost" || fail 'Certificate does not cover hostname.'
    timeout 10 openssl x509 -in "$cert" -pubkey -noout >"$work/cert.pub"
    timeout 10 openssl pkey -in "$key" -passin pass: -pubout >"$work/key.pub" || fail 'Key must be readable and unencrypted.'
    cmp -s "$work/cert.pub" "$work/key.pub" || fail 'Certificate/private key mismatch.'
}

renewal_scheduler() {
    local timer
    timer=$(ask 'Renewal systemd timer name, or cron for an existing root cron renewal job' cron)
    if [[ $timer == cron ]]; then
        pidof cron >/dev/null || fail 'cron is not running; enable the renewal scheduler first.'
        # Require root-owned, non-writable scheduler files and an actual renewal command.
        python3 - <<'PY'
import pathlib,re,stat
files=[pathlib.Path('/etc/crontab')]+list(pathlib.Path('/etc/cron.d').glob('*'))
for f in files:
    if not f.is_file() or f.is_symlink(): continue
    st=f.stat()
    if st.st_uid or st.st_mode & 0o022: continue
    for line in f.read_text().splitlines():
        s=line.strip()
        if not s or s.startswith('#'): continue
        fields=s.split(None,6)
        if len(fields)==7 and fields[5]=='root' and re.search(r'\bcertbot\s+(?:-[A-Za-z][A-Za-z-]*\s+)*renew\b',fields[6]):
            raise SystemExit(0)
raise SystemExit('ERROR: no safe root certbot renew entry in /etc/crontab or /etc/cron.d')
PY
    else
        [[ $timer =~ ^[A-Za-z0-9_.@-]+\.timer$ ]] || fail 'Invalid timer name.'
        [[ $init == systemd ]] || fail 'A systemd timer cannot run under SysVinit.'
        systemctl is-enabled --quiet "$timer" && systemctl is-active --quiet "$timer" || fail 'Renewal timer must be enabled and active.'
        local unit
        unit=$(systemctl show "$timer" --property=Triggers --value)
        [[ $unit =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || fail 'Timer must trigger exactly one renewal service.'
        systemctl cat "$unit" >"$work/renewal-service"
        /bin/grep -Eq '^ExecStart=.*certbot[[:space:]]+(-[[:alpha:]][[:alpha:]-]*[[:space:]]+)*renew([[:space:]]|$)' "$work/renewal-service" || fail 'Timer service must directly run certbot renew; wrapper schedulers need manual integration.'
    fi
}

ensure_cert() {
    local mode webroot email
    mode=$(ask 'Certificate mode: existing or webroot (never nginx installer)' existing)
    cert=$(ask 'Full-chain PEM path' "/etc/letsencrypt/live/$domain/fullchain.pem")
    key=$(ask 'Unencrypted private-key PEM path' "/etc/letsencrypt/live/$domain/privkey.pem")
    helper path "$cert"; helper path "$key"
    case $mode in
        existing) ;;
        webroot)
            command -v certbot >/dev/null || fail 'Install certbot first.'
            [[ $cert == "/etc/letsencrypt/live/$domain/fullchain.pem" && $key == "/etc/letsencrypt/live/$domain/privkey.pem" ]] || fail 'Webroot mode requires the standard hostname lineage paths.'
            webroot=$(ask 'Already served HTTP-01 webroot directory (this script does not configure port 80)')
            helper path "$webroot"; [[ -d $webroot ]] || fail 'Webroot directory missing.'
            email=$(ask 'ACME contact email')
            [[ $email =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$ ]] || fail 'Invalid email.'
            confirm 'Confirm this exact webroot is already publicly served for /.well-known/acme-challenge/ on this hostname and accept ACME terms?' || fail 'Cancelled.'
            timeout 300 certbot certonly --webroot -w "$webroot" --cert-name "$domain" -d "$domain" --non-interactive --agree-tos --email "$email" || fail 'Certificate issuance failed; nginx was not changed.'
            ;;
        *) fail 'Choose existing or webroot.' ;;
    esac
    validate_certificate
    printf '%s\n' 'For DNS-01 use an externally provisioned certificate; configure its renewal before continuing.'
    renewal_scheduler || fail 'Renewal scheduler validation failed.'
    confirm 'Confirm the scheduler renews this certificate and runs /etc/letsencrypt/renewal-hooks/deploy/dnsproxy-doh (RENEWED_LINEAGE set to its certificate directory)?' || fail 'Configure renewal integration first.'
}

# Every replaced path is snapshotted, including symlinks. No recursive nginx edits.
snapshot() {
    local target=$1 idx=${#targets[@]}
    if [[ -e $target || -L $target ]]; then
        cp -a -- "$target" "$backup/$idx"
        existed+=(yes)
    else
        existed+=(no)
    fi
    targets+=("$target")
    printf '%s\t%s\t%s\n' "$idx" "${existed[idx]}" "$target" >>"$backup/manifest.tsv"
}
check_owned() {
    local target=$1
    [[ ! -e $target && ! -L $target ]] && return 0
    [[ ! -L $target && -f $target ]] || fail "Refusing non-regular managed target: $target"
    if ! /bin/grep -qFx '# Managed by dns-over-https-setup v2' "$target"; then
        printf 'Unmanaged/legacy target: %s\n' "$target" >&2
        confirm "Explicitly adopt and back up $target?" || fail 'Adoption declined; nothing was changed.'
    fi
}
put() {
    local source=$1 target=$2 mode=$3 tmp
    snapshot "$target"
    tmp=$(mktemp "${target}.stage.XXXXXX")
    install -m "$mode" "$source" "$tmp"
    mv -fT -- "$tmp" "$target"
}
backend() {
    if [[ $init == systemd ]]; then timeout 45 systemctl "$1" dnsproxy-doh.service 9>&-
    else timeout 45 service dnsproxy-doh "$1" 9>&-; fi
}
reload_nginx() {
    nginx -t || return
    if [[ $init == systemd ]]; then timeout 30 systemctl reload nginx
    else timeout 30 service nginx reload; fi
}
rollback() {
    local i target
    printf 'Activation failed; restoring snapshots from %s\n' "$backup" >&2
    backend stop || printf 'WARNING: failed to stop new backend. Check manually.\n' >&2
    if [[ $registered == yes && $previous_enabled == no ]]; then
        if [[ $init == systemd ]]; then systemctl disable dnsproxy-doh.service || true
        else update-rc.d -f dnsproxy-doh remove || true; fi
    fi
    for ((i=${#targets[@]}-1;i>=0;i--)); do
        target=${targets[i]}
        rm -f -- "$target"
        if [[ ${existed[i]} == yes ]]; then cp -a -- "$backup/$i" "$target" || printf 'RESTORE FAILED: %s\n' "$target" >&2; fi
    done
    if [[ $init == systemd ]]; then systemctl daemon-reload || true; fi
    if [[ $previous_active == yes ]]; then backend restart || printf 'WARNING: original backend restart failed.\n' >&2; fi
    reload_nginx || printf 'WARNING: restored nginx reload failed; inspect nginx -t.\n' >&2
}
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ ${transaction:-no} == yes ]]; then rollback; fi
    [[ -z ${work:-} ]] || rm -rf -- "$work"
    exit "$status"
}

stage_files() {
    local acl
    {
        printf '%s\n' '#!/bin/bash' '# Managed by dns-over-https-setup v2' 'set -euo pipefail'
        declare -f helper
        printf '%s\n' 'helper probe "$@"'
    } >"$work/probe"
    cat >"$work/runner" <<EOF
#!/bin/sh
# Managed by dns-over-https-setup v2
# Do not let the SysV background process inherit the installer/renewal lock.
exec 9>&-
exec '$bin' -l 127.0.0.1 -p 0 --https-port=$port --tls-crt='$cert' --tls-key='$key' -u '$upstream' --cache --refuse-any -r 20
EOF
    cat >"$work/systemd" <<'EOF'
# Managed by dns-over-https-setup v2
[Unit]
Description=DNS-over-HTTPS backend
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/etc/bkcfg/dns-over-https/run
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
[Install]
WantedBy=multi-user.target
EOF
    cat >"$work/sysv" <<'EOF'
#!/bin/sh
# Managed by dns-over-https-setup v2
### BEGIN INIT INFO
# Provides:          dnsproxy-doh
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: DNS-over-HTTPS backend
### END INIT INFO
set -eu
PID=/run/dnsproxy-doh.pid
RUN=/etc/bkcfg/dns-over-https/run
BIN=$(sed -n "s/^exec '\([^']*\)'.*/\1/p" "$RUN")
alive() {
    [ -r "$PID" ] || return 1
    read -r p <"$PID"
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    [ "$p" -gt 1 ] && kill -0 "$p" 2>/dev/null && [ "$(readlink "/proc/$p/exe")" = "$BIN" ]
}
case "${1:-}" in
start)
    alive && exit 0
    if [ -e "$PID" ]; then
        read -r stale <"$PID" || stale=''
        case "$stale" in ''|*[!0-9]*) echo 'Invalid PID file; inspect manually' >&2; exit 1 ;; esac
        if kill -0 "$stale" 2>/dev/null; then echo 'PID ownership mismatch; inspect manually' >&2; exit 1; fi
        rm -f "$PID"
    fi
    touch /var/log/dnsproxy-doh.log; chmod 600 /var/log/dnsproxy-doh.log
    start-stop-daemon --start --background --make-pidfile --pidfile "$PID" --startas "$RUN" --no-close >>/var/log/dnsproxy-doh.log 2>&1
    count=0
    while [ "$count" -lt 5 ]; do sleep 1; count=$((count+1)); alive || { echo 'Startup failed; see /var/log/dnsproxy-doh.log' >&2; exit 1; }; done
    ;;
stop)
    if [ ! -e "$PID" ]; then exit 0; fi
    if ! alive; then
        read -r stale <"$PID" || exit 1
        case "$stale" in ''|*[!0-9]*) exit 1 ;; esac
        if kill -0 "$stale" 2>/dev/null; then echo 'Refusing PID ownership mismatch' >&2; exit 1; fi
        rm -f "$PID"; exit 0
    fi
    start-stop-daemon --stop --pidfile "$PID" --exec "$BIN" --retry TERM/15/KILL/5
    if kill -0 "$p" 2>/dev/null; then echo 'Backend did not stop' >&2; exit 1; fi
    rm -f "$PID"
    ;;
restart) "$0" stop; "$0" start ;;
status) alive ;;
*) echo 'Usage: dnsproxy-doh {start|stop|restart|status}' >&2; exit 2 ;;
esac
EOF
    {
        cat <<EOF
# Managed by dns-over-https-setup v2
server {
    listen 443 ssl;
    server_name $domain;
    ssl_certificate $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    location = /dns-query {
        satisfy all;
EOF
        for acl in $allowed_cidrs; do printf '        allow %s;\n' "$acl"; done
        cat <<EOF
        allow 127.0.0.1/32; # local authenticated-certificate health probe
        deny all;
        client_max_body_size 64k;
        proxy_connect_timeout 5s;
        proxy_read_timeout 10s;
        proxy_send_timeout 10s;
        proxy_set_header Host $domain;
        proxy_ssl_server_name on;
        proxy_ssl_name $domain;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 5;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_pass https://127.0.0.1:$port/dns-query;
    }
    location / { return 404; }
}
EOF
    } >"$work/site"
    cat >"$work/hook" <<EOF
#!/bin/bash
# Managed by dns-over-https-setup v2
set -euo pipefail
[[ -n \${RENEWED_LINEAGE:-} ]] || exit 0
[[ \$(realpath -m "\$RENEWED_LINEAGE") == \$(realpath -m '$(dirname "$cert")') ]] || exit 0
exec 9>/run/lock/dns-over-https-setup.lock
flock -w 60 9 || exit 1
nginx -t
EOF
    if [[ $init == systemd ]]; then
        printf '%s\n' 'timeout 45 systemctl restart dnsproxy-doh.service' >>"$work/hook"
    else
        printf '%s\n' 'timeout 45 service dnsproxy-doh restart' >>"$work/hook"
    fi
    cat >>"$work/hook" <<EOF
ready=no
for attempt in 1 2 3 4 5; do
    if timeout 20 /etc/bkcfg/dns-over-https/probe '$domain' 127.0.0.1 '$port' '$query'; then ready=yes; break; fi
    sleep 1
done
[[ \$ready == yes ]] || { echo 'Renewal failed: backend DoH readiness check failed' >&2; exit 1; }
EOF
    if [[ $init == systemd ]]; then
        printf '%s\n' 'timeout 30 systemctl reload nginx' >>"$work/hook"
    else
        printf '%s\n' 'timeout 30 service nginx reload' >>"$work/hook"
    fi
    printf "timeout 20 /etc/bkcfg/dns-over-https/probe '%s' 127.0.0.1 443 '%s'\n" "$domain" "$query" >>"$work/hook"
    cat >"$work/config" <<EOF
# Managed by dns-over-https-setup v2
domain=$domain
doh_url=https://$domain/dns-query
dnsproxy_listen=127.0.0.1:$port
upstream=$upstream
allowed_cidrs=$allowed_cidrs
certificate=$cert
private_key=$key
EOF
}

main() {
    set -Eeuo pipefail
    umask 077
    [[ $# == 0 ]] || fail 'Usage: bash dns-over-https-setup.sh [--library]'
    [[ $(id -u) == 0 ]] || fail 'Run as root.'
    check_os; check_dependencies
    exec 9>/run/lock/dns-over-https-setup.lock
    flock -n 9 || fail 'Another installation or renewal hook is running.'
    work=$(mktemp -d /var/tmp/dns-over-https.XXXXXXXX)
    transaction=no; registered=no; targets=(); existed=()
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    config_dir=/etc/bkcfg/dns-over-https
    init=sysv
    [[ ! -d /run/systemd/system ]] || init=systemd
    domain=$(ask 'DoH hostname (lowercase fully qualified name)')
    validate_domain "$domain"
    site="/etc/nginx/sites-available/dns-over-https-$domain"
    enabled="/etc/nginx/sites-enabled/dns-over-https-$domain"
    hook=/etc/letsencrypt/renewal-hooks/deploy/dnsproxy-doh
    service_file=/etc/init.d/dnsproxy-doh
    [[ $init != systemd ]] || service_file=/etc/systemd/system/dnsproxy-doh.service
    helper previous "$config_dir/config.txt" "$domain"
    # Conflict inspection precedes downloads, certificate issuance and managed writes.
    check_conflicts
    for target in "$config_dir" "$config_dir/backups" /etc/bkcfg /etc/letsencrypt /etc/letsencrypt/renewal-hooks /etc/letsencrypt/renewal-hooks/deploy; do
        [[ ! -L $target ]] || fail "Symlink directory is not supported: $target"
        [[ ! -e $target || -d $target ]] || fail "Not a directory: $target"
    done
    for target in "$site" "$service_file" "$config_dir/config.txt" "$config_dir/run" "$config_dir/probe" "$hook"; do check_owned "$target"; done
    if [[ -e $enabled || -L $enabled ]]; then
        [[ -L $enabled && $(readlink -f "$enabled") == "$site" ]] || fail "Unexpected enabled-site target: $enabled"
    fi
    # A second init implementation would be an ambiguous unmanaged instance.
    if [[ $init == systemd && -e /etc/init.d/dnsproxy-doh ]] || [[ $init == sysv && -e /etc/systemd/system/dnsproxy-doh.service ]]; then
        fail 'Alternate init service exists. Resolve the duplicate service explicitly before rerunning.'
    fi
    upstream=$(ask 'Upstream IP:port (IPv6: [address]:port); no default')
    validate_ip_port "$upstream"
    port=$(ask 'Loopback backend HTTPS port' 5443); validate_port "$port"
    [[ $port != 443 ]] || fail 'Backend port must differ from nginx.'
    allowed_cidrs=$(ask 'Space-separated client CIDRs (network addresses with explicit prefixes)')
    validate_cidrs "$allowed_cidrs"
    query=$(ask 'Existing public DNS name with a resolvable A record for health check' example.com)
    validate_domain "$query"
    confirm 'Apply this single-instance configuration after certificate/binary preflight?' || fail 'Cancelled.'
    candidate=''; choose_binary
    ensure_cert
    stage_files
    # Check flags and kernel compatibility using the candidate before any replacement.
    timeout 10 "${candidate:-$bin}" --help >"$work/help" 2>&1 || fail 'dnsproxy --help failed.'
    for flag in --https-port --tls-crt --tls-key --cache --refuse-any; do
        /bin/grep -q -- "$flag" "$work/help" || fail "Installed executable lacks $flag; explicitly choose a compatible pinned release."
    done
    check_conflicts
    previous_active=no; previous_enabled=no
    if [[ $init == systemd ]]; then
        if systemctl is-active --quiet dnsproxy-doh.service; then previous_active=yes; fi
        if systemctl is-enabled --quiet dnsproxy-doh.service; then previous_enabled=yes; fi
    else
        if [[ -x $service_file ]] && timeout 10 service dnsproxy-doh status >/dev/null 2>&1; then previous_active=yes; fi
        if compgen -G '/etc/rc[2345].d/S*dnsproxy-doh' >/dev/null; then previous_enabled=yes; fi
    fi
    mkdir -p "$config_dir/backups" /etc/letsencrypt/renewal-hooks/deploy
    backup=$(mktemp -d "$config_dir/backups/transaction.XXXXXXXX")
    printf 'Rollback snapshots: %s\n' "$backup"
    transaction=yes
    # Stop under the OLD definition/binary; never signal a PID after replacing it.
    if [[ $previous_active == yes ]]; then backend stop; fi
    [[ -z $candidate ]] || put "$candidate" "$bin" 755
    put "$work/runner" "$config_dir/run" 700
    put "$work/probe" "$config_dir/probe" 700
    if [[ $init == systemd ]]; then put "$work/systemd" "$service_file" 644
    else put "$work/sysv" "$service_file" 755; fi
    put "$work/site" "$site" 644
    snapshot "$enabled"
    link_stage=$(mktemp "${enabled}.stage.XXXXXX")
    rm -f "$link_stage"
    ln -s "$site" "$link_stage"
    mv -fT "$link_stage" "$enabled"
    put "$work/hook" "$hook" 700
    put "$work/config" "$config_dir/config.txt" 600
    nginx -t
    if [[ $init == systemd ]]; then systemctl daemon-reload; fi
    backend restart
    sleep 2
    backend status >/dev/null
    # Full bounded DNS query on backend, then on nginx after reload.
    timeout 20 bash "$0" --probe "$domain" 127.0.0.1 "$port" "$query"
    reload_nginx
    timeout 20 bash "$0" --probe "$domain" 127.0.0.1 443 "$query"
    registered=yes
    if [[ $init == systemd ]]; then systemctl enable dnsproxy-doh.service
    else update-rc.d dnsproxy-doh defaults; fi
    transaction=no
    printf 'Configured https://%s/dns-query\nConfiguration: %s/config.txt\nBackups: %s\n' "$domain" "$config_dir" "$backup"
    printf '%s\n' 'Local TLS/HTTP/DNS checks passed. Verify client routing, firewall and ACLs from an allowed client; no public firewall changes were made.'
}

# --probe is non-mutating and does not accept environment overrides.
if [[ ${1:-} == --library ]]; then
    [[ $# == 1 ]] || { printf 'Only --library is accepted in library mode.\n' >&2; return 2 2>/dev/null || exit 2; }
elif [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'Source only with: source dns-over-https-setup.sh --library\n' >&2
    return 2
elif [[ ${1:-} == --probe && $# == 5 ]]; then
    shift; helper probe "$@"
else
    main "$@"
fi
