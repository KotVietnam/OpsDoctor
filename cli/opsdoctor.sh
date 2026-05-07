#!/usr/bin/env bash
set -u

OPSDOCTOR_VERSION="0.1.0"
OPSDOCTOR_NAME="OpsDoctor"
OPSDOCTOR_CONFIG_FILE="${OPSDOCTOR_CONFIG_FILE:-/etc/opsdoctor/opsdoctor.conf}"
SUPPORTED_LANGUAGES="en ru es zh hi ar pt fr de ja ko it tr pl uk id vi fa bn ur nl cs sv ro"
INSTALLED_LANG_CACHE=""

USE_COLOR=1
OUTPUT_MODE="terminal"
HTML_OUTPUT_FILE=""
LANG_REQUESTED="${OPSDOCTOR_LANG:-auto}"
LANG_CODE="en"

REPORT_TIMESTAMP=""
HOST_HOSTNAME=""
HOST_OS=""
HOST_KERNEL=""
SCORE=100

COUNT_OK=0
COUNT_WARNING=0
COUNT_CRITICAL=0
COUNT_SKIPPED=0

CHECK_IDS=()
CHECK_CATEGORIES=()
CHECK_TITLES=()
CHECK_STATUSES=()
CHECK_MESSAGES=()
CHECK_FIXES=()
CHECK_CATEGORY_LABELS=()
CHECK_TITLE_LABELS=()
CHECK_STATUS_LABELS=()

COLOR_RESET=""
COLOR_BOLD=""
COLOR_OK=""
COLOR_WARNING=""
COLOR_CRITICAL=""
COLOR_SKIPPED=""
COLOR_DIM=""

lang_name() {
  case "$1" in
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

is_supported_lang() {
  case " $SUPPORTED_LANGUAGES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
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
    iw|he) printf 'en' ;;
    in) printf 'id' ;;
    *) printf '%s' "$raw" ;;
  esac
}

config_language() {
  local line key value
  [ -r "$OPSDOCTOR_CONFIG_FILE" ] || return 1
  while IFS='=' read -r key value; do
    key="$(trim "$key")"
    value="$(trim "${value:-}")"
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

system_language() {
  local candidate
  for candidate in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
    candidate="$(normalize_lang "$candidate")"
    if is_supported_lang "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf 'en'
}

resolve_language() {
  local requested="${1:-auto}"
  local candidate
  requested="$(normalize_lang "$requested")"

  if [ -n "$requested" ] && [ "$requested" != "auto" ]; then
    if is_supported_lang "$requested"; then
      printf '%s' "$requested"
    else
      printf 'en'
    fi
    return 0
  fi

  candidate="$(config_language 2>/dev/null || true)"
  candidate="$(normalize_lang "$candidate")"
  if [ -n "$candidate" ] && [ "$candidate" != "auto" ] && is_supported_lang "$candidate"; then
    printf '%s' "$candidate"
    return 0
  fi

  system_language
}

init_language() {
  LANG_CODE="$(resolve_language "$LANG_REQUESTED")"
}

language_is_installed() {
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
  if ! command_exists locale; then
    INSTALLED_LANG_CACHE="none"
    return 0
  fi
  if command_exists awk; then
    while IFS= read -r code; do
      code="$(normalize_lang "$code")"
      if is_supported_lang "$code"; then
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
    if is_supported_lang "$code"; then
      case " $INSTALLED_LANG_CACHE " in
        *" $code "*) ;;
        *) INSTALLED_LANG_CACHE="$INSTALLED_LANG_CACHE $code" ;;
      esac
    fi
  done < <(locale -a 2>/dev/null)
  [ -n "$INSTALLED_LANG_CACHE" ] || INSTALLED_LANG_CACHE="none"
}

t_en() {
  case "$1" in
    usage_title) printf 'lightweight Linux diagnostics toolkit' ;;
    usage_usage) printf 'Usage' ;;
    usage_commands) printf 'Commands' ;;
    usage_options) printf 'Options' ;;
    usage_examples) printf 'Examples' ;;
    cmd_check) printf 'Run one-shot Linux diagnostics (default command)' ;;
    cmd_version) printf 'Print OpsDoctor version' ;;
    cmd_help) printf 'Show this help' ;;
    cmd_languages) printf 'Show supported languages and system locales' ;;
    opt_json) printf 'Print a valid JSON report to stdout' ;;
    opt_html) printf 'Write a standalone HTML report to FILE' ;;
    opt_no_color) printf 'Disable colored terminal output' ;;
    opt_lang) printf 'Use language LANG (auto, en, ru, es, zh, hi, ar, pt, fr, de, ja, ko, it, tr, pl, uk, id, vi, fa, bn, ur, nl, cs, sv, ro)' ;;
    lang_title) printf 'Supported languages' ;;
    lang_current) printf 'Current language' ;;
    lang_system) printf 'System language' ;;
    lang_installed) printf 'installed' ;;
    lang_not_installed) printf 'not installed' ;;
    host) printf 'Host' ;;
    os) printf 'OS' ;;
    kernel) printf 'Kernel' ;;
    timestamp) printf 'Timestamp' ;;
    summary) printf 'Summary' ;;
    score) printf 'Score' ;;
    out_of_100) printf 'out of 100' ;;
    ok) printf 'OK' ;;
    warning) printf 'WARNING' ;;
    critical) printf 'CRITICAL' ;;
    skipped) printf 'SKIPPED' ;;
    warnings) printf 'Warnings' ;;
    criticals) printf 'Critical' ;;
    checks) printf 'Checks' ;;
    category) printf 'Category' ;;
    status) printf 'Status' ;;
    check) printf 'Check' ;;
    message) printf 'Message' ;;
    fix) printf 'Suggested fix' ;;
    suggested_fixes) printf 'Suggested fixes' ;;
    no_immediate_fixes) printf 'No immediate fixes' ;;
    all_checks_ok_or_skipped) printf 'All checks are OK or skipped.' ;;
    generated_at) printf 'Generated at' ;;
    html_written) printf 'HTML report written to' ;;
    invalid_status_message) printf 'Invalid check status returned' ;;
    report_bug_fix) printf 'Report this as an OpsDoctor bug.' ;;
    *) printf '%s' "$1" ;;
  esac
}

t_ru() {
  case "$1" in
    usage_title) printf 'лёгкий инструмент диагностики Linux' ;;
    usage_usage) printf 'Использование' ;;
    usage_commands) printf 'Команды' ;;
    usage_options) printf 'Опции' ;;
    usage_examples) printf 'Примеры' ;;
    cmd_check) printf 'Запустить одноразовую диагностику Linux (команда по умолчанию)' ;;
    cmd_version) printf 'Показать версию OpsDoctor' ;;
    cmd_help) printf 'Показать эту справку' ;;
    cmd_languages) printf 'Показать поддерживаемые языки и локали системы' ;;
    opt_json) printf 'Вывести валидный JSON-отчёт в stdout' ;;
    opt_html) printf 'Записать автономный HTML-отчёт в FILE' ;;
    opt_no_color) printf 'Отключить цветной вывод в терминале' ;;
    opt_lang) printf 'Использовать язык LANG (auto, en, ru, es, zh, hi, ar, pt, fr, de, ja, ko, it, tr, pl, uk, id, vi, fa, bn, ur, nl, cs, sv, ro)' ;;
    lang_title) printf 'Поддерживаемые языки' ;;
    lang_current) printf 'Текущий язык' ;;
    lang_system) printf 'Язык системы' ;;
    lang_installed) printf 'установлен' ;;
    lang_not_installed) printf 'не установлен' ;;
    host) printf 'Хост' ;;
    os) printf 'ОС' ;;
    kernel) printf 'Ядро' ;;
    timestamp) printf 'Время' ;;
    summary) printf 'Итог' ;;
    score) printf 'Оценка' ;;
    out_of_100) printf 'из 100' ;;
    ok) printf 'OK' ;;
    warning) printf 'ВНИМАНИЕ' ;;
    critical) printf 'КРИТИЧНО' ;;
    skipped) printf 'ПРОПУЩЕНО' ;;
    warnings) printf 'Предупреждения' ;;
    criticals) printf 'Критично' ;;
    checks) printf 'Проверки' ;;
    category) printf 'Раздел' ;;
    status) printf 'Статус' ;;
    check) printf 'Проверка' ;;
    message) printf 'Сообщение' ;;
    fix) printf 'Рекомендация' ;;
    suggested_fixes) printf 'Рекомендации' ;;
    no_immediate_fixes) printf 'Нет срочных исправлений' ;;
    all_checks_ok_or_skipped) printf 'Все проверки в статусе OK или пропущены.' ;;
    generated_at) printf 'Сформировано' ;;
    html_written) printf 'HTML-отчёт записан в' ;;
    invalid_status_message) printf 'Проверка вернула некорректный статус' ;;
    report_bug_fix) printf 'Сообщите об этом как об ошибке OpsDoctor.' ;;
    *) t_en "$1" ;;
  esac
}

t_generic() {
  case "$1" in
    ok) printf 'OK' ;;
    warning)
      case "$LANG_CODE" in
        es) printf 'ADVERTENCIA' ;; zh) printf '警告' ;; hi) printf 'चेतावनी' ;; ar) printf 'تحذير' ;; pt) printf 'AVISO' ;; fr) printf 'AVERTISSEMENT' ;; de) printf 'WARNUNG' ;; ja) printf '警告' ;; ko) printf '경고' ;; it) printf 'AVVISO' ;; tr) printf 'UYARI' ;; pl) printf 'OSTRZEŻENIE' ;; uk) printf 'УВАГА' ;; id) printf 'PERINGATAN' ;; vi) printf 'CẢNH BÁO' ;; fa) printf 'هشدار' ;; bn) printf 'সতর্কতা' ;; ur) printf 'انتباہ' ;; nl) printf 'WAARSCHUWING' ;; cs) printf 'VAROVÁNÍ' ;; sv) printf 'VARNING' ;; ro) printf 'AVERTISMENT' ;; *) t_en "$1" ;; esac ;;
    critical)
      case "$LANG_CODE" in
        es) printf 'CRÍTICO' ;; zh) printf '严重' ;; hi) printf 'गंभीर' ;; ar) printf 'حرج' ;; pt) printf 'CRÍTICO' ;; fr) printf 'CRITIQUE' ;; de) printf 'KRITISCH' ;; ja) printf '重大' ;; ko) printf '치명적' ;; it) printf 'CRITICO' ;; tr) printf 'KRİTİK' ;; pl) printf 'KRYTYCZNE' ;; uk) printf 'КРИТИЧНО' ;; id) printf 'KRITIS' ;; vi) printf 'NGHIÊM TRỌNG' ;; fa) printf 'بحرانی' ;; bn) printf 'গুরুতর' ;; ur) printf 'سنگین' ;; nl) printf 'KRITIEK' ;; cs) printf 'KRITICKÉ' ;; sv) printf 'KRITISKT' ;; ro) printf 'CRITIC' ;; *) t_en "$1" ;; esac ;;
    skipped)
      case "$LANG_CODE" in
        es) printf 'OMITIDO' ;; zh) printf '已跳过' ;; hi) printf 'छोड़ा गया' ;; ar) printf 'تم التخطي' ;; pt) printf 'IGNORADO' ;; fr) printf 'IGNORÉ' ;; de) printf 'ÜBERSPRUNGEN' ;; ja) printf 'スキップ' ;; ko) printf '건너뜀' ;; it) printf 'SALTATO' ;; tr) printf 'ATLANDI' ;; pl) printf 'POMINIĘTE' ;; uk) printf 'ПРОПУЩЕНО' ;; id) printf 'DILEWATI' ;; vi) printf 'BỎ QUA' ;; fa) printf 'رد شد' ;; bn) printf 'এড়ানো হয়েছে' ;; ur) printf 'چھوڑا گیا' ;; nl) printf 'OVERGESLAGEN' ;; cs) printf 'PŘESKOČENO' ;; sv) printf 'HOPPAD' ;; ro) printf 'OMIS' ;; *) t_en "$1" ;; esac ;;
    summary)
      case "$LANG_CODE" in
        es) printf 'Resumen' ;; zh) printf '摘要' ;; hi) printf 'सारांश' ;; ar) printf 'الملخص' ;; pt) printf 'Resumo' ;; fr) printf 'Résumé' ;; de) printf 'Zusammenfassung' ;; ja) printf '概要' ;; ko) printf '요약' ;; it) printf 'Riepilogo' ;; tr) printf 'Özet' ;; pl) printf 'Podsumowanie' ;; uk) printf 'Підсумок' ;; id) printf 'Ringkasan' ;; vi) printf 'Tóm tắt' ;; fa) printf 'خلاصه' ;; bn) printf 'সারাংশ' ;; ur) printf 'خلاصہ' ;; nl) printf 'Samenvatting' ;; cs) printf 'Souhrn' ;; sv) printf 'Sammanfattning' ;; ro) printf 'Rezumat' ;; *) t_en "$1" ;; esac ;;
    score)
      case "$LANG_CODE" in
        es) printf 'Puntuación' ;; zh) printf '评分' ;; hi) printf 'स्कोर' ;; ar) printf 'النتيجة' ;; pt) printf 'Pontuação' ;; fr) printf 'Score' ;; de) printf 'Bewertung' ;; ja) printf 'スコア' ;; ko) printf '점수' ;; it) printf 'Punteggio' ;; tr) printf 'Puan' ;; pl) printf 'Wynik' ;; uk) printf 'Оцінка' ;; id) printf 'Skor' ;; vi) printf 'Điểm' ;; fa) printf 'امتیاز' ;; bn) printf 'স্কোর' ;; ur) printf 'اسکور' ;; nl) printf 'Score' ;; cs) printf 'Skóre' ;; sv) printf 'Poäng' ;; ro) printf 'Scor' ;; *) t_en "$1" ;; esac ;;
    checks)
      case "$LANG_CODE" in
        es) printf 'Comprobaciones' ;; zh) printf '检查' ;; hi) printf 'जांच' ;; ar) printf 'الفحوصات' ;; pt) printf 'Verificações' ;; fr) printf 'Contrôles' ;; de) printf 'Prüfungen' ;; ja) printf 'チェック' ;; ko) printf '검사' ;; it) printf 'Controlli' ;; tr) printf 'Kontroller' ;; pl) printf 'Sprawdzenia' ;; uk) printf 'Перевірки' ;; id) printf 'Pemeriksaan' ;; vi) printf 'Kiểm tra' ;; fa) printf 'بررسی‌ها' ;; bn) printf 'পরীক্ষা' ;; ur) printf 'جانچیں' ;; nl) printf 'Controles' ;; cs) printf 'Kontroly' ;; sv) printf 'Kontroller' ;; ro) printf 'Verificări' ;; *) t_en "$1" ;; esac ;;
    suggested_fixes|fix)
      case "$LANG_CODE" in
        es) printf 'Correcciones sugeridas' ;; zh) printf '建议修复' ;; hi) printf 'सुझाए गए सुधार' ;; ar) printf 'الإصلاحات المقترحة' ;; pt) printf 'Correções sugeridas' ;; fr) printf 'Correctifs suggérés' ;; de) printf 'Empfohlene Korrekturen' ;; ja) printf '推奨修正' ;; ko) printf '권장 수정' ;; it) printf 'Correzioni suggerite' ;; tr) printf 'Önerilen düzeltmeler' ;; pl) printf 'Sugerowane poprawki' ;; uk) printf 'Рекомендації' ;; id) printf 'Perbaikan yang disarankan' ;; vi) printf 'Cách khắc phục đề xuất' ;; fa) printf 'راهکارهای پیشنهادی' ;; bn) printf 'প্রস্তাবিত সমাধান' ;; ur) printf 'تجویز کردہ اصلاحات' ;; nl) printf 'Voorgestelde oplossingen' ;; cs) printf 'Doporučené opravy' ;; sv) printf 'Föreslagna åtgärder' ;; ro) printf 'Remedieri sugerate' ;; *) t_en "$1" ;; esac ;;
    *) t_en "$1" ;;
  esac
}

t() {
  case "$LANG_CODE" in
    ru) t_ru "$1" ;;
    en) t_en "$1" ;;
    *) t_generic "$1" ;;
  esac
}

category_label() {
  local category="$1"
  if [ "$LANG_CODE" = "ru" ]; then
    case "$category" in
      System) printf 'Система' ;;
      Network) printf 'Сеть' ;;
      Security) printf 'Безопасность' ;;
      Services) printf 'Сервисы' ;;
      Packages) printf 'Пакеты' ;;
      Docker) printf 'Docker' ;;
      Nginx) printf 'Nginx' ;;
      *) printf '%s' "$category" ;;
    esac
  else
    printf '%s' "$category"
  fi
}

title_label() {
  local title="$1"
  if [ "$LANG_CODE" = "ru" ]; then
    case "$title" in
      "Hostname") printf 'Имя хоста' ;;
      "Operating system") printf 'Операционная система' ;;
      "Kernel version") printf 'Версия ядра' ;;
      "Uptime") printf 'Время работы' ;;
      "Load average") printf 'Средняя нагрузка' ;;
      "CPU count") printf 'Количество CPU' ;;
      "RAM usage") printf 'Использование RAM' ;;
      "Swap usage") printf 'Использование swap' ;;
      "Root disk usage") printf 'Использование корневого диска' ;;
      "Default gateway") printf 'Шлюз по умолчанию' ;;
      "DNS availability") printf 'Доступность DNS' ;;
      "Internet access") printf 'Доступ в интернет' ;;
      "Listening ports") printf 'Слушающие порты' ;;
      "SSH listening port") printf 'Порт SSH' ;;
      "Hostname resolution") printf 'Разрешение имени хоста' ;;
      "SSH root login") printf 'Root-доступ по SSH' ;;
      "SSH password authentication") printf 'Парольная аутентификация SSH' ;;
      "SSH public key authentication") printf 'Аутентификация SSH по ключам' ;;
      "SSH X11 forwarding") printf 'SSH X11 forwarding' ;;
      "SSH TCP forwarding") printf 'SSH TCP forwarding' ;;
      "UFW firewall") printf 'Фаервол UFW' ;;
      "firewalld") printf 'firewalld' ;;
      "Fail2ban") printf 'Fail2ban' ;;
      "UID 0 users") printf 'Пользователи с UID 0' ;;
      "/etc/passwd permissions") printf 'Права /etc/passwd' ;;
      "/etc/shadow permissions") printf 'Права /etc/shadow' ;;
      "Failed systemd units") printf 'Сбойные systemd units' ;;
      "nginx service") printf 'Сервис nginx' ;;
      "Docker service") printf 'Сервис Docker' ;;
      "cron service") printf 'Сервис cron' ;;
      "SSH service") printf 'Сервис SSH' ;;
      "APT availability") printf 'Доступность APT' ;;
      "Available package updates") printf 'Доступные обновления пакетов' ;;
      "Reboot required") printf 'Требуется перезагрузка' ;;
      "Docker installed") printf 'Docker установлен' ;;
      "Docker daemon") printf 'Docker daemon' ;;
      "Running containers") printf 'Запущенные контейнеры' ;;
      "Stopped containers") printf 'Остановленные контейнеры' ;;
      "Container restart policies") printf 'Политики перезапуска контейнеров' ;;
      "nginx installed") printf 'nginx установлен' ;;
      "nginx running") printf 'nginx запущен' ;;
      "nginx configuration test") printf 'Проверка конфигурации nginx' ;;
      "nginx sites-enabled") printf 'nginx sites-enabled' ;;
      "nginx server_name directives") printf 'Директивы nginx server_name' ;;
      "nginx HTTPS listeners") printf 'HTTPS listeners nginx' ;;
      "Linux platform") printf 'Платформа Linux' ;;
      *) printf '%s' "$title" ;;
    esac
  else
    printf '%s' "$title"
  fi
}

localize_text() {
  local text="$1"
  if [ "$LANG_CODE" = "ru" ]; then
    case "$text" in
      "No action required.") printf 'Действий не требуется.' ;;
      "No action required if this is intentional.") printf 'Действий не требуется, если это сделано намеренно.' ;;
      "OpsDoctor is Linux-only and this host is not Linux.") printf 'OpsDoctor работает только на Linux, а текущий хост не является Linux.' ;;
      "Run OpsDoctor on a Linux server.") printf 'Запустите OpsDoctor на Linux-сервере.' ;;
      "Install coreutils.") printf 'Установите coreutils.' ;;
      "Ensure /proc is mounted.") printf 'Убедитесь, что /proc смонтирован.' ;;
      "Install iproute2 for ss or net-tools for netstat.") printf 'Установите iproute2 для ss или net-tools для netstat.' ;;
      "Install nginx if this host is expected to serve HTTP traffic.") printf 'Установите nginx, если этот хост должен обслуживать HTTP-трафик.' ;;
      "Install Docker only if this host is expected to run containers.") printf 'Установите Docker только если этот хост должен запускать контейнеры.' ;;
      "Package update checks are only supported on Debian/Ubuntu-like systems.") printf 'Проверка обновлений пакетов поддерживается для Debian/Ubuntu-подобных систем.' ;;
      *) printf '%s' "$text" ;;
    esac
  else
    printf '%s' "$text"
  fi
}

usage() {
  init_language
  printf '%s - %s\n\n' "$OPSDOCTOR_NAME" "$(t usage_title)"
  printf '%s:\n' "$(t usage_usage)"
  cat <<EOF
  opsdoctor check [--json] [--html FILE] [--no-color] [--lang LANG]
  opsdoctor version
  opsdoctor languages
  opsdoctor help

$(t usage_commands):
  check              $(t cmd_check)
  version            $(t cmd_version)
  languages          $(t cmd_languages)
  help               $(t cmd_help)

$(t usage_options):
  --json             $(t opt_json)
  --html FILE        $(t opt_html)
  --no-color         $(t opt_no_color)
  --lang LANG        $(t opt_lang)

$(t usage_examples):
  opsdoctor check
  opsdoctor check --json
  opsdoctor check --lang ru
  opsdoctor check --html report.html
EOF
}

is_linux() {
  [ "$(uname -s 2>/dev/null || printf unknown)" = "Linux" ]
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

init_colors() {
  if [ "$USE_COLOR" -eq 1 ] && [ -t 1 ]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_OK=$'\033[32m'
    COLOR_WARNING=$'\033[33m'
    COLOR_CRITICAL=$'\033[31m'
    COLOR_SKIPPED=$'\033[90m'
    COLOR_DIM=$'\033[2m'
  else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_OK=""
    COLOR_WARNING=""
    COLOR_CRITICAL=""
    COLOR_SKIPPED=""
    COLOR_DIM=""
  fi
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

json_escape() {
  local value="${1:-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

html_escape() {
  local value="${1:-}"
  value=${value//&/&amp;}
  value=${value//</&lt;}
  value=${value//>/&gt;}
  value=${value//\"/&quot;}
  value=${value//\'/&#39;}
  printf '%s' "$value"
}

add_check() {
  local category="$1"
  local id="$2"
  local title="$3"
  local status="$4"
  local message="$5"
  local fix="$6"

  case "$status" in
    ok|warning|critical|skipped) ;;
    *) status="skipped"; message="$(t invalid_status_message) $id"; fix="$(t report_bug_fix)" ;;
  esac

  CHECK_CATEGORIES+=("$category")
  CHECK_IDS+=("$id")
  CHECK_TITLES+=("$title")
  CHECK_STATUSES+=("$status")
  CHECK_MESSAGES+=("$(localize_text "$message")")
  CHECK_FIXES+=("$(localize_text "$fix")")
  CHECK_CATEGORY_LABELS+=("$(category_label "$category")")
  CHECK_TITLE_LABELS+=("$(title_label "$title")")
  CHECK_STATUS_LABELS+=("$(status_label "$status")")

  case "$status" in
    ok) COUNT_OK=$((COUNT_OK + 1)) ;;
    warning) COUNT_WARNING=$((COUNT_WARNING + 1)) ;;
    critical) COUNT_CRITICAL=$((COUNT_CRITICAL + 1)) ;;
    skipped) COUNT_SKIPPED=$((COUNT_SKIPPED + 1)) ;;
  esac
}

calculate_score() {
  SCORE=$((100 - (COUNT_WARNING * 3) - (COUNT_CRITICAL * 10)))
  if [ "$SCORE" -lt 0 ]; then
    SCORE=0
  fi
}

timestamp_iso() {
  date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z"
}

read_os_release() {
  if [ -r /etc/os-release ]; then
    (
      PRETTY_NAME=""
      NAME=""
      VERSION_ID=""
      # shellcheck disable=SC1091
      . /etc/os-release
      if [ -n "${PRETTY_NAME:-}" ]; then
        printf '%s' "$PRETTY_NAME"
      elif [ -n "${NAME:-}" ]; then
        printf '%s %s' "$NAME" "${VERSION_ID:-}"
      else
        printf 'Linux'
      fi
    )
  else
    printf 'Linux'
  fi
}

collect_host_info() {
  REPORT_TIMESTAMP="$(timestamp_iso)"
  if command_exists hostname; then
    HOST_HOSTNAME="$(hostname 2>/dev/null || printf unknown)"
  elif [ -r /etc/hostname ]; then
    IFS= read -r HOST_HOSTNAME < /etc/hostname || HOST_HOSTNAME="unknown"
  else
    HOST_HOSTNAME="unknown"
  fi
  HOST_OS="$(read_os_release)"
  HOST_KERNEL="$(uname -r 2>/dev/null || printf unknown)"
}

line_count() {
  local count=0
  local line=""
  while IFS= read -r line; do
    [ -n "$line" ] && count=$((count + 1))
  done
  printf '%s' "$count"
}

systemctl_usable() {
  if ! command_exists systemctl; then
    return 1
  fi
  local output=""
  output="$(systemctl is-system-running 2>&1 || true)"
  case "$output" in
    *"System has not been booted"*|*"Failed to connect"*|offline|unknown)
      return 1
      ;;
  esac
  return 0
}

service_is_active() {
  local unit="$1"
  systemctl_usable || return 1
  systemctl is-active --quiet "$unit" 2>/dev/null
}

service_is_enabled() {
  local unit="$1"
  systemctl_usable || return 1
  systemctl is-enabled --quiet "$unit" 2>/dev/null
}

systemd_unit_known() {
  local unit="$1"
  systemctl_usable || return 1
  systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q "^$unit[[:space:]]"
}

check_system_hostname() {
  if [ -n "$HOST_HOSTNAME" ] && [ "$HOST_HOSTNAME" != "unknown" ]; then
    add_check "System" "system_hostname" "Hostname" "ok" "Hostname is $HOST_HOSTNAME." "No action required."
  else
    add_check "System" "system_hostname" "Hostname" "warning" "Hostname could not be determined." "Set a persistent hostname with hostnamectl set-hostname <name>."
  fi
}

check_system_os() {
  if [ -r /etc/os-release ]; then
    add_check "System" "system_os" "Operating system" "ok" "$HOST_OS." "No action required."
  else
    add_check "System" "system_os" "Operating system" "skipped" "/etc/os-release is not readable." "Use a distribution that provides /etc/os-release."
  fi
}

check_system_kernel() {
  if command_exists uname; then
    add_check "System" "system_kernel" "Kernel version" "ok" "Kernel is $HOST_KERNEL." "No action required."
  else
    add_check "System" "system_kernel" "Kernel version" "skipped" "uname is not available." "Install core system utilities."
  fi
}

check_system_uptime() {
  if [ -r /proc/uptime ]; then
    local up raw days hours minutes
    read -r raw _ < /proc/uptime || raw="0"
    up="${raw%%.*}"
    days=$((up / 86400))
    hours=$(((up % 86400) / 3600))
    minutes=$(((up % 3600) / 60))
    add_check "System" "system_uptime" "Uptime" "ok" "System has been up for ${days}d ${hours}h ${minutes}m." "No action required."
  elif command_exists uptime; then
    add_check "System" "system_uptime" "Uptime" "ok" "$(uptime 2>/dev/null)." "No action required."
  else
    add_check "System" "system_uptime" "Uptime" "skipped" "No uptime source is available." "Ensure /proc is mounted."
  fi
}

check_system_load() {
  if [ ! -r /proc/loadavg ]; then
    add_check "System" "system_load" "Load average" "skipped" "/proc/loadavg is not readable." "Ensure /proc is mounted."
    return
  fi

  local load1 load5 load15 rest cpu load1_int status message fix
  read -r load1 load5 load15 rest < /proc/loadavg || {
    add_check "System" "system_load" "Load average" "skipped" "Could not read load average." "Ensure /proc is mounted."
    return
  }
  cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)"
  case "$cpu" in *[!0-9]*|"") cpu=1 ;; esac
  load1_int="${load1%%.*}"
  case "$load1_int" in *[!0-9]*|"") load1_int=0 ;; esac

  status="ok"
  fix="No action required."
  if [ "$load1_int" -ge $((cpu * 2)) ]; then
    status="critical"
    fix="Inspect CPU-bound processes with top, htop, or ps and scale or tune the workload."
  elif [ "$load1_int" -ge "$cpu" ]; then
    status="warning"
    fix="Review CPU pressure and long-running processes."
  fi
  message="Load average is ${load1}, ${load5}, ${load15} on ${cpu} CPU(s)."
  add_check "System" "system_load" "Load average" "$status" "$message" "$fix"
}

check_system_cpu_count() {
  local cpu=""
  cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [ -z "$cpu" ] && command_exists nproc; then
    cpu="$(nproc 2>/dev/null || true)"
  fi
  if [ -z "$cpu" ] && [ -r /proc/cpuinfo ]; then
    cpu="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
  fi
  case "$cpu" in
    *[!0-9]*|"") add_check "System" "system_cpu_count" "CPU count" "skipped" "CPU count could not be determined." "Ensure /proc is mounted or install coreutils." ;;
    *) add_check "System" "system_cpu_count" "CPU count" "ok" "$cpu CPU(s) detected." "No action required." ;;
  esac
}

check_system_ram() {
  if [ ! -r /proc/meminfo ]; then
    add_check "System" "system_ram_usage" "RAM usage" "skipped" "/proc/meminfo is not readable." "Ensure /proc is mounted."
    return
  fi

  local key value unit total=0 available=0 used percent status fix
  while read -r key value unit; do
    case "$key" in
      MemTotal:) total="$value" ;;
      MemAvailable:) available="$value" ;;
    esac
  done < /proc/meminfo

  if [ "$total" -le 0 ] || [ "$available" -le 0 ]; then
    add_check "System" "system_ram_usage" "RAM usage" "skipped" "Memory statistics could not be parsed." "Ensure /proc/meminfo contains MemTotal and MemAvailable."
    return
  fi

  used=$((total - available))
  percent=$((used * 100 / total))
  status="ok"
  fix="No action required."
  if [ "$percent" -ge 95 ]; then
    status="critical"
    fix="Free memory, reduce workload pressure, or add RAM."
  elif [ "$percent" -ge 85 ]; then
    status="warning"
    fix="Review memory-heavy processes and tune services."
  fi
  add_check "System" "system_ram_usage" "RAM usage" "$status" "RAM usage is ${percent}% (${used} kB used of ${total} kB)." "$fix"
}

check_system_swap() {
  if [ ! -r /proc/meminfo ]; then
    add_check "System" "system_swap_usage" "Swap usage" "skipped" "/proc/meminfo is not readable." "Ensure /proc is mounted."
    return
  fi

  local key value unit total=0 free=0 used percent status fix
  while read -r key value unit; do
    case "$key" in
      SwapTotal:) total="$value" ;;
      SwapFree:) free="$value" ;;
    esac
  done < /proc/meminfo

  if [ "$total" -eq 0 ]; then
    add_check "System" "system_swap_usage" "Swap usage" "ok" "No swap is configured." "No action required if this is intentional."
    return
  fi

  used=$((total - free))
  percent=$((used * 100 / total))
  status="ok"
  fix="No action required."
  if [ "$percent" -ge 80 ]; then
    status="critical"
    fix="Investigate memory pressure and add RAM or swap capacity."
  elif [ "$percent" -ge 50 ]; then
    status="warning"
    fix="Review memory pressure and swap activity."
  fi
  add_check "System" "system_swap_usage" "Swap usage" "$status" "Swap usage is ${percent}% (${used} kB used of ${total} kB)." "$fix"
}

check_system_root_disk() {
  if ! command_exists df; then
    add_check "System" "system_root_disk_usage" "Root disk usage" "skipped" "df is not available." "Install coreutils."
    return
  fi

  local output header line usage percent status fix filesystem size used avail mount
  output="$(df -P / 2>/dev/null || true)"
  {
    read -r header
    read -r line
  } <<< "$output"

  if [ -z "${line:-}" ]; then
    add_check "System" "system_root_disk_usage" "Root disk usage" "skipped" "Could not read disk usage for /." "Ensure the root filesystem is mounted."
    return
  fi

  read -r filesystem size used avail usage mount <<< "$line"
  percent="${usage%\%}"
  case "$percent" in *[!0-9]*|"") percent=0 ;; esac
  status="ok"
  fix="No action required."
  if [ "$percent" -gt 90 ]; then
    status="critical"
    fix="Free disk space, rotate logs, or extend the root filesystem immediately."
  elif [ "$percent" -gt 80 ]; then
    status="warning"
    fix="Clean old logs, packages, caches, or expand the root filesystem."
  fi
  add_check "System" "system_root_disk_usage" "Root disk usage" "$status" "Root filesystem usage is ${usage} (${used} used, ${avail} available)." "$fix"
}

check_network_gateway() {
  local line gateway iface
  if command_exists ip; then
    line="$(ip route show default 2>/dev/null | while IFS= read -r l; do printf '%s' "$l"; break; done)"
    if [ -n "$line" ]; then
      gateway=""
      iface=""
      set -- $line
      while [ "$#" -gt 0 ]; do
        case "$1" in
          via) shift; gateway="${1:-}" ;;
          dev) shift; iface="${1:-}" ;;
        esac
        shift || true
      done
      add_check "Network" "network_default_gateway" "Default gateway" "ok" "Default gateway is ${gateway:-direct} via ${iface:-unknown interface}." "No action required."
      return
    fi
  fi

  if command_exists route; then
    line="$(route -n 2>/dev/null | grep '^0.0.0.0' | while IFS= read -r l; do printf '%s' "$l"; break; done)"
    if [ -n "$line" ]; then
      read -r _ gateway _ _ _ _ _ iface _ <<< "$line"
      add_check "Network" "network_default_gateway" "Default gateway" "ok" "Default gateway is ${gateway:-unknown} via ${iface:-unknown interface}." "No action required."
      return
    fi
  fi

  add_check "Network" "network_default_gateway" "Default gateway" "warning" "No default gateway was found." "Configure a default route for outbound connectivity."
}

check_network_dns() {
  local nameserver_found=0 line
  if [ -r /etc/resolv.conf ]; then
    while IFS= read -r line; do
      case "$line" in
        nameserver*) nameserver_found=1 ;;
      esac
    done < /etc/resolv.conf
  fi

  if [ "$nameserver_found" -eq 0 ]; then
    add_check "Network" "network_dns" "DNS availability" "warning" "No nameserver entry was found in /etc/resolv.conf." "Configure DNS resolvers through systemd-resolved, NetworkManager, or /etc/resolv.conf."
    return
  fi

  if command_exists getent; then
    if getent hosts debian.org >/dev/null 2>&1; then
      add_check "Network" "network_dns" "DNS availability" "ok" "DNS resolution works for debian.org." "No action required."
    else
      add_check "Network" "network_dns" "DNS availability" "warning" "DNS resolver is configured but external hostname resolution failed." "Check resolver IPs, firewall rules, and upstream DNS reachability."
    fi
  else
    add_check "Network" "network_dns" "DNS availability" "skipped" "getent is not available; found nameserver entries but could not test resolution." "Install libc-bin or equivalent name service tools."
  fi
}

check_network_internet() {
  if ! command_exists ping; then
    add_check "Network" "network_internet_access" "Internet access" "skipped" "ping is not available." "Install iputils-ping or test connectivity with another tool."
    return
  fi

  if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    add_check "Network" "network_internet_access" "Internet access" "ok" "ICMP connectivity to 1.1.1.1 works." "No action required."
  elif ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    add_check "Network" "network_internet_access" "Internet access" "ok" "ICMP connectivity to 8.8.8.8 works." "No action required."
  else
    add_check "Network" "network_internet_access" "Internet access" "warning" "ICMP checks to 1.1.1.1 and 8.8.8.8 failed." "Check routing, firewall policy, provider connectivity, or ICMP filtering."
  fi
}

listening_ports_output() {
  if command_exists ss; then
    ss -tulpen 2>/dev/null
  elif command_exists netstat; then
    netstat -tulpen 2>/dev/null
  else
    return 1
  fi
}

check_network_listening_ports() {
  local output count
  output="$(listening_ports_output || true)"
  if [ -z "$output" ]; then
    add_check "Network" "network_listening_ports" "Listening ports" "skipped" "Neither ss nor netstat produced listening port data." "Install iproute2 for ss or net-tools for netstat."
    return
  fi
  count="$(printf '%s\n' "$output" | grep -E 'LISTEN|UNCONN|udp|tcp' | grep -vE '^Netid|^Proto' | line_count)"
  if [ "$count" -gt 0 ]; then
    add_check "Network" "network_listening_ports" "Listening ports" "ok" "$count listening UDP/TCP socket(s) found." "Review exposed services regularly."
  else
    add_check "Network" "network_listening_ports" "Listening ports" "warning" "No listening UDP/TCP sockets were detected." "Confirm that expected services are running and visible to ss/netstat."
  fi
}

get_ssh_option() {
  local wanted="$1"
  local value=""
  local line key val file

  if command_exists sshd; then
    while read -r key val _; do
      key="${key,,}"
      if [ "$key" = "$wanted" ]; then
        printf '%s' "$val"
        return 0
      fi
    done < <(sshd -T 2>/dev/null || true)
  fi

  local files=("/etc/ssh/sshd_config")
  shopt -s nullglob
  for file in /etc/ssh/sshd_config.d/*.conf; do
    files+=("$file")
  done
  shopt -u nullglob

  for file in "${files[@]}"; do
    [ -r "$file" ] || continue
    while IFS= read -r line; do
      line="$(trim "${line%%#*}")"
      [ -n "$line" ] || continue
      read -r key val _ <<< "$line"
      key="${key,,}"
      if [ "$key" = "$wanted" ]; then
        value="$val"
      fi
    done < "$file"
  done

  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  return 1
}

get_ssh_port() {
  local port=""
  port="$(get_ssh_option "port" 2>/dev/null || true)"
  case "$port" in
    *[!0-9]*|"") printf '22' ;;
    *) printf '%s' "$port" ;;
  esac
}

check_network_ssh_port() {
  local port output
  port="$(get_ssh_port)"
  output="$(listening_ports_output || true)"
  if [ -z "$output" ]; then
    add_check "Network" "network_ssh_port" "SSH listening port" "skipped" "Could not inspect listening sockets." "Install iproute2 for ss or net-tools for netstat."
    return
  fi

  if printf '%s\n' "$output" | grep -Eq "[:.]${port}[[:space:]].*(LISTEN|users:|sshd)|LISTEN[[:space:]].*[:.]${port}[[:space:]]"; then
    add_check "Network" "network_ssh_port" "SSH listening port" "ok" "SSH appears to be listening on port $port." "No action required."
  else
    add_check "Network" "network_ssh_port" "SSH listening port" "warning" "SSH does not appear to be listening on configured/default port $port." "Start ssh/sshd or update firewall and sshd_config if SSH uses another port."
  fi
}

check_network_hostname_resolution() {
  local host
  host="$HOST_HOSTNAME"
  if [ -z "$host" ] || [ "$host" = "unknown" ]; then
    add_check "Network" "network_hostname_resolution" "Hostname resolution" "warning" "Hostname is unknown, so local resolution cannot be tested." "Set a persistent hostname and add it to DNS or /etc/hosts."
    return
  fi
  if ! command_exists getent; then
    add_check "Network" "network_hostname_resolution" "Hostname resolution" "skipped" "getent is not available." "Install libc-bin or equivalent name service tools."
    return
  fi
  if getent hosts "$host" >/dev/null 2>&1; then
    add_check "Network" "network_hostname_resolution" "Hostname resolution" "ok" "Hostname $host resolves locally." "No action required."
  else
    add_check "Network" "network_hostname_resolution" "Hostname resolution" "warning" "Hostname $host does not resolve through NSS." "Add the hostname to DNS or /etc/hosts."
  fi
}

check_ssh_setting() {
  local id="$1"
  local title="$2"
  local option="$3"
  local good_value="$4"
  local bad_value="$5"
  local bad_status="$6"
  local fix="$7"
  local value
  value="$(get_ssh_option "$option" 2>/dev/null || true)"

  if [ -z "$value" ]; then
    add_check "Security" "$id" "$title" "skipped" "Could not determine effective SSH setting $option." "Install openssh-server or review /etc/ssh/sshd_config manually."
    return
  fi

  value="${value,,}"
  if [ "$value" = "$good_value" ]; then
    add_check "Security" "$id" "$title" "ok" "$option is set to $value." "No action required."
  elif [ "$value" = "$bad_value" ]; then
    add_check "Security" "$id" "$title" "$bad_status" "$option is set to $value." "$fix"
  else
    add_check "Security" "$id" "$title" "warning" "$option is set to $value." "Review whether $option=$value matches your hardening baseline."
  fi
}

check_security_ssh() {
  check_ssh_setting "ssh_root_login" "SSH root login" "permitrootlogin" "no" "yes" "critical" "Set PermitRootLogin no in /etc/ssh/sshd_config and restart ssh."
  check_ssh_setting "ssh_password_auth" "SSH password authentication" "passwordauthentication" "no" "yes" "warning" "Use key-based SSH and set PasswordAuthentication no."
  check_ssh_setting "ssh_pubkey_auth" "SSH public key authentication" "pubkeyauthentication" "yes" "no" "warning" "Set PubkeyAuthentication yes and restart ssh."
  check_ssh_setting "ssh_x11_forwarding" "SSH X11 forwarding" "x11forwarding" "no" "yes" "warning" "Set X11Forwarding no unless GUI forwarding is explicitly required."
  check_ssh_setting "ssh_tcp_forwarding" "SSH TCP forwarding" "allowtcpforwarding" "no" "yes" "warning" "Set AllowTcpForwarding no unless tunnels are required."
}

check_security_ufw() {
  if ! command_exists ufw; then
    add_check "Security" "firewall_ufw" "UFW firewall" "skipped" "ufw is not installed." "Install and enable ufw if it is your chosen firewall frontend."
    return
  fi
  local status
  status="$(ufw status 2>/dev/null | while IFS= read -r l; do printf '%s' "$l"; break; done)"
  case "$status" in
    *inactive*) add_check "Security" "firewall_ufw" "UFW firewall" "warning" "UFW is installed but inactive." "Enable ufw or document the alternative firewall in use." ;;
    *active*) add_check "Security" "firewall_ufw" "UFW firewall" "ok" "UFW is active." "No action required." ;;
    *) add_check "Security" "firewall_ufw" "UFW firewall" "warning" "UFW status could not be determined." "Run ufw status and verify firewall policy." ;;
  esac
}

check_security_firewalld() {
  if ! command_exists firewall-cmd && ! systemctl_usable; then
    add_check "Security" "firewall_firewalld" "firewalld" "skipped" "firewalld is not installed or systemctl is unavailable." "Install and enable firewalld if it is your chosen firewall frontend."
    return
  fi

  if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    add_check "Security" "firewall_firewalld" "firewalld" "ok" "firewalld is running." "No action required."
  elif systemd_unit_known firewalld.service; then
    if service_is_active firewalld.service; then
      add_check "Security" "firewall_firewalld" "firewalld" "ok" "firewalld service is active." "No action required."
    else
      add_check "Security" "firewall_firewalld" "firewalld" "warning" "firewalld is installed but inactive." "Enable firewalld or document the alternative firewall in use."
    fi
  else
    add_check "Security" "firewall_firewalld" "firewalld" "skipped" "firewalld is not installed." "Install and enable firewalld if it is your chosen firewall frontend."
  fi
}

check_security_fail2ban() {
  local installed=0
  if command_exists fail2ban-client; then
    installed=1
  elif systemd_unit_known fail2ban.service; then
    installed=1
  fi

  if [ "$installed" -eq 0 ]; then
    add_check "Security" "fail2ban_status" "Fail2ban" "warning" "fail2ban is not installed." "Install fail2ban to protect SSH and other exposed services from brute-force attempts."
    return
  fi

  if service_is_active fail2ban.service || (command_exists fail2ban-client && fail2ban-client ping >/dev/null 2>&1); then
    add_check "Security" "fail2ban_status" "Fail2ban" "ok" "fail2ban is installed and running." "No action required."
  else
    add_check "Security" "fail2ban_status" "Fail2ban" "warning" "fail2ban is installed but not running." "Enable and start fail2ban.service."
  fi
}

check_security_uid0() {
  if [ ! -r /etc/passwd ]; then
    add_check "Security" "uid0_users" "UID 0 users" "skipped" "/etc/passwd is not readable." "Run as a privileged user or inspect /etc/passwd permissions."
    return
  fi

  local user pass uid gid rest extra=""
  while IFS=: read -r user pass uid gid rest; do
    if [ "$uid" = "0" ] && [ "$user" != "root" ]; then
      if [ -z "$extra" ]; then
        extra="$user"
      else
        extra="$extra, $user"
      fi
    fi
  done < /etc/passwd

  if [ -n "$extra" ]; then
    add_check "Security" "uid0_users" "UID 0 users" "critical" "Additional UID 0 user(s) found: $extra." "Remove UID 0 from non-root accounts unless explicitly required and audited."
  else
    add_check "Security" "uid0_users" "UID 0 users" "ok" "No UID 0 users besides root were found." "No action required."
  fi
}

check_security_passwd_permissions() {
  if ! command_exists stat; then
    add_check "Security" "passwd_permissions" "/etc/passwd permissions" "skipped" "stat is not available." "Install coreutils."
    return
  fi
  if [ ! -e /etc/passwd ]; then
    add_check "Security" "passwd_permissions" "/etc/passwd permissions" "critical" "/etc/passwd is missing." "Restore /etc/passwd from backup or recovery media."
    return
  fi
  local mode owner group
  mode="$(stat -c '%a' /etc/passwd 2>/dev/null || true)"
  owner="$(stat -c '%U' /etc/passwd 2>/dev/null || true)"
  group="$(stat -c '%G' /etc/passwd 2>/dev/null || true)"
  if [ "$mode" = "644" ] && [ "$owner" = "root" ] && [ "$group" = "root" ]; then
    add_check "Security" "passwd_permissions" "/etc/passwd permissions" "ok" "/etc/passwd is $mode $owner:$group." "No action required."
  else
    add_check "Security" "passwd_permissions" "/etc/passwd permissions" "warning" "/etc/passwd is $mode $owner:$group; expected 644 root:root." "Run chown root:root /etc/passwd && chmod 644 /etc/passwd."
  fi
}

check_security_shadow_permissions() {
  if ! command_exists stat; then
    add_check "Security" "shadow_permissions" "/etc/shadow permissions" "skipped" "stat is not available." "Install coreutils."
    return
  fi
  if [ ! -e /etc/shadow ]; then
    add_check "Security" "shadow_permissions" "/etc/shadow permissions" "critical" "/etc/shadow is missing." "Restore /etc/shadow from backup or recovery media."
    return
  fi
  local mode owner group status fix
  mode="$(stat -c '%a' /etc/shadow 2>/dev/null || true)"
  owner="$(stat -c '%U' /etc/shadow 2>/dev/null || true)"
  group="$(stat -c '%G' /etc/shadow 2>/dev/null || true)"
  status="warning"
  fix="Run chown root:shadow /etc/shadow && chmod 640 /etc/shadow, or use your distribution's documented secure mode."
  if [ "$owner" = "root" ] && { [ "$mode" = "640" ] || [ "$mode" = "600" ]; }; then
    status="ok"
    fix="No action required."
  fi
  add_check "Security" "shadow_permissions" "/etc/shadow permissions" "$status" "/etc/shadow is $mode $owner:$group." "$fix"
}

check_services_failed_units() {
  if ! systemctl_usable; then
    add_check "Services" "systemd_failed_units" "Failed systemd units" "skipped" "systemctl is unavailable or systemd is not PID 1." "Run this check on a systemd-based Linux host."
    return
  fi
  local failed count
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
  count="$(printf '%s\n' "$failed" | line_count)"
  if [ "$count" -eq 0 ]; then
    add_check "Services" "systemd_failed_units" "Failed systemd units" "ok" "No failed systemd units." "No action required."
  else
    add_check "Services" "systemd_failed_units" "Failed systemd units" "critical" "$count failed systemd unit(s) found." "Run systemctl --failed and inspect journalctl -xeu <unit>."
  fi
}

check_service_installed_running() {
  local id="$1"
  local title="$2"
  local command_name="$3"
  local units="$4"
  local category="${5:-Services}"
  local installed=0 unit active=0 enabled=0 enabled_text="unknown"

  if command_exists "$command_name"; then
    installed=1
  fi

  if systemctl_usable; then
    for unit in $units; do
      if systemd_unit_known "$unit" || systemctl status "$unit" >/dev/null 2>&1; then
        installed=1
        if service_is_active "$unit"; then
          active=1
        fi
        if service_is_enabled "$unit"; then
          enabled=1
        fi
      fi
    done
    if [ "$enabled" -eq 1 ]; then
      enabled_text="enabled"
    else
      enabled_text="not enabled"
    fi
  fi

  if [ "$installed" -eq 0 ]; then
    add_check "$category" "$id" "$title" "skipped" "$title is not installed." "Install $title if this host is expected to run it."
  elif [ "$active" -eq 1 ]; then
    add_check "$category" "$id" "$title" "ok" "$title is installed, running, and $enabled_text." "No action required."
  elif ! systemctl_usable; then
    add_check "$category" "$id" "$title" "skipped" "$title appears installed, but systemctl is unavailable." "Check service state with your init system."
  else
    add_check "$category" "$id" "$title" "warning" "$title is installed but not running." "Start and enable the relevant service with systemctl."
  fi
}

check_services_common() {
  check_service_installed_running "service_nginx" "nginx service" "nginx" "nginx.service"
  check_service_installed_running "service_docker" "Docker service" "docker" "docker.service"
  if command_exists cron || command_exists crond || [ -x /usr/sbin/cron ] || [ -x /usr/sbin/crond ]; then
    check_service_installed_running "service_cron" "cron service" "cron" "cron.service crond.service"
  else
    add_check "Services" "service_cron" "cron service" "skipped" "cron is not installed." "Install cron if scheduled jobs are required on this host."
  fi
  if command_exists sshd || [ -x /usr/sbin/sshd ] || [ -x /usr/sbin/ssh ]; then
    check_service_installed_running "service_ssh" "SSH service" "sshd" "ssh.service sshd.service"
  else
    add_check "Services" "service_ssh" "SSH service" "skipped" "OpenSSH server is not installed." "Install openssh-server if remote SSH access is required."
  fi
}

check_packages_apt() {
  if command_exists apt-get || command_exists apt; then
    add_check "Packages" "packages_apt_available" "APT availability" "ok" "APT is available." "No action required."
  else
    add_check "Packages" "packages_apt_available" "APT availability" "skipped" "APT is not available." "Package update checks are only supported on Debian/Ubuntu-like systems."
  fi
}

check_packages_updates() {
  if ! command_exists apt-get; then
    add_check "Packages" "packages_updates" "Available package updates" "skipped" "apt-get is not available." "Run this check on Debian/Ubuntu or install apt."
    return
  fi
  local output count
  output="$(apt-get -s upgrade 2>/dev/null || true)"
  if [ -z "$output" ]; then
    add_check "Packages" "packages_updates" "Available package updates" "skipped" "Could not simulate apt upgrade." "Run apt-get update and retry, or inspect APT configuration."
    return
  fi
  count="$(printf '%s\n' "$output" | grep -c '^Inst ' 2>/dev/null || true)"
  case "$count" in *[!0-9]*|"") count=0 ;; esac
  if [ "$count" -eq 0 ]; then
    add_check "Packages" "packages_updates" "Available package updates" "ok" "No package updates are currently visible to APT." "Keep package indexes fresh with apt-get update."
  elif [ "$count" -ge 50 ]; then
    add_check "Packages" "packages_updates" "Available package updates" "warning" "$count package update(s) are available." "Schedule maintenance and apply security updates."
  else
    add_check "Packages" "packages_updates" "Available package updates" "warning" "$count package update(s) are available." "Review and apply updates during a maintenance window."
  fi
}

check_packages_reboot_required() {
  if [ -e /var/run/reboot-required ]; then
    add_check "Packages" "packages_reboot_required" "Reboot required" "warning" "A reboot is required by installed packages." "Schedule a reboot to finish kernel or library updates."
  else
    add_check "Packages" "packages_reboot_required" "Reboot required" "ok" "No /var/run/reboot-required marker found." "No action required."
  fi
}

docker_daemon_ready() {
  command_exists docker || return 1
  docker info >/dev/null 2>&1
}

check_docker_installed() {
  if command_exists docker; then
    add_check "Docker" "docker_installed" "Docker installed" "ok" "Docker CLI is installed." "No action required."
  else
    add_check "Docker" "docker_installed" "Docker installed" "skipped" "Docker CLI is not installed." "Install Docker only if this host is expected to run containers."
  fi
}

check_docker_daemon() {
  if ! command_exists docker; then
    add_check "Docker" "docker_daemon" "Docker daemon" "skipped" "Docker CLI is not installed." "Install Docker before checking the daemon."
    return
  fi
  if docker_daemon_ready; then
    add_check "Docker" "docker_daemon" "Docker daemon" "ok" "Docker daemon is reachable." "No action required."
  else
    add_check "Docker" "docker_daemon" "Docker daemon" "warning" "Docker CLI is installed but the daemon is not reachable." "Start docker.service or check Docker socket permissions."
  fi
}

check_docker_running_count() {
  if ! docker_daemon_ready; then
    add_check "Docker" "docker_running_containers" "Running containers" "skipped" "Docker daemon is not reachable." "Start docker.service before collecting container inventory."
    return
  fi
  local count
  count="$(docker ps -q 2>/dev/null | line_count)"
  add_check "Docker" "docker_running_containers" "Running containers" "ok" "$count running container(s)." "No action required."
}

check_docker_stopped_count() {
  if ! docker_daemon_ready; then
    add_check "Docker" "docker_stopped_containers" "Stopped containers" "skipped" "Docker daemon is not reachable." "Start docker.service before collecting container inventory."
    return
  fi
  local count status fix
  count="$(docker ps -a -f status=exited -f status=created -q 2>/dev/null | line_count)"
  status="ok"
  fix="No action required."
  if [ "$count" -gt 0 ]; then
    status="warning"
    fix="Remove stale containers with docker container prune after confirming they are no longer needed."
  fi
  add_check "Docker" "docker_stopped_containers" "Stopped containers" "$status" "$count stopped or created container(s)." "$fix"
}

check_docker_restart_policy() {
  if ! docker_daemon_ready; then
    add_check "Docker" "docker_restart_policy" "Container restart policies" "skipped" "Docker daemon is not reachable." "Start docker.service before checking restart policies."
    return
  fi
  local ids id policy name offenders=""
  ids="$(docker ps -q 2>/dev/null || true)"
  if [ -z "$ids" ]; then
    add_check "Docker" "docker_restart_policy" "Container restart policies" "ok" "No running containers to inspect." "No action required."
    return
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$id" 2>/dev/null || printf unknown)"
    name="$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##' || printf "$id")"
    if [ "$policy" = "no" ] || [ -z "$policy" ]; then
      if [ -z "$offenders" ]; then
        offenders="$name"
      else
        offenders="$offenders, $name"
      fi
    fi
  done <<< "$ids"
  if [ -n "$offenders" ]; then
    add_check "Docker" "docker_restart_policy" "Container restart policies" "warning" "Running container(s) without restart policy: $offenders." "Set an explicit restart policy such as --restart unless-stopped for long-lived services."
  else
    add_check "Docker" "docker_restart_policy" "Container restart policies" "ok" "Running containers have explicit restart policies." "No action required."
  fi
}

nginx_installed() {
  command_exists nginx
}

check_nginx_installed() {
  if nginx_installed; then
    add_check "Nginx" "nginx_installed" "nginx installed" "ok" "nginx binary is available." "No action required."
  else
    add_check "Nginx" "nginx_installed" "nginx installed" "skipped" "nginx is not installed." "Install nginx if this host is expected to serve HTTP traffic."
  fi
}

check_nginx_running() {
  if ! nginx_installed; then
    add_check "Nginx" "nginx_running" "nginx running" "skipped" "nginx is not installed." "Install nginx before checking runtime state."
    return
  fi
  if service_is_active nginx.service; then
    add_check "Nginx" "nginx_running" "nginx running" "ok" "nginx service is running." "No action required."
  elif command_exists pgrep && pgrep -x nginx >/dev/null 2>&1; then
    add_check "Nginx" "nginx_running" "nginx running" "ok" "nginx process is running." "No action required."
  else
    add_check "Nginx" "nginx_running" "nginx running" "warning" "nginx is installed but not running." "Start nginx.service and inspect logs if it fails."
  fi
}

check_nginx_config_test() {
  if ! nginx_installed; then
    add_check "Nginx" "nginx_config_test" "nginx configuration test" "skipped" "nginx is not installed." "Install nginx before testing configuration."
    return
  fi
  local output
  output="$(nginx -t 2>&1 || true)"
  if printf '%s\n' "$output" | grep -q "test is successful"; then
    add_check "Nginx" "nginx_config_test" "nginx configuration test" "ok" "nginx -t completed successfully." "No action required."
  else
    add_check "Nginx" "nginx_config_test" "nginx configuration test" "critical" "nginx -t failed: $(printf '%s' "$output" | tr '\n' ' ' | cut -c 1-180)." "Run nginx -t, fix reported configuration errors, then reload nginx."
  fi
}

check_nginx_sites_enabled() {
  if [ -d /etc/nginx/sites-enabled ]; then
    add_check "Nginx" "nginx_sites_enabled" "nginx sites-enabled" "ok" "/etc/nginx/sites-enabled exists." "No action required."
  elif nginx_installed; then
    add_check "Nginx" "nginx_sites_enabled" "nginx sites-enabled" "warning" "/etc/nginx/sites-enabled does not exist." "This may be normal on non-Debian layouts; otherwise create sites-enabled and include it from nginx.conf."
  else
    add_check "Nginx" "nginx_sites_enabled" "nginx sites-enabled" "skipped" "nginx is not installed." "Install nginx before checking site directories."
  fi
}

nginx_config_files() {
  local dirs=()
  [ -d /etc/nginx/sites-enabled ] && dirs+=("/etc/nginx/sites-enabled")
  [ -d /etc/nginx/conf.d ] && dirs+=("/etc/nginx/conf.d")
  if [ "${#dirs[@]}" -eq 0 ]; then
    return 1
  fi
  find -L "${dirs[@]}" -type f 2>/dev/null
}

check_nginx_server_name() {
  if ! nginx_installed; then
    add_check "Nginx" "nginx_missing_server_name" "nginx server_name directives" "skipped" "nginx is not installed." "Install nginx before scanning virtual host files."
    return
  fi
  local files file total=0 missing=0 examples=""
  files="$(nginx_config_files || true)"
  if [ -z "$files" ]; then
    add_check "Nginx" "nginx_missing_server_name" "nginx server_name directives" "skipped" "No nginx site configuration files were found." "Add site files under /etc/nginx/sites-enabled or /etc/nginx/conf.d."
    return
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    total=$((total + 1))
    if ! grep -Eq '^[[:space:]]*server_name[[:space:]]+' "$file" 2>/dev/null; then
      missing=$((missing + 1))
      [ -z "$examples" ] && examples="$file"
    fi
  done <<< "$files"
  if [ "$missing" -gt 0 ]; then
    add_check "Nginx" "nginx_missing_server_name" "nginx server_name directives" "warning" "$missing of $total nginx config file(s) do not contain server_name. Example: $examples." "Add explicit server_name directives to nginx server blocks."
  else
    add_check "Nginx" "nginx_missing_server_name" "nginx server_name directives" "ok" "All scanned nginx config files contain server_name directives." "No action required."
  fi
}

check_nginx_https() {
  if ! nginx_installed; then
    add_check "Nginx" "nginx_missing_https" "nginx HTTPS listeners" "skipped" "nginx is not installed." "Install nginx before scanning HTTPS listeners."
    return
  fi
  local files file total=0 missing=0 examples=""
  files="$(nginx_config_files || true)"
  if [ -z "$files" ]; then
    add_check "Nginx" "nginx_missing_https" "nginx HTTPS listeners" "skipped" "No nginx site configuration files were found." "Add site files under /etc/nginx/sites-enabled or /etc/nginx/conf.d."
    return
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    total=$((total + 1))
    if ! grep -Eq 'listen[[:space:]]+(\[::\]:)?443|ssl_certificate' "$file" 2>/dev/null; then
      missing=$((missing + 1))
      [ -z "$examples" ] && examples="$file"
    fi
  done <<< "$files"
  if [ "$missing" -gt 0 ]; then
    add_check "Nginx" "nginx_missing_https" "nginx HTTPS listeners" "warning" "$missing of $total nginx config file(s) do not appear to define HTTPS/listen 443. Example: $examples." "Enable TLS with listen 443 ssl and valid certificates where public HTTP services are expected."
  else
    add_check "Nginx" "nginx_missing_https" "nginx HTTPS listeners" "ok" "Scanned nginx config files appear to include HTTPS listeners or certificates." "No action required."
  fi
}

run_all_checks() {
  collect_host_info

  if ! is_linux; then
    add_check "System" "linux_only" "Linux platform" "critical" "OpsDoctor is Linux-only and this host is not Linux." "Run OpsDoctor on a Linux server."
    calculate_score
    return
  fi

  check_system_hostname
  check_system_os
  check_system_kernel
  check_system_uptime
  check_system_load
  check_system_cpu_count
  check_system_ram
  check_system_swap
  check_system_root_disk

  check_network_gateway
  check_network_dns
  check_network_internet
  check_network_listening_ports
  check_network_ssh_port
  check_network_hostname_resolution

  check_security_ssh
  check_security_ufw
  check_security_firewalld
  check_security_fail2ban
  check_security_uid0
  check_security_passwd_permissions
  check_security_shadow_permissions

  check_services_failed_units
  check_services_common

  check_packages_apt
  check_packages_updates
  check_packages_reboot_required

  check_docker_installed
  check_docker_daemon
  check_docker_running_count
  check_docker_stopped_count
  check_docker_restart_policy

  check_nginx_installed
  check_nginx_running
  check_nginx_config_test
  check_nginx_sites_enabled
  check_nginx_server_name
  check_nginx_https

  calculate_score
}

status_color() {
  case "$1" in
    ok) printf '%s' "$COLOR_OK" ;;
    warning) printf '%s' "$COLOR_WARNING" ;;
    critical) printf '%s' "$COLOR_CRITICAL" ;;
    skipped) printf '%s' "$COLOR_SKIPPED" ;;
    *) printf '%s' "$COLOR_RESET" ;;
  esac
}

status_label() {
  case "$1" in
    ok) t ok ;;
    warning) t warning ;;
    critical) t critical ;;
    skipped) t skipped ;;
    *) printf '%s' "$1" ;;
  esac
}

print_terminal_report() {
  init_colors
  local categories=("System" "Network" "Security" "Services" "Packages" "Docker" "Nginx")
  local category i status color label

  printf '%s%s%s %s%s%s\n' "$COLOR_BOLD" "$OPSDOCTOR_NAME" "$COLOR_RESET" "$COLOR_DIM" "$OPSDOCTOR_VERSION" "$COLOR_RESET"
  printf '%s: %s | %s: %s | %s: %s\n' "$(t host)" "$HOST_HOSTNAME" "$(t os)" "$HOST_OS" "$(t kernel)" "$HOST_KERNEL"
  printf '%s: %s | %s: %s\n\n' "$(t timestamp)" "$REPORT_TIMESTAMP" "$(t lang_current)" "$LANG_CODE"

  for category in "${categories[@]}"; do
    printf '%s%s%s\n' "$COLOR_BOLD" "$(category_label "$category")" "$COLOR_RESET"
    for i in "${!CHECK_IDS[@]}"; do
      [ "${CHECK_CATEGORIES[$i]}" = "$category" ] || continue
      status="${CHECK_STATUSES[$i]}"
      color="$(status_color "$status")"
      label="${CHECK_STATUS_LABELS[$i]}"
      printf '  %s%-12s%s  %-34s %s\n' "$color" "$label" "$COLOR_RESET" "${CHECK_TITLE_LABELS[$i]}" "${CHECK_MESSAGES[$i]}"
    done
    printf '\n'
  done

  printf '%s%s%s\n' "$COLOR_BOLD" "$(t summary)" "$COLOR_RESET"
  printf '  %s: %s%s%s/100\n' "$(t score)" "$(status_color_from_score "$SCORE")" "$SCORE" "$COLOR_RESET"
  printf '  %s: %s | %s: %s | %s: %s | %s: %s\n' "$(t ok)" "$COUNT_OK" "$(t warnings)" "$COUNT_WARNING" "$(t criticals)" "$COUNT_CRITICAL" "$(t skipped)" "$COUNT_SKIPPED"
}

status_color_from_score() {
  local score="$1"
  if [ "$score" -ge 90 ]; then
    printf '%s' "$COLOR_OK"
  elif [ "$score" -ge 70 ]; then
    printf '%s' "$COLOR_WARNING"
  else
    printf '%s' "$COLOR_CRITICAL"
  fi
}

print_json_report() {
  local i
  printf '{\n'
  printf '  "tool": "%s",\n' "$(json_escape "$OPSDOCTOR_NAME")"
  printf '  "version": "%s",\n' "$(json_escape "$OPSDOCTOR_VERSION")"
  printf '  "language": "%s",\n' "$(json_escape "$LANG_CODE")"
  printf '  "timestamp": "%s",\n' "$(json_escape "$REPORT_TIMESTAMP")"
  printf '  "host": {\n'
  printf '    "hostname": "%s",\n' "$(json_escape "$HOST_HOSTNAME")"
  printf '    "os": "%s",\n' "$(json_escape "$HOST_OS")"
  printf '    "kernel": "%s"\n' "$(json_escape "$HOST_KERNEL")"
  printf '  },\n'
  printf '  "score": %s,\n' "$SCORE"
  printf '  "summary": {\n'
  printf '    "ok": %s,\n' "$COUNT_OK"
  printf '    "warning": %s,\n' "$COUNT_WARNING"
  printf '    "critical": %s,\n' "$COUNT_CRITICAL"
  printf '    "skipped": %s\n' "$COUNT_SKIPPED"
  printf '  },\n'
  printf '  "checks": [\n'
  for i in "${!CHECK_IDS[@]}"; do
    if [ "$i" -gt 0 ]; then
      printf ',\n'
    fi
    printf '    {\n'
    printf '      "id": "%s",\n' "$(json_escape "${CHECK_IDS[$i]}")"
    printf '      "category": "%s",\n' "$(json_escape "${CHECK_CATEGORIES[$i]}")"
    printf '      "category_label": "%s",\n' "$(json_escape "${CHECK_CATEGORY_LABELS[$i]}")"
    printf '      "title": "%s",\n' "$(json_escape "${CHECK_TITLES[$i]}")"
    printf '      "title_label": "%s",\n' "$(json_escape "${CHECK_TITLE_LABELS[$i]}")"
    printf '      "status": "%s",\n' "$(json_escape "${CHECK_STATUSES[$i]}")"
    printf '      "status_label": "%s",\n' "$(json_escape "${CHECK_STATUS_LABELS[$i]}")"
    printf '      "message": "%s",\n' "$(json_escape "${CHECK_MESSAGES[$i]}")"
    printf '      "fix": "%s"\n' "$(json_escape "${CHECK_FIXES[$i]}")"
    printf '    }'
  done
  printf '\n  ]\n'
  printf '}\n'
}

print_html_report() {
  local i status safe_title safe_message safe_fix safe_category
  cat <<EOF
<!doctype html>
<html lang="$(html_escape "$LANG_CODE")">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpsDoctor Report - $(html_escape "$HOST_HOSTNAME")</title>
  <style>
    :root { color-scheme: dark; --bg: #101316; --panel: #171b20; --panel-2: #1f252b; --text: #e8edf2; --muted: #9aa7b3; --border: #2d3742; --ok: #38c172; --warning: #f4c542; --critical: #ff5c5c; --skipped: #8b949e; }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: var(--bg); color: var(--text); }
    main { max-width: 1180px; margin: 0 auto; padding: 32px 18px 48px; }
    header { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 18px; align-items: flex-start; margin-bottom: 24px; }
    h1 { margin: 0 0 8px; font-size: 32px; letter-spacing: 0; }
    h2 { margin: 28px 0 12px; font-size: 20px; letter-spacing: 0; }
    .muted { color: var(--muted); }
    .score { min-width: 132px; padding: 18px; border: 1px solid var(--border); border-radius: 8px; background: var(--panel); text-align: center; }
    .score strong { display: block; font-size: 40px; line-height: 1; }
    .cards { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; margin: 18px 0 26px; }
    .card { border: 1px solid var(--border); border-radius: 8px; background: var(--panel); padding: 14px 16px; }
    .card span { display: block; color: var(--muted); font-size: 13px; }
    .card strong { display: block; margin-top: 6px; font-size: 28px; }
    table { width: 100%; border-collapse: collapse; overflow: hidden; border-radius: 8px; background: var(--panel); border: 1px solid var(--border); }
    th, td { padding: 12px 14px; border-bottom: 1px solid var(--border); text-align: left; vertical-align: top; }
    th { color: var(--muted); font-size: 12px; text-transform: uppercase; background: var(--panel-2); }
    tr:last-child td { border-bottom: none; }
    .badge { display: inline-block; min-width: 78px; padding: 4px 8px; border-radius: 999px; font-size: 12px; font-weight: 700; text-align: center; color: #101316; }
    .ok { background: var(--ok); }
    .warning { background: var(--warning); }
    .critical { background: var(--critical); }
    .skipped { background: var(--skipped); color: #111; }
    .fixes { display: grid; gap: 10px; }
    .fix { border: 1px solid var(--border); border-radius: 8px; background: var(--panel); padding: 12px 14px; }
    @media (max-width: 760px) { .cards { grid-template-columns: repeat(2, minmax(0, 1fr)); } th:nth-child(1), td:nth-child(1) { display: none; } }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>OpsDoctor Report</h1>
        <div class="muted">$(html_escape "$HOST_HOSTNAME") · $(html_escape "$HOST_OS") · $(html_escape "$(t kernel)") $(html_escape "$HOST_KERNEL")</div>
        <div class="muted">$(html_escape "$(t generated_at)") $(html_escape "$REPORT_TIMESTAMP") · $(html_escape "$(t lang_current)") $(html_escape "$LANG_CODE")</div>
      </div>
      <div class="score"><span class="muted">$(html_escape "$(t score)")</span><strong>$SCORE</strong><span class="muted">$(html_escape "$(t out_of_100)")</span></div>
    </header>

    <section class="cards">
      <div class="card"><span>$(html_escape "$(t ok)")</span><strong>$COUNT_OK</strong></div>
      <div class="card"><span>$(html_escape "$(t warnings)")</span><strong>$COUNT_WARNING</strong></div>
      <div class="card"><span>$(html_escape "$(t criticals)")</span><strong>$COUNT_CRITICAL</strong></div>
      <div class="card"><span>$(html_escape "$(t skipped)")</span><strong>$COUNT_SKIPPED</strong></div>
    </section>

    <h2>$(html_escape "$(t checks)")</h2>
    <table>
      <thead><tr><th>$(html_escape "$(t category)")</th><th>$(html_escape "$(t status)")</th><th>$(html_escape "$(t check)")</th><th>$(html_escape "$(t message)")</th><th>$(html_escape "$(t fix)")</th></tr></thead>
      <tbody>
EOF

  for i in "${!CHECK_IDS[@]}"; do
    status="${CHECK_STATUSES[$i]}"
    safe_category="$(html_escape "${CHECK_CATEGORY_LABELS[$i]}")"
    safe_title="$(html_escape "${CHECK_TITLE_LABELS[$i]}")"
    safe_message="$(html_escape "${CHECK_MESSAGES[$i]}")"
    safe_fix="$(html_escape "${CHECK_FIXES[$i]}")"
    printf '        <tr><td>%s</td><td><span class="badge %s">%s</span></td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$safe_category" "$status" "$(html_escape "${CHECK_STATUS_LABELS[$i]}")" "$safe_title" "$safe_message" "$safe_fix"
  done

  cat <<EOF
      </tbody>
    </table>

    <h2>$(html_escape "$(t suggested_fixes)")</h2>
    <section class="fixes">
EOF

  local emitted=0
  for i in "${!CHECK_IDS[@]}"; do
    status="${CHECK_STATUSES[$i]}"
    if [ "$status" = "warning" ] || [ "$status" = "critical" ]; then
      emitted=1
      safe_title="$(html_escape "${CHECK_TITLE_LABELS[$i]}")"
      safe_fix="$(html_escape "${CHECK_FIXES[$i]}")"
      printf '      <div class="fix"><strong>%s</strong><br><span class="muted">%s</span></div>\n' "$safe_title" "$safe_fix"
    fi
  done
  if [ "$emitted" -eq 0 ]; then
    printf '      <div class="fix"><strong>%s</strong><br><span class="muted">%s</span></div>\n' "$(html_escape "$(t no_immediate_fixes)")" "$(html_escape "$(t all_checks_ok_or_skipped)")"
  fi

  cat <<'EOF'
    </section>
  </main>
</body>
</html>
EOF
}

write_html_report() {
  local file="$1"
  if [ -z "$file" ]; then
    printf 'Error: --html requires a file path.\n' >&2
    return 1
  fi
  if ! print_html_report > "$file"; then
    printf 'Error: failed to write HTML report to %s\n' "$file" >&2
    return 1
  fi
}

print_languages() {
  init_language
  local system_lang code marker
  system_lang="$(system_language)"
  printf '%s\n' "$(t lang_title)"
  printf '  %s: %s (%s)\n' "$(t lang_current)" "$LANG_CODE" "$(lang_name "$LANG_CODE")"
  printf '  %s: %s (%s)\n\n' "$(t lang_system)" "$system_lang" "$(lang_name "$system_lang")"
  for code in $SUPPORTED_LANGUAGES; do
    if language_is_installed "$code"; then
      marker="$(t lang_installed)"
    else
      marker="$(t lang_not_installed)"
    fi
    printf '  %-3s  %-22s  %s\n' "$code" "$(lang_name "$code")" "$marker"
  done
}

run_check_command() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        OUTPUT_MODE="json"
        ;;
      --html)
        shift
        if [ "$#" -eq 0 ]; then
          printf 'Error: --html requires a file path.\n' >&2
          return 1
        fi
        HTML_OUTPUT_FILE="$1"
        ;;
      --no-color)
        USE_COLOR=0
        ;;
      --lang)
        shift
        if [ "$#" -eq 0 ]; then
          printf 'Error: --lang requires a language code.\n' >&2
          return 1
        fi
        LANG_REQUESTED="$1"
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        printf 'Error: unknown option: %s\n\n' "$1" >&2
        usage >&2
        return 1
        ;;
    esac
    shift
  done

  init_language
  run_all_checks

  if [ -n "$HTML_OUTPUT_FILE" ]; then
    write_html_report "$HTML_OUTPUT_FILE" || return 1
  fi

  if [ "$OUTPUT_MODE" = "json" ]; then
    print_json_report
  else
    print_terminal_report
    if [ -n "$HTML_OUTPUT_FILE" ]; then
      printf '\n%s %s\n' "$(t html_written)" "$HTML_OUTPUT_FILE"
    fi
  fi
}

main() {
  local command_name="${1:-check}"
  if [ "$#" -gt 0 ]; then
    case "$command_name" in
      --json|--html|--no-color|--lang)
        command_name="check"
        ;;
      *)
        shift
        ;;
    esac
  fi

  case "$command_name" in
    check)
      run_check_command "$@"
      ;;
    version)
      init_language
      printf '%s %s\n' "$OPSDOCTOR_NAME" "$OPSDOCTOR_VERSION"
      ;;
    languages)
      print_languages
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      printf 'Error: unknown command: %s\n\n' "$command_name" >&2
      usage >&2
      return 1
      ;;
  esac
}

main "$@"
