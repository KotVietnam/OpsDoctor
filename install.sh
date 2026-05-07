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
  require_root
  local dir
  dir="$(project_dir)"

  if [ ! -f "$dir/cli/opsdoctor.sh" ]; then
    printf 'Could not find cli/opsdoctor.sh from %s\n' "$dir" >&2
    exit 1
  fi

  install -m 0755 "$dir/cli/opsdoctor.sh" /usr/local/bin/opsdoctor

  printf 'OpsDoctor CLI installed to /usr/local/bin/opsdoctor\n\n'
  printf 'Try:\n'
  printf '  opsdoctor check\n'
  printf '  opsdoctor check --json\n'
  printf '  opsdoctor check --html report.html\n'
}

main "$@"
