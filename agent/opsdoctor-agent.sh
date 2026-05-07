#!/usr/bin/env bash
set -u

DATA_DIR="${OPSDOCTOR_DATA_DIR:-/var/lib/opsdoctor}"
HISTORY_DIR="$DATA_DIR/history"
LATEST_FILE="$DATA_DIR/latest.json"
LOG_FILE="${OPSDOCTOR_AGENT_LOG:-/var/log/opsdoctor-agent.log}"
CLI_BIN="${OPSDOCTOR_CLI:-opsdoctor}"

log() {
  local message="$1"
  local ts
  ts="$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")"
  if ! printf '%s %s\n' "$ts" "$message" >> "$LOG_FILE" 2>/dev/null; then
    printf '%s %s\n' "$ts" "$message" >&2
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

script_dir() {
  CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
}

find_cli() {
  if command_exists "$CLI_BIN"; then
    printf '%s' "$CLI_BIN"
    return 0
  fi

  local dir
  dir="$(script_dir)"
  if [ -x "$dir/../cli/opsdoctor.sh" ]; then
    printf '%s' "$dir/../cli/opsdoctor.sh"
    return 0
  fi

  if [ -x /usr/local/bin/opsdoctor ]; then
    printf '%s' "/usr/local/bin/opsdoctor"
    return 0
  fi

  return 1
}

ensure_dirs() {
  mkdir -p "$DATA_DIR" "$HISTORY_DIR" || return 1
}

run_agent() {
  local cli tmp history_file stamp
  cli="$(find_cli)" || {
    log "ERROR: opsdoctor CLI was not found"
    printf 'opsdoctor CLI was not found. Install it first or set OPSDOCTOR_CLI.\n' >&2
    return 1
  }

  ensure_dirs || {
    log "ERROR: could not create data directories under $DATA_DIR"
    printf 'Could not create %s. Run as root or adjust OPSDOCTOR_DATA_DIR.\n' "$DATA_DIR" >&2
    return 1
  }

  stamp="$(date +"%Y%m%dT%H%M%S%z")"
  tmp="$DATA_DIR/latest.json.tmp.$$"
  history_file="$HISTORY_DIR/$stamp.json"

  if ! "$cli" check --json > "$tmp"; then
    rm -f "$tmp"
    log "ERROR: opsdoctor check --json failed"
    return 1
  fi

  if ! grep -q '^{[[:space:]]*$' "$tmp" && ! grep -q '^{' "$tmp"; then
    rm -f "$tmp"
    log "ERROR: CLI output did not look like JSON"
    printf 'CLI output did not look like JSON.\n' >&2
    return 1
  fi

  chmod 0644 "$tmp" 2>/dev/null || true
  mv "$tmp" "$LATEST_FILE" || {
    rm -f "$tmp"
    log "ERROR: could not update $LATEST_FILE"
    return 1
  }
  cp "$LATEST_FILE" "$history_file" || {
    log "ERROR: could not write history file $history_file"
    return 1
  }
  chmod 0644 "$history_file" 2>/dev/null || true
  log "OK: wrote $LATEST_FILE and $history_file"
}

install_agent_local() {
  if [ "$(id -u)" -ne 0 ]; then
    printf 'Please run as root or with sudo.\n' >&2
    return 1
  fi
  ensure_dirs || return 1
  install -m 0755 "$0" /usr/local/bin/opsdoctor-agent
  printf 'Installed opsdoctor-agent to /usr/local/bin/opsdoctor-agent.\n'
  printf 'For systemd timer installation, run ./install-agent.sh from the project root.\n'
}

uninstall_agent_local() {
  if [ "$(id -u)" -ne 0 ]; then
    printf 'Please run as root or with sudo.\n' >&2
    return 1
  fi
  rm -f /usr/local/bin/opsdoctor-agent
  printf 'Removed /usr/local/bin/opsdoctor-agent.\n'
  printf 'Data directory was kept at %s.\n' "$DATA_DIR"
}

status_agent() {
  printf 'OpsDoctor agent status\n'
  printf '  Data directory: %s\n' "$DATA_DIR"
  printf '  Latest report:  %s\n' "$LATEST_FILE"
  if [ -f "$LATEST_FILE" ]; then
    printf '  Latest mtime:   %s\n' "$(date -r "$LATEST_FILE" -Iseconds 2>/dev/null || ls -l "$LATEST_FILE")"
  else
    printf '  Latest mtime:   missing\n'
  fi
  if [ -d "$HISTORY_DIR" ]; then
    printf '  History files:  %s\n' "$(find "$HISTORY_DIR" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  else
    printf '  History files:  0\n'
  fi
  if command_exists systemctl; then
    systemctl --no-pager status opsdoctor-agent.timer 2>/dev/null || true
  fi
}

usage() {
  cat <<'EOF'
Usage:
  opsdoctor-agent run
  opsdoctor-agent install
  opsdoctor-agent uninstall
  opsdoctor-agent status
EOF
}

main() {
  local command_name="${1:-run}"
  case "$command_name" in
    run) run_agent ;;
    install) install_agent_local ;;
    uninstall) uninstall_agent_local ;;
    status) status_agent ;;
    help|-h|--help) usage ;;
    *)
      printf 'Unknown command: %s\n\n' "$command_name" >&2
      usage >&2
      return 1
      ;;
  esac
}

main "$@"
