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
    print_dependency_report cli
    exit 0
  fi

  require_root

  if [ ! -f "$dir/cli/opsdoctor.sh" ]; then
    printf 'Could not find cli/opsdoctor.sh from %s\n' "$dir" >&2
    exit 1
  fi

  ensure_dependencies cli
  configure_language
  install -m 0755 "$dir/cli/opsdoctor.sh" /usr/local/bin/opsdoctor

  printf 'OpsDoctor CLI installed to /usr/local/bin/opsdoctor\n\n'
  printf 'Try:\n'
  printf '  opsdoctor check\n'
  printf '  opsdoctor check --json\n'
  printf '  opsdoctor check --html report.html\n'
  printf '  opsdoctor check --lang ru\n'
  printf '  opsdoctor languages\n'
}

main "$@"
