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

server_ip() {
  local addrs
  if command -v hostname >/dev/null 2>&1; then
    addrs="$(hostname -I 2>/dev/null || true)"
    set -- $addrs
    printf '%s' "${1:-}"
  fi
}

main() {
  local dir tmp_bin ip
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
    print_dependency_report web
    exit 0
  fi

  require_root
  ensure_dependencies web

  if [ -n "$INSTALL_LANG_REQUESTED" ]; then
    "$dir/install-agent.sh" --skip-deps --lang "$INSTALL_LANG_REQUESTED"
  else
    "$dir/install-agent.sh" --skip-deps
  fi

  if ! command -v go >/dev/null 2>&1; then
    printf '\nGo is not installed, so the web dashboard binary was not built.\n' >&2
    printf 'Build it on a machine with Go installed:\n' >&2
    printf '  cd web && go build -o opsdoctor-web .\n' >&2
    printf 'Then copy the binary to /usr/local/bin/opsdoctor-web and run this script again.\n' >&2
    exit 1
  fi

  tmp_bin="$(mktemp -t opsdoctor-web.XXXXXX)"
  trap 'rm -f "$tmp_bin"' EXIT
  (cd "$dir/web" && go build -o "$tmp_bin" .)
  install -m 0755 "$tmp_bin" /usr/local/bin/opsdoctor-web
  install -m 0644 "$dir/systemd/opsdoctor-web.service" /etc/systemd/system/opsdoctor-web.service

  systemctl daemon-reload
  systemctl enable --now opsdoctor-web.service

  ip="$(server_ip)"
  [ -n "$ip" ] || ip="SERVER_IP"

  printf '\nOpsDoctor web dashboard installed.\n'
  printf 'URL: http://%s:7357\n\n' "$ip"
  systemctl --no-pager status opsdoctor-web.service || true
}

main "$@"
