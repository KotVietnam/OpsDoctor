# OpsDoctor

`[CI: coming soon]` `[License: MIT]` `[Linux: Debian/Ubuntu]` `[Runtime: Bash + optional Go]`

OpsDoctor is a lightweight Linux server diagnostics and monitoring toolkit for sysadmins, network administrators and DevOps engineers.

No Python. No Node.js. No heavy dependencies. Pure Bash for checks. Optional single-binary Go web dashboard.

OpsDoctor is designed for quick one-shot diagnostics, simple periodic server health collection, and a small web dashboard that reads the latest JSON report from disk.

## Key Features

- Bash CLI for one-shot Linux diagnostics.
- Agent mode that periodically writes `/var/lib/opsdoctor/latest.json`.
- History snapshots under `/var/lib/opsdoctor/history/`.
- Go web dashboard as one standalone binary.
- Valid JSON output without `jq`.
- Standalone HTML reports with embedded CSS.
- Automatic language detection with installer-time language selection.
- Localized dashboard and report labels for major world languages.
- Linux-only checks for system, network, security, services, packages, Docker, and nginx.
- Graceful degradation when optional commands are missing.
- Unified check result format: `id`, `category`, `title`, `status`, `message`, `fix`.
- Health score from 0 to 100.

## Installation

Clone the repository on a Debian or Ubuntu server:

```bash
git clone https://github.com/opsdoctor/opsdoctor.git
cd opsdoctor
sudo ./install.sh
```

The installer places the CLI at:

```text
/usr/local/bin/opsdoctor
```

During installation OpsDoctor can keep `auto` language detection or write a preferred language to `/etc/opsdoctor/opsdoctor.conf`:

```bash
sudo ./install.sh --lang ru
sudo ./install.sh --auto-lang
./install.sh --list-languages
```

Installers check required and recommended dependencies before copying files. On Debian/Ubuntu they can install missing packages automatically with `apt-get`:

```bash
./install.sh --check-deps
sudo ./install.sh --install-deps
sudo ./install.sh --skip-deps
```

Try:

```bash
opsdoctor check
opsdoctor check --json
opsdoctor check --html report.html
opsdoctor check --lang ru
opsdoctor languages
```

## One-Shot CLI Usage

Run the default terminal report:

```bash
opsdoctor
```

Run an explicit check:

```bash
opsdoctor check
```

Disable colors:

```bash
opsdoctor check --no-color
```

Write JSON:

```bash
opsdoctor check --json > report.json
```

Write a standalone HTML report:

```bash
opsdoctor check --html report.html
```

Override language for one run:

```bash
opsdoctor check --lang ru
OPSDOCTOR_LANG=de opsdoctor check
```

Print version and help:

```bash
opsdoctor version
opsdoctor help
opsdoctor languages
```

## Language Support

OpsDoctor detects language in this order:

1. CLI flag or environment variable: `--lang LANG`, `OPSDOCTOR_LANG`, or `OPSDOCTOR_WEB_LANG`.
2. `/etc/opsdoctor/opsdoctor.conf`.
3. System locale from `LC_ALL`, `LC_MESSAGES`, or `LANG`.
4. English fallback.

Supported language codes:

```text
en ru es zh hi ar pt fr de ja ko it tr pl uk id vi fa bn ur nl cs sv ro
```

Installers list languages already installed as system locales first, then the remaining supported languages:

```bash
sudo ./install.sh
sudo ./install-agent.sh --lang ru
sudo ./install-web.sh --lang auto
```

The CLI JSON report includes stable machine-readable fields plus localized labels:

```json
{
  "language": "ru",
  "checks": [
    {
      "category": "Security",
      "category_label": "Безопасность",
      "title": "SSH root login",
      "title_label": "Root-доступ по SSH",
      "status": "critical",
      "status_label": "КРИТИЧНО"
    }
  ]
}
```

## Dependency Checks

OpsDoctor keeps runtime dependencies small. The Bash CLI works with common Debian/Ubuntu base utilities and degrades individual checks to `skipped` or `warning` when optional diagnostic tools are missing.

Installer dependency modes:

```bash
./install.sh --check-deps
./install-agent.sh --check-deps
./install-web.sh --check-deps

sudo ./install.sh --install-deps
sudo ./install-agent.sh --install-deps
sudo ./install-web.sh --install-deps

sudo ./install.sh --skip-deps
```

The default installer behavior is `--install-deps`: missing required and recommended OpsDoctor packages are installed automatically when `apt-get` is available.

Core packages checked by the installers include:

```text
bash coreutils grep sed mawk findutils libc-bin hostname iproute2 iputils-ping procps
```

Agent installation additionally requires systemd:

```text
systemd
```

Web dashboard installation additionally requires Go for building the single binary:

```text
golang-go
```

OpsDoctor does not automatically install monitored services such as nginx, Docker, ufw, firewalld, or fail2ban. Those are inspected if present and reported as skipped or warning when absent, depending on the check.

## Agent Installation

The agent runs the Bash CLI, stores the newest JSON report, and keeps timestamped history files.

```bash
sudo ./install-agent.sh
```

This installs:

```text
/usr/local/bin/opsdoctor
/usr/local/bin/opsdoctor-agent
/etc/systemd/system/opsdoctor-agent.service
/etc/systemd/system/opsdoctor-agent.timer
```

The first collection is run immediately. Agent logs are written to:

```text
/var/log/opsdoctor-agent.log
```

Manual agent commands:

```bash
sudo opsdoctor-agent run
opsdoctor-agent status
sudo opsdoctor-agent install
sudo opsdoctor-agent uninstall
```

## Web Dashboard Installation

The web dashboard is written in Go and uses only the Go standard library.

```bash
sudo ./install-web.sh
```

If Go is installed, the script builds the binary with:

```bash
cd web && go build -o opsdoctor-web .
```

The installed service listens on:

```text
http://SERVER_IP:7357
```

Configuration is environment-based:

```text
OPSDOCTOR_WEB_PORT=7357
OPSDOCTOR_DATA_FILE=/var/lib/opsdoctor/latest.json
```

Endpoints:

```text
/             HTML dashboard
/api/status   raw latest.json
/health       health check
/static/style.css
```

## JSON Example

```json
{
  "tool": "OpsDoctor",
  "version": "0.1.0",
  "language": "en",
  "timestamp": "2026-05-07T17:00:00+05:00",
  "host": {
    "hostname": "server01",
    "os": "Debian GNU/Linux 12",
    "kernel": "6.1.0"
  },
  "score": 74,
  "summary": {
    "ok": 18,
    "warning": 6,
    "critical": 1,
    "skipped": 2
  },
  "checks": [
    {
      "id": "ssh_root_login",
      "category": "Security",
      "category_label": "Security",
      "title": "SSH root login",
      "title_label": "SSH root login",
      "status": "critical",
      "status_label": "CRITICAL",
      "message": "PermitRootLogin is enabled",
      "fix": "Set PermitRootLogin no in /etc/ssh/sshd_config and restart ssh"
    }
  ]
}
```

See a larger sample in [`examples/report.json`](examples/report.json).

## HTML Report Example

Generate an HTML report:

```bash
opsdoctor check --html report.html
```

Open the generated file in a browser. A sample report is included at [`examples/report.html`](examples/report.html).

## Screenshots

CLI output placeholder:

```text
OpsDoctor 0.1.0
Host: server01 | OS: Debian GNU/Linux 12 | Kernel: 6.1.0

System
  OK        Hostname                           Hostname is server01.
  WARNING   Root disk usage                    Root filesystem usage is 84%.

Summary
  Score: 74/100
```

Dashboard placeholder:

```text
+------------------------------------------------------+
| OpsDoctor Dashboard                      Score 74/100 |
| server01 · Debian GNU/Linux 12                       |
| OK 18 | Warnings 6 | Critical 1 | Skipped 2           |
| Checks table + Suggested fixes                       |
+------------------------------------------------------+
```

## Systemd Timer

`opsdoctor-agent.timer` runs every five minutes:

```ini
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true
```

The timer triggers `opsdoctor-agent.service`, a oneshot unit that runs:

```text
/usr/local/bin/opsdoctor-agent run
```

The latest report is always available at:

```text
/var/lib/opsdoctor/latest.json
```

Historical reports are stored as timestamped files in:

```text
/var/lib/opsdoctor/history/
```

## Supported Platforms

OpsDoctor is Linux-only.

The MVP targets Debian and Ubuntu servers with Bash and common base utilities. Checks degrade to `skipped` when optional commands such as `ss`, `netstat`, `ufw`, `firewall-cmd`, `docker`, or `nginx` are not installed.

The web dashboard can be built anywhere Go is available, then copied to the target Linux server as a single binary.

## Security Notes

- OpsDoctor reads local system state and configuration files.
- Some checks are more complete when run as root.
- The web dashboard binds to `0.0.0.0:7357` by default. Put it behind a firewall, VPN, reverse proxy, or SSH tunnel before exposing it on untrusted networks.
- The dashboard serves the latest local JSON report and does not implement authentication in the MVP.
- Review generated HTML and JSON before sharing them because they may include hostnames, open ports, service names, and configuration findings.

## Roadmap

- More package managers and distributions.
- Configurable thresholds.
- Pluggable checks.
- Prometheus text exporter.
- Signed release binaries.
- Authentication options for the web dashboard.
- HTML report branding and light theme.
- CI checks for shell syntax and Go builds.

## Contributing

Contributions are welcome.

Suggested workflow:

```bash
git checkout -b feature/my-change
bash -n cli/opsdoctor.sh agent/opsdoctor-agent.sh install.sh install-agent.sh install-web.sh uninstall.sh
cd web && go test ./...
```

Keep the Bash runtime lightweight and avoid adding Python, Node.js, Docker, or heavy runtime dependencies to the core CLI/agent.

## License

MIT License. See [`LICENSE`](LICENSE).
