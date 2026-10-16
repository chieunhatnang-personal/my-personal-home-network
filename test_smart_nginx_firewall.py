#!/usr/bin/env python3
"""Regression and unit test suite for Smart Nginx Firewall (SNF)."""

import importlib.util
import os
import re
import socket
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

# Load smart_nginx_firewall.sh as a python module.
# The script is a polyglot shell/python script with:
# SNF_SCRIPT_PATH="$0" python3 - "$@" <<'PY'
# ... python code ...
# PY
SCRIPT_PATH = Path(__file__).parent / "smart_nginx_firewall.sh"
if not SCRIPT_PATH.exists():
    _alt_path = Path("/usr/local/bin/smart_nginx_firewall")
    if _alt_path.exists():
        SCRIPT_PATH = _alt_path

def load_snf_module():
    content = SCRIPT_PATH.read_text(encoding="utf-8")
    # Extract Python code between <<'PY' and PY
    m = re.search(r"<<'PY'\n(.*?)\nPY\s*$", content, re.DOTALL)
    if not m:
        raise RuntimeError("Could not find embedded Python in smart_nginx_firewall.sh")
    py_code = m.group(1)
    
    spec = importlib.util.spec_from_loader("snf_module", loader=None)
    module = importlib.util.module_from_spec(spec)
    exec(py_code, module.__dict__)
    return module

class TestSmartNginxFirewall(unittest.TestCase):
    def setUp(self):
        self.snf = load_snf_module()
        self.cfg = dict(self.snf.DEFAULT_CONFIG)
        self.cfg["minimum_bad_signal_rate"] = 0.05
        self.now = datetime.now(timezone.utc)

    def test_immich_legitimate_query_tokens_not_flagged(self):
        """TDD RED test: Legitimate Immich query tokens with %2F, %2B, %3D

        Legitimate photo/asset requests with base64/URL-encoded query tokens
        must NOT trigger 'traversal-injection' or any bad signal.
        Under the old script, %2F in query matched traversal-injection.
        """
        st = self.snf.Stat()
        test_requests = [
            (
                "GET",
                "/api/asset/thumbnail/c29tZS1hc3NldC1pZD9rZXk9YWJjZGVm%2F%2B%3D",
                "GET /api/asset/thumbnail/c29tZS1hc3NldC1pZD9rZXk9YWJjZGVm%2F%2B%3D?size=thumbnail&key=c29tZSt0b2tlbi92YWx1ZT0%3D HTTP/1.1",
                "200",
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) ImmichApp/1.100.0",
            ),
            (
                "GET",
                "/api/albums/search",
                "GET /api/albums/search?tag=vacation%2Fbeach%2Bsummer%3D HTTP/1.1",
                "204",
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) ImmichApp/1.100.0",
            ),
            (
                "GET",
                "/api/asset/file",
                "GET /api/asset/file?path=photos%2F2026%2F05%2Bspecial%3D.jpg HTTP/1.1",
                "304",
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) ImmichApp/1.100.0",
            ),
            (
                "GET",
                "/api/oauth/callback",
                "GET /api/oauth/callback?code=def%2Fghi%2B123%3D&state=xyz HTTP/1.1",
                "200",
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) ImmichApp/1.100.0",
            ),
        ]

        for method, path, req, status, ua in test_requests:
            st.add(self.now, method, path, status, req, ua)

        # RED expectation: traversal-injection must NOT match these requests
        self.assertEqual(
            st.bad_reasons.get("traversal-injection", 0),
            0,
            f"Legitimate Immich tokens with %2F/%2B/%3D should NOT trigger traversal-injection, got {st.bad_reasons}"
        )
        self.assertEqual(
            st.non_wpad_signals(),
            0,
            f"Expected 0 non-wpad signals for normal Immich traffic, got {st.bad_reasons}"
        )
        self.assertFalse(
            st.should_block(self.cfg),
            "Immich legitimate traffic must not be blocked"
        )

    def test_real_path_traversal_is_detected(self):
        """Real directory traversal attacks MUST be detected and blocked."""
        traversal_requests = [
            ("GET", "/../../etc/passwd", "GET /../../etc/passwd HTTP/1.1"),
            ("GET", "/static/%2e%2e/%2e%2e/etc/passwd", "GET /static/%2e%2e/%2e%2e/etc/passwd HTTP/1.1"),
            ("GET", "/images/..%2f..%2fwinnt/win.ini", "GET /images/..%2f..%2fwinnt/win.ini HTTP/1.1"),
            ("GET", "/app/..\\..\\windows\\system.ini", "GET /app/..\\..\\windows\\system.ini HTTP/1.1"),
            ("GET", "/..%5c..%5cetc/shadow", "GET /..%5c..%5cetc/shadow HTTP/1.1"),
        ]
        for method, path, req in traversal_requests:
            st = self.snf.Stat()
            st.add(self.now, method, path, "404", req, "curl/7.68.0")
            self.assertGreater(
                st.bad_reasons.get("traversal-injection", 0) + st.bad_reasons.get("traversal", 0),
                0,
                f"Failed to detect real traversal attack in path: {path}"
            )

    def test_scanner_fixtures_blocked(self):
        """Vulnerability scanners (WordPress probes, secrets, git leaks) must still be blocked."""
        scanner_paths = [
            "/wp-admin/setup-config.php",
            "/wp-login.php",
            "/.env",
            "/.git/config",
            "/cgi-bin/luci",
            "/phpmyadmin/index.php",
        ]
        st = self.snf.Stat()
        for p in scanner_paths:
            st.add(self.now, "GET", p, "404", f"GET {p} HTTP/1.1", "masscan/1.0")

        self.assertTrue(
            st.should_block(self.cfg),
            "Scanner attacking known sensitive endpoints must be blocked"
        )

    def test_good_traffic_with_weak_signals_defense_in_depth(self):
        """Legitimate users with 100+ 2xx/204/304 requests and rare 404s must not be blocked."""
        st = self.snf.Stat()
        # 120 successful requests
        for i in range(120):
            status = "200" if i % 2 == 0 else "304"
            st.add(self.now, "GET", f"/api/photos/{i}", status, f"GET /api/photos/{i} HTTP/1.1", "Mozilla/5.0")
        # 2 accidental 404s (e.g. missing asset)
        st.add(self.now, "GET", "/missing-icon.png", "404", "GET /missing-icon.png HTTP/1.1", "Mozilla/5.0")
        st.add(self.now, "GET", "/favicon.ico", "404", "GET /favicon.ico HTTP/1.1", "Mozilla/5.0")

        self.assertEqual(st.good_requests, 120)
        self.assertEqual(st.bad_requests, 2)
        # bad signal rate = 2 / 122 = 0.0164, well below minimum_bad_signal_rate default 0.05
        self.assertLess(st.bad_signal_rate(), self.cfg.get("minimum_bad_signal_rate", 0.05))
        self.assertFalse(st.should_block(self.cfg))

    def test_sqli_xss_query_matching(self):
        """SQLi and XSS patterns in query parameters must be detected without inspecting request body."""
        st = self.snf.Stat()
        st.add(self.now, "GET", "/search", "400", "GET /search?id=1%20UNION%20SELECT%20username,password%20FROM%20users HTTP/1.1", "curl/7.68.0")
        st.add(self.now, "GET", "/profile", "400", "GET /profile?name=<script>alert(1)</script> HTTP/1.1", "curl/7.68.0")

        self.assertGreater(
            st.bad_reasons.get("sqli", 0) + st.bad_reasons.get("xss", 0) + st.bad_reasons.get("traversal-injection", 0),
            0,
            "SQLi or XSS in query parameters should be detected"
        )

    def test_transmission_auth_threshold_default(self):
        """Transmission auth failure threshold default must be 5."""
        self.assertEqual(int(self.snf.DEFAULT_CONFIG.get("threshold_transmission_auth_failures", 1)), 5)

        # 4 auth failures -> should not block
        st = self.snf.Stat()
        for _ in range(4):
            st.add(self.now, "GET", "/transmission/rpc", "401", "GET /transmission/rpc HTTP/1.1", "Transmission/3.00", source="/var/log/nginx/down_access.log")
        self.assertFalse(st.should_block(self.cfg))

        # 5th auth failure -> should block
        st.add(self.now, "GET", "/transmission/rpc", "401", "GET /transmission/rpc HTTP/1.1", "Transmission/3.00", source="/var/log/nginx/down_access.log")
        self.assertTrue(st.should_block(self.cfg))

    def test_openvpn_endpoint_protection(self):
        """OpenVPN remote endpoints from config files or config setting must be whitelisted."""
        with tempfile.TemporaryDirectory() as tmpdir:
            ovpn_conf = Path(tmpdir) / "test.conf"
            ovpn_conf.write_text("client\ndev tun\nremote 1.2.3.4 1194\n", encoding="utf-8")
            
            cfg = dict(self.cfg)
            cfg["protect_openvpn_endpoints"] = True
            cfg["openvpn_config_dir"] = tmpdir
            cfg["openvpn_remote_endpoints"] = ["5.6.7.8"]
            
            state = {"whitelisted": [], "blacklisted": []}
            endpoints = self.snf.get_openvpn_endpoints(cfg)
            self.assertIn("1.2.3.4", endpoints)
            self.assertIn("5.6.7.8", endpoints)
            
            # Ensure is_whitelisted returns True for protected endpoints
            self.assertTrue(self.snf.is_whitelisted("1.2.3.4", state, cfg))
            self.assertTrue(self.snf.is_whitelisted("5.6.7.8", state, cfg))
            self.assertFalse(self.snf.is_whitelisted("9.9.9.9", state, cfg))

    def test_cron_uses_internal_lock_only(self):
        """Cron must not take the same lock that SNF acquires internally."""
        cron_text = self.snf.build_cron_text(use_flock=True)
        self.assertNotIn("/usr/bin/flock", cron_text)
        self.assertIn("/usr/local/bin/snf scan", cron_text)
        self.assertIn("/usr/local/bin/snf expire", cron_text)

    @unittest.skipIf(os.name == "nt", "fcntl locking is available on the Linux target only")
    def test_process_lock_reports_contention(self):
        """A second ProcessLock on the same file must fail closed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            lock_path = Path(tmpdir) / "snf.lock"
            with self.snf.ProcessLock(lock_path) as first:
                self.assertTrue(first)
                with self.snf.ProcessLock(lock_path) as second:
                    self.assertFalse(second)

    def test_expire_removes_whitelisted_blacklist_entries(self):
        """A newly protected endpoint must be removed from persisted blacklist state."""
        ip = "203.0.113.10"
        state = {
            "whitelisted": [{"ip": ip, "reason": "protected", "added_at": None}],
            "blacklisted": [{
                "ip": ip,
                "expires_at": "2999-01-01T00:00:00Z",
                "blocked_at": "2026-01-01T00:00:00Z",
                "reason": "old false positive",
                "score": 30,
            }],
        }
        removed = self.snf.expire_blocks(state, self.cfg, apply=False)
        self.assertEqual([row["ip"] for row in removed], [ip])
        self.assertEqual(state["blacklisted"], [])

    def test_run_required_raises_on_firewall_failure(self):
        """Critical firewall mutations must not silently succeed."""
        class Failed:
            returncode = 4
            stdout = ""
            stderr = "permission denied"

        original = self.snf.run
        try:
            self.snf.run = lambda cmd, check=False: Failed()
            with self.assertRaisesRegex(RuntimeError, "permission denied"):
                self.snf.run_required(["iptables", "-I", "INPUT", "1"])
        finally:
            self.snf.run = original

    def test_firewall_hook_specs_are_port_scoped(self):
        """Hooks for both iptables and ipset must strictly match TCP 80/443."""
        ipt_spec = self.snf.get_firewall_hook_spec("iptables")
        ipset_spec = self.snf.get_firewall_hook_spec("ipset")
        
        # iptables hook
        self.assertIn("-p", ipt_spec)
        self.assertIn("tcp", ipt_spec)
        self.assertIn(self.snf.IPTABLES_CHAIN, ipt_spec)
        # Port match check
        has_ports = any("80" in arg for arg in ipt_spec) or any("0x50" in arg for arg in ipt_spec)
        self.assertTrue(has_ports, f"iptables hook must match port 80: {ipt_spec}")

        # ipset hook
        self.assertIn("-p", ipset_spec)
        self.assertIn("tcp", ipset_spec)
        self.assertIn(self.snf.IPSET_NAME, ipset_spec)
        has_ports_ipset = any("80" in arg for arg in ipset_spec) or any("0x50" in arg for arg in ipset_spec)
        self.assertTrue(has_ports_ipset, f"ipset hook must match port 80: {ipset_spec}")

    def test_u32_fallback_destination_port_mask(self):
        """Regression test: u32 fallback must mask destination port with &0xFFFF.

        At offset 0 of TCP header (@0), the 32-bit dword is (sport << 16) | dport.
        Comparing @0=80,443 without &0xFFFF requires sport==0, which normal traffic
        never has, causing the counter to stay zero and firewall bans to be bypassed.
        The u32 rule must include &0xFFFF before comparing to 80,443.
        """
        orig_check = self.snf._check_multiport_supported
        try:
            self.snf._check_multiport_supported = lambda: False
            ipt_spec = self.snf.get_firewall_hook_spec("iptables")
            ipset_spec = self.snf.get_firewall_hook_spec("ipset")

            expected_u32 = "0>>22&0x3C@0&0xFFFF=80,443"

            # Check iptables spec
            self.assertIn("--u32", ipt_spec)
            u32_idx = ipt_spec.index("--u32") + 1
            self.assertEqual(
                ipt_spec[u32_idx],
                expected_u32,
                f"iptables u32 rule must be {expected_u32}, got {ipt_spec[u32_idx]}"
            )

            # Check ipset spec
            self.assertIn("--u32", ipset_spec)
            ipset_u32_idx = ipset_spec.index("--u32") + 1
            self.assertEqual(
                ipset_spec[ipset_u32_idx],
                expected_u32,
                f"ipset u32 rule must be {expected_u32}, got {ipset_spec[ipset_u32_idx]}"
            )
        finally:
            self.snf._check_multiport_supported = orig_check

    def test_reconcile_replaces_old_wrong_u32_hook_without_fail_open_gap(self):
        """Insert/verify the corrected hook before deleting the old u32 hook."""
        executed_cmds = []
        corrected = "0>>22&0x3C@0&0xFFFF=80,443"
        old_rule = "-A INPUT -p tcp -m u32 --u32 0>>22&0x3C@0=80,443 -j SNF_BLOCK"
        corrected_rule = f"-A INPUT -p tcp -m u32 --u32 {corrected} -j SNF_BLOCK"
        installed = False

        def fake_run(cmd, check=False):
            nonlocal installed
            executed_cmds.append(cmd)
            rc, stdout = 0, ""
            if cmd[:4] == ["iptables", "-L", "SNF_BLOCK", "-n"]:
                rc = 0
            elif cmd[:3] == ["iptables", "-S", "INPUT"]:
                stdout = corrected_rule + "\n" if installed else old_rule + "\n"
            elif cmd[:3] == ["iptables", "-C", "INPUT"]:
                rc = 0 if installed and corrected in cmd else 1
            elif cmd[:4] == ["iptables", "-I", "INPUT", "1"]:
                installed = True
            elif cmd[:4] == ["iptables", "-D", "INPUT", "2"]:
                rc = 0
            else:
                rc = 1
            return type("Result", (), {"returncode": rc, "stdout": stdout, "stderr": ""})()

        original_run = self.snf.run
        original_check = self.snf._check_multiport_supported
        try:
            self.snf.run = fake_run
            self.snf._check_multiport_supported = lambda: False
            self.snf.reconcile_firewall_hooks({"use_ipset_if_available": False})
            insert_index = next(i for i, cmd in enumerate(executed_cmds) if cmd[:4] == ["iptables", "-I", "INPUT", "1"])
            delete_index = next(i for i, cmd in enumerate(executed_cmds) if cmd[:4] == ["iptables", "-D", "INPUT", "2"])
            self.assertLess(insert_index, delete_index)
        finally:
            self.snf.run = original_run
            self.snf._check_multiport_supported = original_check

    def test_reconcile_preserves_existing_valid_hook_and_counters(self):
        """When the desired hook is already unique and at position 1, reconciliation should not re-insert."""
        executed_cmds = []

        def fake_run(cmd, check=False):
            executed_cmds.append(cmd)
            stdout = "-P INPUT ACCEPT\n-A INPUT -p tcp -m u32 --u32 0x0>>0x16&0x3c@0x0&0xffff=0x50,0x1bb -j SNF_BLOCK\n"
            if cmd[:4] == ["iptables", "-L", "SNF_BLOCK", "-n"]:
                rc = 0
            elif cmd[:3] == ["iptables", "-S", "INPUT"]:
                rc = 0
            elif cmd[:3] == ["iptables", "-C", "INPUT"] and "--u32" in cmd:
                rc = 0
            else:
                rc = 1
            return type("Result", (), {"returncode": rc, "stdout": stdout, "stderr": ""})()

        orig_run = self.snf.run
        orig_check = self.snf._check_multiport_supported
        try:
            self.snf.run = fake_run
            self.snf._check_multiport_supported = lambda: False
            cfg = {"use_ipset_if_available": False}
            self.snf.reconcile_firewall_hooks(cfg)

            reinserted = any(
                cmd[:4] == ["iptables", "-I", "INPUT", "1"] and "SNF_BLOCK" in cmd
                for cmd in executed_cmds
            )
            self.assertFalse(reinserted, "Should not re-insert hook when already valid at position 1")
        finally:
            self.snf.run = orig_run
            self.snf._check_multiport_supported = orig_check

    def test_config_backward_compatibility(self):
        """Old config without new keys should merge cleanly with new defaults."""
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = Path(tmpdir) / "config.json"
            cfg_file.write_text('{"block_days": 14, "threshold_score": 30}', encoding="utf-8")
            
            # Temporarily point CONFIG_FILE to cfg_file
            orig_cfg = self.snf.CONFIG_FILE
            try:
                self.snf.CONFIG_FILE = cfg_file
                merged = self.snf.load_config()
                self.assertEqual(merged["block_days"], 14)
                self.assertEqual(merged["threshold_score"], 30)
                self.assertEqual(merged["threshold_transmission_auth_failures"], 5)
                self.assertEqual(merged["minimum_bad_signal_rate"], 0.05)
                self.assertTrue(merged["protect_openvpn_endpoints"])
            finally:
                self.snf.CONFIG_FILE = orig_cfg

if __name__ == "__main__":
    unittest.main()
