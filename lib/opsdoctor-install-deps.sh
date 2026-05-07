#!/usr/bin/env bash

OPSDOCTOR_INSTALL_DEPS="${OPSDOCTOR_INSTALL_DEPS:-auto}"
OPSDOCTOR_CHECK_DEPS_ONLY=0

parse_dependency_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --install-deps)
        OPSDOCTOR_INSTALL_DEPS="auto"
        ;;
      --skip-deps|--no-install-deps)
        OPSDOCTOR_INSTALL_DEPS="no"
        ;;
      --check-deps)
        OPSDOCTOR_CHECK_DEPS_ONLY=1
        OPSDOCTOR_INSTALL_DEPS="no"
        ;;
      --lang)
        shift
        ;;
      --auto-lang|--list-languages)
        ;;
      *)
        ;;
    esac
    shift
  done
}

dependency_specs() {
  local profile="$1"

  cat <<'EOF'
bash|bash|required|Bash runtime
install|coreutils|required|installer file copy helper
date|coreutils|required|timestamps
uname|coreutils|required|kernel and platform detection
df|coreutils|required|disk usage checks
stat|coreutils|required|permission checks
grep|grep|required|configuration parsing
sed|sed|required|string cleanup
awk|mawk|required|installer and locale parsing
find|findutils|required|nginx config and history scanning
getent|libc-bin|recommended|DNS and hostname resolution checks
locale|libc-bin|recommended|language and locale detection
hostname|hostname|recommended|hostname detection and dashboard URL hints
ip|iproute2|recommended|default gateway checks
ss|iproute2|recommended|listening port checks
ping|iputils-ping|recommended|internet reachability checks
pgrep|procps|recommended|process state checks
curl|curl|recommended|OpsDoctor upstream update checks
wget|wget|optional|OpsDoctor update check fallback when curl is unavailable
netstat|net-tools|optional|listening port fallback when ss is unavailable
EOF

  case "$profile" in
    agent|web)
      cat <<'EOF'
systemctl|systemd|required|systemd service and timer management
EOF
      ;;
  esac

  case "$profile" in
    web)
      cat <<'EOF'
go|golang-go|required|Go web dashboard build
EOF
      ;;
  esac
}

dependency_profile_name() {
  case "$1" in
    cli) printf 'CLI' ;;
    agent) printf 'CLI + Agent' ;;
    web) printf 'CLI + Agent + Web Dashboard' ;;
    *) printf '%s' "$1" ;;
  esac
}

dedupe_words() {
  local item result=""
  for item in "$@"; do
    [ -n "$item" ] || continue
    case " $result " in
      *" $item "*) ;;
      *) result="$result $item" ;;
    esac
  done
  result="${result#"${result%%[![:space:]]*}"}"
  result="${result%"${result##*[![:space:]]}"}"
  printf '%s\n' "$result"
}

missing_dependency_packages() {
  local profile="$1"
  local include_optional="${2:-no}"
  local line command_name package_name level description packages=()

  while IFS='|' read -r command_name package_name level description; do
    [ -n "$command_name" ] || continue
    if [ "$level" = "optional" ] && [ "$include_optional" != "yes" ]; then
      continue
    fi
    if ! command -v "$command_name" >/dev/null 2>&1; then
      packages+=("$package_name")
    fi
  done <<EOF
$(dependency_specs "$profile")
EOF

  dedupe_words "${packages[@]}"
}

has_missing_required_dependencies() {
  local profile="$1"
  local line command_name package_name level description
  while IFS='|' read -r command_name package_name level description; do
    [ -n "$command_name" ] || continue
    [ "$level" = "required" ] || continue
    if ! command -v "$command_name" >/dev/null 2>&1; then
      return 0
    fi
  done <<EOF
$(dependency_specs "$profile")
EOF
  return 1
}

print_dependency_report() {
  local profile="$1"
  local line command_name package_name level description state

  printf 'OpsDoctor dependency check: %s\n\n' "$(dependency_profile_name "$profile")"
  printf '  %-10s %-13s %-16s %s\n' 'State' 'Level' 'Package' 'Command / purpose'
  printf '  %-10s %-13s %-16s %s\n' '-----' '-----' '-------' '-----------------'

  while IFS='|' read -r command_name package_name level description; do
    [ -n "$command_name" ] || continue
    if command -v "$command_name" >/dev/null 2>&1; then
      state="ok"
    else
      state="missing"
    fi
    printf '  %-10s %-13s %-16s %s (%s)\n' "$state" "$level" "$package_name" "$command_name" "$description"
  done <<EOF
$(dependency_specs "$profile")
EOF

  cat <<'EOF'

Notes:
  required     must be present for installation or core operation
  recommended improves diagnostic coverage; missing commands become skipped/warning checks
  optional     fallback helpers; not installed automatically
EOF
}

apt_available() {
  command -v apt-get >/dev/null 2>&1
}

install_dependency_packages() {
  local packages="$1"
  [ -n "$packages" ] || return 0

  if ! apt_available; then
    printf 'Missing packages: %s\n' "$packages" >&2
    printf 'Automatic dependency installation currently supports apt-get on Debian/Ubuntu.\n' >&2
    printf 'Install the missing packages manually, then rerun the installer.\n' >&2
    return 1
  fi

  printf '\nInstalling OpsDoctor dependencies with apt-get:\n  %s\n\n' "$packages"
  apt-get update
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y $packages
}

ensure_dependencies() {
  local profile="$1"
  local missing_packages

  print_dependency_report "$profile"
  missing_packages="$(missing_dependency_packages "$profile" no)"
  missing_packages="${missing_packages#"${missing_packages%%[![:space:]]*}"}"
  missing_packages="${missing_packages%"${missing_packages##*[![:space:]]}"}"

  if [ -z "$missing_packages" ]; then
    printf '\nAll required and recommended OpsDoctor dependencies are present.\n'
    return 0
  fi

  if [ "$OPSDOCTOR_INSTALL_DEPS" = "no" ]; then
    printf '\nMissing required/recommended packages were not installed because dependency installation is disabled.\n' >&2
    if has_missing_required_dependencies "$profile"; then
      return 1
    fi
    return 0
  fi

  install_dependency_packages "$missing_packages"

  if has_missing_required_dependencies "$profile"; then
    printf '\nSome required dependencies are still missing after installation.\n' >&2
    print_dependency_report "$profile" >&2
    return 1
  fi

  printf '\nDependency installation completed.\n'
}
