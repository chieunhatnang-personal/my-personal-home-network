# DNS over HTTPS on Debian

`dns-over-https-setup.sh` configures one dnsproxy backend behind an existing nginx installation on **Debian 11 or later**, with either systemd or SysVinit. Run it with Bash, not `sh`.

```sh
sudo apt update
sudo apt install bash nginx python3 openssl ca-certificates curl coreutils util-linux dpkg init-system-helpers procps
# Needed for issuance and the supported renewal scheduler integration:
sudo apt install certbot cron
sudo bash ./dns-over-https-setup.sh
```

The script does not install packages, alter DNS/firewall rules, or remove unrelated nginx virtual hosts. All deployment values are entered at runtime. There are no environment-variable switches for skipping security checks. Review your package changes separately on legacy systems.

## Prepare first

- Have a working nginx configuration with the Debian `sites-available` / `sites-enabled` layout. Ensure nginx is running and the layout is included in its effective configuration.
- Choose an unused hostname, such as `dns.example.com`. Clients must resolve it to the intended server. The endpoint path is fixed at `/dns-query`.
- Supply a DNS upstream as an **IP address and explicit port**, for example `192.0.2.53:53` or `[2001:db8::53]:53`. These are documentation addresses; replace them. Hostnames, URLs and shell expressions are rejected. The upstream connection is ordinary DNS, not encrypted transport.
- Supply explicit allowed client networks, for example `192.0.2.0/24`. Network host bits and `/0` are rejected. No client ACL is assumed. Explicit `satisfy all` prevents inherited authentication from bypassing the network restriction; inherited authentication itself remains enabled and can require separate administrator configuration for browser DoH. Loopback is separately allowed for health checks. Choose narrow networks; two broad prefixes can still effectively open a resolver.
- Choose a backend port in `1024..65535` (default `5443`). dnsproxy binds only to IPv4 loopback. The generated frontend uses IPv4 `listen 443 ssl`; IPv6 frontend customization is outside this installer.
- Select a public name with a stable A answer for the health query (default `example.com`). A broken upstream or policy blocking that name aborts activation.

## Certificates without duplicate nginx sites

**Never use `certbot --nginx` as part of this workflow.** The installer does not use the nginx installer or authenticator.

Choose one of:

1. **Existing certificate:** provide absolute full-chain and unencrypted private-key PEM paths. Certificates must cover the hostname, have more than seven days remaining, and match the key. The issuer must be trusted by the system CA store; the activation queries also verify validity dates and the chain. For a private CA, configure the system CA store explicitly before installation.
2. **Explicit HTTP-01 webroot issuance:** independently configure and verify an already served HTTP webroot, then select `webroot`. The installer runs only `certbot certonly --webroot`, with your supplied webroot and contact email, for the exact hostname lineage. It does not create a port 80 vhost. Existing port 80 hosts declaring this same name conflict with the conservative ownership rule: arrange a suitable default challenge handler without an overlapping `server_name`, or provision the certificate externally first. Public HTTP challenge reachability remains your responsibility.
3. **DNS-01:** provision and renew the certificate externally with an appropriate DNS plugin, then select `existing`. Never put DNS API credentials in this repository. This works with split DNS and does not require exposing HTTP-01.

The installer requires a verified running renewal scheduler: either an enabled/active systemd timer whose triggered service directly runs `certbot renew`, or a root-owned, non-group/world-writable `/etc/crontab` or `/etc/cron.d` entry running `certbot renew`, with cron running. Arbitrary wrapper scripts, root crontab spool entries and unrelated ACME tools are deliberately not auto-detected. For these, arrange a supported scheduler/integration before proceeding rather than bypassing the check. The administrator must confirm that the detected scheduler actually renews the selected lineage and executes deploy hooks; merely finding a timer/job cannot prove this association.

For the usual certbot installation, enable the appropriate scheduler manually:

```sh
# systemd only:
sudo systemctl enable --now certbot.timer
sudo systemctl status certbot.timer
# SysVinit: inspect the packaged root renewal entry and ensure cron runs:
sudo service cron status
sudo editor /etc/cron.d/certbot
```

A managed deploy hook is installed at `/etc/letsencrypt/renewal-hooks/deploy/dnsproxy-doh`. It acts only when `RENEWED_LINEAGE` resolves to the selected certificate directory, locks against concurrent installation, tests nginx, restarts the backend to load the renewed certificate, verifies backend DoH readiness, reloads nginx, and verifies the frontend. A managed `/etc/bkcfg/dns-over-https/probe` helper performs the same TLS-verified DNS checks after renewal; readiness failures return nonzero. Custom certificate-copy workflows must invoke this hook with the destination lineage directory. Certbot issuance/account/renewal changes are **not rolled back** when subsequent service activation fails.

## Existing binaries and legacy installations

The default is to preserve the installed dnsproxy executable. An upgrade requires explicit approval and an exact stable release tag `vX.Y.Z`; there is no latest-release lookup or implicit version choice. A working old binary can be preferable on old kernels even when the Debian userspace is newer.

Downloads use a private temporary directory, HTTPS-only redirects, time and size bounds, and the release asset's **published GitHub SHA256 digest**. A missing digest fails closed. The checksum and executable extraction are checked before execution; only one regular `dnsproxy` member is extracted, without trusting archive paths or symlinks. `--version` and required help flags are checked before replacement. This catches immediate CPU/kernel incompatibility, but does not prove every runtime code path is compatible; activation health checks provide a further gate. Release metadata and archives share GitHub's trust boundary; this is integrity checking, not an independently signed supply-chain guarantee.

Only `/usr/local/bin/dnsproxy` can be replaced by the installer. Package-owned/custom executables are preserved or must be managed externally. Backups include any binary replaced in the transaction.

The single-instance configuration remains at `/etc/bkcfg/dns-over-https/config.txt`. Existing summary keys are preserved; it is never sourced as shell code. Reruns must use the same hostname. Unmarked legacy/custom managed files require explicit per-file adoption approval and are backed up. Non-regular files, unexpected links and alternate-init duplicate service definitions are rejected. Legacy enabled sites with this hostname must be reviewed and disabled/migrated explicitly before adoption; the installer does not infer that a hostname collision is safe to delete.

## Conflict refusal and activation

Effective `nginx -T` output, not just files in `sites-available`, is checked **before** downloads, issuance and managed writes, and checked again before activation. Exact names, overlapping wildcards and dotted suffix names are conflicts. Regex `server_name` directives are conservatively refused, even when the regex might not match. Existing nginx warnings (including ignored duplicate hosts) also cause refusal. Remove the ambiguity as an administrator; do not delete an entire unrelated/default vhost just to silence a collision. Nginx configuration edits by another administrator are not serialized by this installer's private lock; avoid concurrent edits.

Managed artifacts are staged then replaced by same-directory renames. Snapshots and `manifest.tsv` are retained under `/etc/bkcfg/dns-over-https/backups/transaction.*`. The old backend is stopped before replacing its executable or service. systemd uses an explicit restart, not `enable --now` as an update substitute. SysVinit uses PID plus executable ownership checks, bounded TERM/KILL stop, startup logging and repeated process checks.

Activation runs nginx validation, backend restart/status, a real backend DoH request, nginx **reload** (never a restart fallback), and a frontend DoH request. The probes validate certificate chain/hostname, HTTP 200, DNS message content type, transaction ID, question, flags, record structure and an A answer. Socket and overall deadlines bound the query. A HEAD request, insecure TLS or HTTP 400/405 is not success.

Failure or a handled interrupt restores original files/links and the binary, attempts restoration of service enablement/running state, and validates/reloads restored nginx. A failed restore is prominently reported; inspect the retained snapshots and manifest. Newly created empty directories, temporary staging remnants after exceptional disk failures, certificate issuance state, package changes, and logs are not transactionally undone. Power loss or `SIGKILL` cannot run a shell rollback. Keep an independent host backup. Backups may contain private deployment settings: do not publish them.

## Troubleshooting and verification

Run diagnostics on the target host, not in a public transcript containing sensitive config:

```sh
sudo nginx -t
sudo nginx -T
# systemd:
sudo systemctl status dnsproxy-doh.service
sudo journalctl -u dnsproxy-doh.service -n 50 --no-pager
# SysVinit:
sudo service dnsproxy-doh status
sudo less /var/log/dnsproxy-doh.log
# Read-only bounded end-to-end DNS probe (substitute your hostname):
timeout 20 bash ./dns-over-https-setup.sh --probe dns.example.com 127.0.0.1 443 example.com
```

A conflict message names the included nginx file/name; `nginx -T` warnings may identify the file and line directly. Resolve collisions before rerunning. Startup failures on old hardware can mean an unsupported executable/kernel or an occupied port; preserve the known-working executable or select another explicitly pinned compatible release. TLS failures can indicate stale certificates, missing intermediate certificates or system trust roots. HTTP 403 generally means the connecting client is outside the configured ACL. A missing DNS A answer may mean the selected upstream is unreachable or filtering the health name.

After a successful local probe, test the actual browser/client using `https://dns.example.com/dns-query`, from an allowed network and separately from a denied network. Local health does **not** prove public DNS, client routing, external firewall state, IPv6 behavior, or remote ACL enforcement. No deployment or testing is implied merely by editing this script.

For isolated test harnesses only, `source ./dns-over-https-setup.sh --library` defines helpers without host probes, root checks, traps, package operations or writes. Sourcing without the explicit argument is rejected. The public executable interface is interactive installation, `--library`, or the read-only `--probe` command above.
