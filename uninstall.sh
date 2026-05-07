#!/usr/bin/env bash
set -u

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    printf 'Please run as root or with sudo.\n' >&2
    exit 1
  fi
}

main() {
  require_root

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now opsdoctor-agent.timer 2>/dev/null || true
    systemctl stop opsdoctor-agent.service 2>/dev/null || true
    systemctl disable --now opsdoctor-web.service 2>/dev/null || true
  fi

  rm -f /usr/local/bin/opsdoctor
  rm -f /usr/local/bin/opsdoctor-agent
  rm -f /usr/local/bin/opsdoctor-web
  rm -f /etc/systemd/system/opsdoctor-agent.service
  rm -f /etc/systemd/system/opsdoctor-agent.timer
  rm -f /etc/systemd/system/opsdoctor-web.service

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
  fi

  printf 'OpsDoctor binaries and systemd units were removed.\n'
  printf 'Monitoring data was kept at /var/lib/opsdoctor.\n'
  printf 'To remove data manually, run: rm -rf /var/lib/opsdoctor /var/log/opsdoctor-agent.log\n'
}

main "$@"
