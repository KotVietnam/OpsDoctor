#!/usr/bin/env bash
set -u

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    printf 'Please run as root or with sudo.\n' >&2
    exit 1
  fi
}

project_dir() {
  CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'systemctl is required for timer installation.\n' >&2
    exit 1
  fi
}

main() {
  local dir
  dir="$(project_dir)"
  # shellcheck disable=SC1091
  . "$dir/lib/opsdoctor-install-deps.sh"
  # shellcheck disable=SC1091
  . "$dir/lib/opsdoctor-install-i18n.sh"
  parse_dependency_args "$@"
  parse_language_args "$@"
  if [ "$INSTALL_LIST_LANGUAGES" -eq 1 ]; then
    configure_language
  fi
  if [ "$OPSDOCTOR_CHECK_DEPS_ONLY" -eq 1 ]; then
    print_dependency_report agent
    exit 0
  fi

  require_root

  ensure_dependencies agent
  require_systemd
  configure_language
  install -m 0755 "$dir/cli/opsdoctor.sh" /usr/local/bin/opsdoctor
  install -m 0755 "$dir/agent/opsdoctor-agent.sh" /usr/local/bin/opsdoctor-agent
  install -m 0644 "$dir/systemd/opsdoctor-agent.service" /etc/systemd/system/opsdoctor-agent.service
  install -m 0644 "$dir/systemd/opsdoctor-agent.timer" /etc/systemd/system/opsdoctor-agent.timer

  mkdir -p /var/lib/opsdoctor/history
  touch /var/log/opsdoctor-agent.log
  chmod 0644 /var/log/opsdoctor-agent.log

  systemctl daemon-reload
  systemctl enable --now opsdoctor-agent.timer
  /usr/local/bin/opsdoctor-agent run

  printf '\nOpsDoctor agent installed.\n'
  systemctl --no-pager status opsdoctor-agent.timer || true
}

main "$@"
