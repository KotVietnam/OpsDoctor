#!/usr/bin/env bash

OPSDOCTOR_CONFIG_DIR="${OPSDOCTOR_CONFIG_DIR:-/etc/opsdoctor}"
OPSDOCTOR_CONFIG_FILE="${OPSDOCTOR_CONFIG_FILE:-$OPSDOCTOR_CONFIG_DIR/opsdoctor.conf}"
SUPPORTED_LANGUAGES="en ru es zh hi ar pt fr de ja ko it tr pl uk id vi fa bn ur nl cs sv ro"
INSTALL_LANG_REQUESTED=""
INSTALL_LIST_LANGUAGES=0
INSTALLED_LANG_CACHE=""

lang_name() {
  case "$1" in
    auto) printf 'Auto (system default)' ;;
    en) printf 'English' ;;
    ru) printf 'Русский' ;;
    es) printf 'Español' ;;
    zh) printf '中文' ;;
    hi) printf 'हिन्दी' ;;
    ar) printf 'العربية' ;;
    pt) printf 'Português' ;;
    fr) printf 'Français' ;;
    de) printf 'Deutsch' ;;
    ja) printf '日本語' ;;
    ko) printf '한국어' ;;
    it) printf 'Italiano' ;;
    tr) printf 'Türkçe' ;;
    pl) printf 'Polski' ;;
    uk) printf 'Українська' ;;
    id) printf 'Bahasa Indonesia' ;;
    vi) printf 'Tiếng Việt' ;;
    fa) printf 'فارسی' ;;
    bn) printf 'বাংলা' ;;
    ur) printf 'اردو' ;;
    nl) printf 'Nederlands' ;;
    cs) printf 'Čeština' ;;
    sv) printf 'Svenska' ;;
    ro) printf 'Română' ;;
    *) printf '%s' "$1" ;;
  esac
}

normalize_lang() {
  local raw="${1:-}"
  raw="${raw%%.*}"
  raw="${raw%%@*}"
  raw="${raw//-/_}"
  raw="${raw%%_*}"
  raw="${raw,,}"
  case "$raw" in
    cn|zh) printf 'zh' ;;
    in) printf 'id' ;;
    *) printf '%s' "$raw" ;;
  esac
}

is_supported_lang() {
  case " $SUPPORTED_LANGUAGES auto " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

system_language() {
  local candidate
  for candidate in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
    candidate="$(normalize_lang "$candidate")"
    if is_supported_lang "$candidate" && [ "$candidate" != "auto" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf 'en'
}

locale_language_installed() {
  local code="$1"
  load_installed_languages
  case " $INSTALLED_LANG_CACHE " in
    *" $code "*) return 0 ;;
    *) return 1 ;;
  esac
}

load_installed_languages() {
  local locale_name code
  [ -n "$INSTALLED_LANG_CACHE" ] && return 0
  command -v locale >/dev/null 2>&1 || {
    INSTALLED_LANG_CACHE="none"
    return 0
  }
  if command -v awk >/dev/null 2>&1; then
    while IFS= read -r code; do
      code="$(normalize_lang "$code")"
      if is_supported_lang "$code" && [ "$code" != "auto" ]; then
        case " $INSTALLED_LANG_CACHE " in
          *" $code "*) ;;
          *) INSTALLED_LANG_CACHE="$INSTALLED_LANG_CACHE $code" ;;
        esac
      fi
    done < <(locale -a 2>/dev/null | awk -F'[_.@-]' '{print tolower($1)}')
    [ -n "$INSTALLED_LANG_CACHE" ] || INSTALLED_LANG_CACHE="none"
    return 0
  fi
  while IFS= read -r locale_name; do
    code="$(normalize_lang "$locale_name")"
    if is_supported_lang "$code" && [ "$code" != "auto" ]; then
      case " $INSTALLED_LANG_CACHE " in
        *" $code "*) ;;
        *) INSTALLED_LANG_CACHE="$INSTALLED_LANG_CACHE $code" ;;
      esac
    fi
  done < <(locale -a 2>/dev/null)
  [ -n "$INSTALLED_LANG_CACHE" ] || INSTALLED_LANG_CACHE="none"
}

ordered_languages() {
  local code
  for code in $SUPPORTED_LANGUAGES; do
    locale_language_installed "$code" && printf '%s\n' "$code"
  done
  for code in $SUPPORTED_LANGUAGES; do
    locale_language_installed "$code" || printf '%s\n' "$code"
  done
}

print_language_list() {
  local code marker
  printf 'Supported OpsDoctor languages\n'
  printf 'System language: %s (%s)\n\n' "$(system_language)" "$(lang_name "$(system_language)")"
  printf '  %-4s %-24s %s\n' auto "$(lang_name auto)" ''
  while IFS= read -r code; do
    if locale_language_installed "$code"; then
      marker='installed locale'
    else
      marker='not installed'
    fi
    printf '  %-4s %-24s %s\n' "$code" "$(lang_name "$code")" "$marker"
  done < <(ordered_languages)
}

read_config_language() {
  local key value
  [ -r "$OPSDOCTOR_CONFIG_FILE" ] || return 1
  while IFS='=' read -r key value; do
    key="${key%%[[:space:]]*}"
    value="${value:-}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    if [ "$key" = "OPSDOCTOR_LANG" ]; then
      printf '%s' "$value"
      return 0
    fi
  done < "$OPSDOCTOR_CONFIG_FILE"
  return 1
}

write_language_config() {
  local lang="$1"
  mkdir -p "$OPSDOCTOR_CONFIG_DIR"
  cat > "$OPSDOCTOR_CONFIG_FILE" <<EOF
# OpsDoctor configuration
# Language: auto or one of: $SUPPORTED_LANGUAGES
OPSDOCTOR_LANG=$lang
EOF
  chmod 0644 "$OPSDOCTOR_CONFIG_FILE" 2>/dev/null || true
  printf 'OpsDoctor language set to %s (%s) in %s\n' "$lang" "$(lang_name "$lang")" "$OPSDOCTOR_CONFIG_FILE"
}

parse_language_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lang)
        shift
        if [ "$#" -eq 0 ]; then
          printf 'Error: --lang requires a language code.\n' >&2
          exit 1
        fi
        INSTALL_LANG_REQUESTED="$(normalize_lang "$1")"
        ;;
      --auto-lang)
        INSTALL_LANG_REQUESTED="auto"
        ;;
      --list-languages)
        INSTALL_LIST_LANGUAGES=1
        ;;
      --install-deps|--skip-deps|--no-install-deps|--check-deps)
        ;;
      *)
        printf 'Error: unknown installer option: %s\n' "$1" >&2
        exit 1
        ;;
    esac
    shift
  done
}

configure_language() {
  local current choice selected index code

  if [ "$INSTALL_LIST_LANGUAGES" -eq 1 ]; then
    print_language_list
    exit 0
  fi

  if [ -n "$INSTALL_LANG_REQUESTED" ]; then
    if ! is_supported_lang "$INSTALL_LANG_REQUESTED"; then
      printf 'Unsupported language: %s\n' "$INSTALL_LANG_REQUESTED" >&2
      print_language_list >&2
      exit 1
    fi
    write_language_config "$INSTALL_LANG_REQUESTED"
    return 0
  fi

  current="$(read_config_language 2>/dev/null || true)"
  if [ -n "$current" ]; then
    printf 'Keeping existing OpsDoctor language: %s (%s)\n' "$current" "$(lang_name "$current")"
    return 0
  fi

  if [ ! -t 0 ]; then
    write_language_config "auto"
    return 0
  fi

  printf '\nChoose OpsDoctor language. Installed system locales are listed first.\n'
  printf '  0) %-4s %s [detected: %s]\n' auto "$(lang_name auto)" "$(system_language)"
  index=1
  while IFS= read -r code; do
    if locale_language_installed "$code"; then
      printf '  %s) %-4s %s [installed]\n' "$index" "$code" "$(lang_name "$code")"
    else
      printf '  %s) %-4s %s\n' "$index" "$code" "$(lang_name "$code")"
    fi
    index=$((index + 1))
  done < <(ordered_languages)

  printf 'Language [0]: '
  IFS= read -r choice || choice="0"
  [ -n "$choice" ] || choice="0"

  if [ "$choice" = "0" ] || [ "$(normalize_lang "$choice")" = "auto" ]; then
    selected="auto"
  elif is_supported_lang "$(normalize_lang "$choice")"; then
    selected="$(normalize_lang "$choice")"
  else
    selected=""
    index=1
    while IFS= read -r code; do
      if [ "$choice" = "$index" ]; then
        selected="$code"
        break
      fi
      index=$((index + 1))
    done < <(ordered_languages)
  fi

  if [ -z "$selected" ]; then
    printf 'Invalid language selection: %s\n' "$choice" >&2
    exit 1
  fi

  write_language_config "$selected"
}
