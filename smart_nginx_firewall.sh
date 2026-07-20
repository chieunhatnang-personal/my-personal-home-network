#!/bin/sh
set -eu

CONFIG_DIR="/etc/bkcfg/smart_nginx_firewall"
STATE_FILE="$CONFIG_DIR/ip.json"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_FILE="/var/log/smart_nginx_firewall.log"
INSTALL_TARGET="/usr/local/bin/smart_nginx_firewall"
INSTALL_LINK="/usr/local/bin/snf"
CRON_FILE="/etc/cron.d/smart_nginx_firewall"

case "${1:-}" in
  ""|help|-h|--help|install|scan|dry-run|expire|list-blocked|list-whitelist|unblock|whitelist|status)
    ;;
  *)
    echo "Unknown command: $1" >&2
    echo "Run: $0 help" >&2
    exit 2
    ;;
esac

if [ "${1:-}" != "install" ] && [ ! -d "$CONFIG_DIR" ] && [ -t 0 ]; then
  printf "smart_nginx_firewall is not installed. Install now? [y/N] "
  read ans
  case "$ans" in
    y|Y|yes|YES) exec "$0" install ;;
  esac
fi

SNF_SCRIPT_PATH="$0" python3 - "$@" <<'PY'
import gzip
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

CONFIG_DIR = Path("/etc/bkcfg/smart_nginx_firewall")
STATE_FILE = CONFIG_DIR / "ip.json"
CONFIG_FILE = CONFIG_DIR / "config.json"
LOG_FILE = Path("/var/log/smart_nginx_firewall.log")
INSTALL_TARGET = Path("/usr/local/bin/smart_nginx_firewall")
INSTALL_LINK = Path("/usr/local/bin/snf")
CRON_FILE = Path("/etc/cron.d/smart_nginx_firewall")
IPSET_NAME = "snf_blacklist"
IPTABLES_CHAIN = "SNF_BLOCK"

DEFAULT_CONFIG = {
    "version": 1,
    "nginx_log_glob": "/var/log/nginx/access.log*",
    "scan_hours": 24,
    "block_days": 7,
    "threshold_score": 25,
    "threshold_bad_requests": 40,
    "minimum_non_wpad_signals": 3,
    "minimum_bad_signal_rate": 0.02,
    "minimum_good_requests_for_rate_check": 100,
    "max_candidates_to_apply": 200,
    "use_ipset_if_available": True,
    "private_ranges_always_allow": True
}

DEFAULT_STATE = {
    "version": 1,
    "blacklisted": [],
    "whitelisted": [
        {"ip": "10.0.0.0/8", "reason": "private range", "added_at": None},
        {"ip": "172.16.0.0/12", "reason": "private range", "added_at": None},
        {"ip": "192.168.0.0/16", "reason": "private range", "added_at": None},
        {"ip": "127.0.0.0/8", "reason": "localhost", "added_at": None}
    ]
}

LOG_RE = re.compile(
    r'(?P<ip>\S+) \S+ \S+ \[(?P<ts>[^\]]+)\] "(?P<req>[^"]*)" '
    r'(?P<status>\d{3}) (?P<body>\S+) "(?P<ref>[^"]*)" "(?P<ua>[^"]*)"'
)

BAD_PATTERNS = [
    ("wordpress", 10, re.compile(r"/(wp-admin|wp-login\.php|xmlrpc\.php|wp-content|wp-includes)", re.I)),
    ("secret-file", 10, re.compile(r"/(\.env|config\.json|config\.php|backup|dump|database|db\.|\.aws|credentials)", re.I)),
    ("vcs-leak", 10, re.compile(r"/(\.git|\.svn|\.hg)", re.I)),
    ("camera-router", 8, re.compile(r"/(ISAPI|SDK|HNAP1|onvif|cgi-bin/luci|boaform)", re.I)),
    ("php-probe", 7, re.compile(r"(\.php|/phpmyadmin|/pma/|phpunit|eval-stdin)", re.I)),
    ("traversal-injection", 8, re.compile(r"(\.\.|%2e|%2f|%5c|/etc/passwd|union.*select|<script)", re.I)),
    ("wpad", 1, re.compile(r"/wpad\.dat", re.I)),
]

SUSPICIOUS_METHODS = {
    "PROPFIND": 8,
    "OPTIONS": 2,
    "TRACE": 8,
    "CONNECT": 8,
    "LEAKIX": 10,
}
NORMAL_METHODS = {"GET", "POST", "HEAD"}

def now_utc():
    return datetime.now(timezone.utc)

def iso(dt):
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def parse_iso(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))

def run(cmd, check=False):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=check)

def have(cmd):
    return shutil.which(cmd) is not None

def load_json(path, default):
    if not path.exists():
        return json.loads(json.dumps(default))
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)

def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp.replace(path)

def load_config():
    cfg = load_json(CONFIG_FILE, DEFAULT_CONFIG)
    merged = dict(DEFAULT_CONFIG)
    merged.update(cfg)
    return merged

def load_state():
    state = load_json(STATE_FILE, DEFAULT_STATE)
    state.setdefault("version", 1)
    state.setdefault("blacklisted", [])
    state.setdefault("whitelisted", [])
    return state

def is_ip(value):
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False

def is_whitelisted(ip, state, cfg):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True
    if cfg.get("private_ranges_always_allow", True) and addr.is_private:
        return True
    for row in state.get("whitelisted", []):
        item = row.get("ip", "")
        try:
            if "/" in item:
                if addr in ipaddress.ip_network(item, strict=False):
                    return True
            elif addr == ipaddress.ip_address(item):
                return True
        except ValueError:
            continue
    return False

def block_lookup(state):
    return {row["ip"]: row for row in state.get("blacklisted", []) if row.get("ip")}

def log_open(path):
    if str(path).endswith(".gz"):
        return gzip.open(path, "rt", errors="replace")
    return open(path, "rt", errors="replace")

def parse_nginx_time(value):
    return datetime.strptime(value, "%d/%b/%Y:%H:%M:%S %z")

class Stat:
    def __init__(self):
        self.total = 0
        self.status = Counter()
        self.methods = Counter()
        self.paths = Counter()
        self.bad_reasons = Counter()
        self.bad_requests = 0
        self.good_requests = 0
        self.wpad_only_count = 0
        self.first_seen = None
        self.last_seen = None

    def add(self, ts, method, path, status, req, ua):
        self.total += 1
        self.status[status] += 1
        self.methods[method] += 1
        self.paths[path] += 1
        self.first_seen = ts if self.first_seen is None else min(self.first_seen, ts)
        self.last_seen = ts if self.last_seen is None else max(self.last_seen, ts)
        if status in {"200", "201", "204", "206", "301", "302", "304"}:
            self.good_requests += 1
        if status in {"400", "401", "403", "404", "405"}:
            self.bad_requests += 1

        hay = f"{method} {path} {req} {ua}"
        matched = False
        for name, _weight, rx in BAD_PATTERNS:
            if rx.search(hay):
                self.bad_reasons[name] += 1
                matched = True
        if method in SUSPICIOUS_METHODS:
            self.bad_reasons[f"method:{method}"] += 1
            matched = True
        elif method and method not in NORMAL_METHODS:
            self.bad_reasons["method:garbage"] += 1
            matched = True
        if path == "/wpad.dat" and matched and len(self.bad_reasons) == 1:
            self.wpad_only_count += 1

    def score(self):
        score = 0
        score += min(self.status["404"] + self.status["400"], 20)
        score += min(self.status["401"] + self.status["403"] + self.status["405"], 10)
        for name, weight, _rx in BAD_PATTERNS:
            count = self.bad_reasons[name]
            if name == "wpad":
                score += min(count * weight, 5)
            else:
                score += min(count * weight, 60)
        for name, count in self.bad_reasons.items():
            if name.startswith("method:"):
                method = name.split(":", 1)[1]
                score += min(count * SUSPICIOUS_METHODS.get(method, 5), 40)
        distinct_bad_paths = sum(1 for p in self.paths if any(rx.search(p) for _n, _w, rx in BAD_PATTERNS))
        score += min(distinct_bad_paths * 3, 30)
        return score

    def non_wpad_signals(self):
        return sum(v for k, v in self.bad_reasons.items() if k != "wpad")

    def bad_signal_count(self):
        return self.bad_requests + self.non_wpad_signals()

    def bad_signal_rate(self):
        total = self.good_requests + self.bad_signal_count()
        if total <= 0:
            return 0.0
        return self.bad_signal_count() / total

    def should_block(self, cfg):
        score = self.score()
        non_wpad_signals = self.non_wpad_signals()
        if non_wpad_signals < int(cfg.get("minimum_non_wpad_signals", 3)):
            return False
        suspicious_paths = [
            p for p in self.paths
            if p != "/wpad.dat" and any(rx.search(p) for name, _w, rx in BAD_PATTERNS if name != "wpad")
        ]
        if self.total < 5 and len(suspicious_paths) <= 1 and self.bad_requests < 3:
            return False
        minimum_good = int(cfg.get("minimum_good_requests_for_rate_check", 100))
        minimum_rate = float(cfg.get("minimum_bad_signal_rate", 0.02))
        if self.good_requests >= minimum_good and self.bad_signal_rate() < minimum_rate:
            return False
        if score >= int(cfg["threshold_score"]):
            return True
        if self.bad_requests >= int(cfg["threshold_bad_requests"]) and self.good_requests <= 2:
            return True
        return False

    def reason(self):
        parts = [
            f"score={self.score()}",
            f"bad={self.bad_requests}",
            f"good={self.good_requests}",
            f"bad_signal_rate={self.bad_signal_rate():.4f}"
        ]
        if self.status:
            parts.append("status=" + ",".join(f"{k}:{v}" for k, v in self.status.most_common(4)))
        if self.bad_reasons:
            parts.append("signals=" + ",".join(f"{k}:{v}" for k, v in self.bad_reasons.most_common(5)))
        top_paths = [p for p, _c in self.paths.most_common(5)]
        if top_paths:
            parts.append("paths=" + ",".join(top_paths)[:220])
        return "; ".join(parts)

def scan_logs(cfg):
    cutoff = now_utc() - timedelta(hours=int(cfg["scan_hours"]))
    stats = defaultdict(Stat)
    import glob
    for name in sorted(glob.glob(cfg["nginx_log_glob"])):
        try:
            fh = log_open(name)
        except OSError:
            continue
        with fh:
            for line in fh:
                m = LOG_RE.match(line.rstrip("\n"))
                if not m:
                    continue
                try:
                    ts = parse_nginx_time(m.group("ts"))
                except ValueError:
                    continue
                if ts < cutoff:
                    continue
                ip = m.group("ip")
                if not is_ip(ip):
                    continue
                req = m.group("req")
                parts = req.split()
                method = parts[0] if len(parts) >= 1 else ""
                target = parts[1] if len(parts) >= 2 else req
                path = target.split("?", 1)[0]
                stats[ip].add(ts, method, path, m.group("status"), req, m.group("ua"))
    return stats

def firewall_backend(cfg):
    if cfg.get("use_ipset_if_available", True) and have("ipset"):
        return "ipset"
    return "iptables"

def ensure_firewall(cfg):
    backend = firewall_backend(cfg)
    if backend == "ipset":
        run(["ipset", "create", IPSET_NAME, "hash:ip", "timeout", "604800", "-exist"])
        check = run(["iptables", "-C", "INPUT", "-m", "set", "--match-set", IPSET_NAME, "src", "-j", "DROP"])
        if check.returncode != 0:
            run(["iptables", "-I", "INPUT", "1", "-m", "set", "--match-set", IPSET_NAME, "src", "-j", "DROP"])
    else:
        run(["iptables", "-N", IPTABLES_CHAIN])
        check = run(["iptables", "-C", "INPUT", "-j", IPTABLES_CHAIN])
        if check.returncode != 0:
            run(["iptables", "-I", "INPUT", "1", "-j", IPTABLES_CHAIN])
    return backend

def firewall_add(ip, seconds, cfg):
    backend = ensure_firewall(cfg)
    if backend == "ipset":
        run(["ipset", "add", IPSET_NAME, ip, "timeout", str(max(60, int(seconds))), "-exist"])
    else:
        check = run(["iptables", "-C", IPTABLES_CHAIN, "-s", ip, "-j", "DROP"])
        if check.returncode != 0:
            run(["iptables", "-A", IPTABLES_CHAIN, "-s", ip, "-j", "DROP"])

def firewall_del(ip, cfg):
    backend = firewall_backend(cfg)
    if backend == "ipset":
        run(["ipset", "del", IPSET_NAME, ip])
    else:
        while run(["iptables", "-C", IPTABLES_CHAIN, "-s", ip, "-j", "DROP"]).returncode == 0:
            run(["iptables", "-D", IPTABLES_CHAIN, "-s", ip, "-j", "DROP"])

def expire_blocks(state, cfg, apply=True):
    now = now_utc()
    kept = []
    expired = []
    for row in state.get("blacklisted", []):
        try:
            exp = parse_iso(row["expires_at"])
        except Exception:
            expired.append(row)
            continue
        if exp <= now:
            expired.append(row)
        else:
            kept.append(row)
    state["blacklisted"] = kept
    if apply:
        for row in expired:
            firewall_del(row["ip"], cfg)
        ensure_firewall(cfg)
        for row in kept:
            seconds = max(60, int((parse_iso(row["expires_at"]) - now).total_seconds()))
            firewall_add(row["ip"], seconds, cfg)
    return expired

def cmd_install():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_FILE.exists():
        save_json(CONFIG_FILE, DEFAULT_CONFIG)
    if not STATE_FILE.exists():
        save_json(STATE_FILE, DEFAULT_STATE)
    src = Path(os.environ.get("SNF_SCRIPT_PATH", sys.argv[0])).resolve()
    if src != INSTALL_TARGET:
        shutil.copy2(src, INSTALL_TARGET)
    INSTALL_TARGET.chmod(0o755)
    if INSTALL_LINK.exists() or INSTALL_LINK.is_symlink():
        if INSTALL_LINK.resolve() != INSTALL_TARGET:
            INSTALL_LINK.unlink()
    if not INSTALL_LINK.exists():
        INSTALL_LINK.symlink_to(INSTALL_TARGET)
    cron = (
        "SHELL=/bin/sh\n"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n"
        "50 23 * * * root /usr/local/bin/snf scan >> /var/log/smart_nginx_firewall.log 2>&1\n"
        "@reboot root /usr/local/bin/snf expire >> /var/log/smart_nginx_firewall.log 2>&1\n"
    )
    CRON_FILE.write_text(cron, encoding="utf-8")
    os.chmod(CRON_FILE, 0o644)
    cfg = load_config()
    state = load_state()
    expire_blocks(state, cfg, apply=True)
    save_json(STATE_FILE, state)
    print(f"Installed {INSTALL_TARGET}")
    print(f"Symlinked {INSTALL_LINK}")
    print(f"State: {STATE_FILE}")
    print(f"Config: {CONFIG_FILE}")
    print(f"Cron: {CRON_FILE}")
    print(f"Firewall backend: {firewall_backend(cfg)}")

def candidate_rows(cfg, state):
    stats = scan_logs(cfg)
    existing = block_lookup(state)
    rows = []
    for ip, st in stats.items():
        if is_whitelisted(ip, state, cfg):
            continue
        if ip in existing:
            continue
        if st.should_block(cfg):
            rows.append((st.score(), ip, st))
    rows.sort(reverse=True, key=lambda item: item[0])
    return rows

def cmd_dry_run():
    cfg = load_config()
    state = load_state()
    expired = expire_blocks(state, cfg, apply=False)
    rows = candidate_rows(cfg, state)
    print(
        f"scan_hours={cfg['scan_hours']} "
        f"threshold_score={cfg['threshold_score']} "
        f"threshold_bad_requests={cfg['threshold_bad_requests']} "
        f"minimum_bad_signal_rate={cfg['minimum_bad_signal_rate']} "
        f"minimum_good_requests_for_rate_check={cfg['minimum_good_requests_for_rate_check']}"
    )
    if expired:
        print(f"would_expire={len(expired)}")
    if not rows:
        print("No new block candidates.")
        return
    print("Candidates:")
    for score, ip, st in rows[: int(cfg["max_candidates_to_apply"])]:
        print(f"{ip}\t{st.reason()}")

def cmd_scan():
    cfg = load_config()
    state = load_state()
    expired = expire_blocks(state, cfg, apply=True)
    rows = candidate_rows(cfg, state)
    max_apply = int(cfg["max_candidates_to_apply"])
    now = now_utc()
    expires = now + timedelta(days=int(cfg["block_days"]))
    existing = block_lookup(state)
    applied = 0
    for score, ip, st in rows[:max_apply]:
        if ip in existing or is_whitelisted(ip, state, cfg):
            continue
        reason = st.reason()
        seconds = int((expires - now).total_seconds())
        firewall_add(ip, seconds, cfg)
        row = {
            "ip": ip,
            "blocked_at": iso(now),
            "expires_at": iso(expires),
            "reason": reason,
            "score": score
        }
        state["blacklisted"].append(row)
        applied += 1
        print(f"blocked {ip}: {reason}")
    save_json(STATE_FILE, state)
    print(f"expired={len(expired)} blocked={applied}")

def cmd_expire():
    cfg = load_config()
    state = load_state()
    expired = expire_blocks(state, cfg, apply=True)
    save_json(STATE_FILE, state)
    for row in expired:
        print(f"expired {row.get('ip')} blocked_at={row.get('blocked_at')} reason={row.get('reason')}")
    print(f"expired={len(expired)} active={len(state.get('blacklisted', []))}")

def cmd_list_blocked():
    state = load_state()
    rows = state.get("blacklisted", [])
    if not rows:
        print("No blocked IPs.")
        return
    for row in sorted(rows, key=lambda r: r.get("blocked_at", "")):
        print(f"{row.get('ip')}\tblocked_at={row.get('blocked_at')}\texpires_at={row.get('expires_at')}\tscore={row.get('score')}\treason={row.get('reason')}")

def cmd_list_whitelist():
    state = load_state()
    rows = state.get("whitelisted", [])
    if not rows:
        print("No whitelisted IPs.")
        return
    for row in rows:
        print(f"{row.get('ip')}\tadded_at={row.get('added_at')}\treason={row.get('reason')}")

def cmd_unblock(ip):
    if not is_ip(ip):
        raise SystemExit(f"Invalid IP: {ip}")
    cfg = load_config()
    state = load_state()
    before = len(state.get("blacklisted", []))
    state["blacklisted"] = [row for row in state.get("blacklisted", []) if row.get("ip") != ip]
    firewall_del(ip, cfg)
    save_json(STATE_FILE, state)
    print(f"unblocked {ip}" if len(state["blacklisted"]) != before else f"{ip} was not in blacklist; firewall entry removed if present")

def cmd_whitelist(args):
    if len(args) < 2 or args[0] not in {"add", "remove"}:
        raise SystemExit("Usage: snf whitelist add <ip-or-cidr> [reason] | snf whitelist remove <ip-or-cidr>")
    action, value = args[0], args[1]
    try:
        if "/" in value:
            ipaddress.ip_network(value, strict=False)
        else:
            ipaddress.ip_address(value)
    except ValueError:
        raise SystemExit(f"Invalid IP/CIDR: {value}")
    cfg = load_config()
    state = load_state()
    if action == "add":
        reason = " ".join(args[2:]) if len(args) > 2 else "manual"
        if not any(row.get("ip") == value for row in state.get("whitelisted", [])):
            state["whitelisted"].append({"ip": value, "reason": reason, "added_at": iso(now_utc())})
        if "/" not in value:
            state["blacklisted"] = [row for row in state.get("blacklisted", []) if row.get("ip") != value]
            firewall_del(value, cfg)
        save_json(STATE_FILE, state)
        print(f"whitelisted {value}")
    else:
        before = len(state.get("whitelisted", []))
        state["whitelisted"] = [row for row in state.get("whitelisted", []) if row.get("ip") != value]
        save_json(STATE_FILE, state)
        print(f"removed {value}" if len(state["whitelisted"]) != before else f"{value} was not whitelisted")

def cmd_status():
    cfg = load_config()
    state = load_state()
    print(f"config_dir={CONFIG_DIR}")
    print(f"state_file={STATE_FILE} exists={STATE_FILE.exists()}")
    print(f"config_file={CONFIG_FILE} exists={CONFIG_FILE.exists()}")
    print(f"cron_file={CRON_FILE} exists={CRON_FILE.exists()}")
    print(f"firewall_backend={firewall_backend(cfg)}")
    print(f"blocked={len(state.get('blacklisted', []))} whitelisted={len(state.get('whitelisted', []))}")
    print(
        f"scan_hours={cfg['scan_hours']} "
        f"block_days={cfg['block_days']} "
        f"threshold_score={cfg['threshold_score']} "
        f"minimum_bad_signal_rate={cfg['minimum_bad_signal_rate']} "
        f"minimum_good_requests_for_rate_check={cfg['minimum_good_requests_for_rate_check']}"
    )

def cmd_help():
    print("""smart_nginx_firewall / snf

Commands:
  snf install                         Install script, config, cron, and firewall hook
  snf dry-run                         Analyze nginx logs and show block candidates only
  snf scan                            Expire old blocks, analyze logs, and block candidates
  snf expire                          Remove expired blocks and reconcile active firewall entries
  snf list-blocked                    Show currently blocked IPs
  snf list-whitelist                  Show whitelisted IPs/CIDRs
  snf unblock <ip>                    Remove one IP from blacklist and firewall
  snf whitelist add <ip-or-cidr> [reason]
  snf whitelist remove <ip-or-cidr>
  snf status                          Show config and backend status
  snf help                            Show this help

Files:
  /etc/bkcfg/smart_nginx_firewall/ip.json
  /etc/bkcfg/smart_nginx_firewall/config.json
  /etc/cron.d/smart_nginx_firewall
""")

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd in {"help", "-h", "--help"}:
        cmd_help()
    elif cmd == "install":
        cmd_install()
    else:
        if not CONFIG_DIR.exists():
            if sys.stdin.isatty():
                ans = input("smart_nginx_firewall is not installed. Install now? [y/N] ")
                if ans.lower() in {"y", "yes"}:
                    cmd_install()
                else:
                    print("Running without installed config using defaults.")
            else:
                CONFIG_DIR.mkdir(parents=True, exist_ok=True)
                save_json(CONFIG_FILE, DEFAULT_CONFIG)
                save_json(STATE_FILE, DEFAULT_STATE)
        if cmd == "dry-run":
            cmd_dry_run()
        elif cmd == "scan":
            cmd_scan()
        elif cmd == "expire":
            cmd_expire()
        elif cmd == "list-blocked":
            cmd_list_blocked()
        elif cmd == "list-whitelist":
            cmd_list_whitelist()
        elif cmd == "unblock":
            if len(sys.argv) != 3:
                raise SystemExit("Usage: snf unblock <ip>")
            cmd_unblock(sys.argv[2])
        elif cmd == "whitelist":
            cmd_whitelist(sys.argv[2:])
        elif cmd == "status":
            cmd_status()
        else:
            raise SystemExit(f"Unknown command: {cmd}")

if __name__ == "__main__":
    main()
PY
