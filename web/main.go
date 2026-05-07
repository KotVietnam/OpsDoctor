package main

import (
	_ "embed"
	"encoding/json"
	"errors"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

const (
	defaultPort       = "7357"
	defaultDataFile   = "/var/lib/opsdoctor/latest.json"
	defaultConfigFile = "/etc/opsdoctor/opsdoctor.conf"
)

//go:embed static/style.css
var styleCSS string

type Report struct {
	Tool      string    `json:"tool"`
	Version   string    `json:"version"`
	Language  string    `json:"language"`
	Timestamp string    `json:"timestamp"`
	Host      Host      `json:"host"`
	Score     int       `json:"score"`
	Summary   Summary   `json:"summary"`
	Checks    []Check   `json:"checks"`
}

type Host struct {
	Hostname string `json:"hostname"`
	OS       string `json:"os"`
	Kernel   string `json:"kernel"`
}

type Summary struct {
	OK       int `json:"ok"`
	Warning  int `json:"warning"`
	Critical int `json:"critical"`
	Skipped  int `json:"skipped"`
}

type Check struct {
	ID            string `json:"id"`
	Category      string `json:"category"`
	CategoryLabel string `json:"category_label"`
	Title         string `json:"title"`
	TitleLabel    string `json:"title_label"`
	Status        string `json:"status"`
	StatusLabel   string `json:"status_label"`
	Message       string `json:"message"`
	Fix           string `json:"fix"`
}

type DashboardData struct {
	Report      Report
	DataFile    string
	GeneratedAt string
	Categories  []string
	Fixes       []Check
	Language    string
	UI          map[string]string
}

type ErrorData struct {
	Language string
	UI       map[string]string
	Message  string
}

var dashboardTemplate = template.Must(template.New("dashboard").Funcs(template.FuncMap{
	"upper": strings.ToUpper,
	"labelCategory": func(check Check) string {
		if check.CategoryLabel != "" {
			return check.CategoryLabel
		}
		return check.Category
	},
	"labelTitle": func(check Check) string {
		if check.TitleLabel != "" {
			return check.TitleLabel
		}
		return check.Title
	},
	"labelStatus": func(check Check) string {
		if check.StatusLabel != "" {
			return check.StatusLabel
		}
		return strings.ToUpper(check.Status)
	},
}).Parse(`<!doctype html>
<html lang="{{.Language}}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="30">
  <title>{{index .UI "dashboard"}}</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <main class="shell">
    <header class="topbar">
      <div>
        <p class="eyebrow">{{index .UI "dashboard"}}</p>
        <h1>{{.Report.Host.Hostname}}</h1>
        <p class="muted">{{.Report.Host.OS}} · {{index .UI "kernel"}} {{.Report.Host.Kernel}}</p>
      </div>
      <div class="score score-{{if ge .Report.Score 90}}ok{{else if ge .Report.Score 70}}warning{{else}}critical{{end}}">
        <span>{{index .UI "score"}}</span>
        <strong>{{.Report.Score}}</strong>
        <small>/100</small>
      </div>
    </header>

    <section class="meta-grid">
      <div class="meta"><span>{{index .UI "report_timestamp"}}</span><strong>{{.Report.Timestamp}}</strong></div>
      <div class="meta"><span>{{index .UI "data_source"}}</span><strong>{{.DataFile}}</strong></div>
      <div class="meta"><span>{{index .UI "auto_refresh"}}</span><strong>30 {{index .UI "seconds"}}</strong></div>
    </section>

    <section class="summary-grid" aria-label="{{index .UI "summary"}}">
      <button class="summary-card ok" data-filter="ok"><span>{{index .UI "ok"}}</span><strong>{{.Report.Summary.OK}}</strong></button>
      <button class="summary-card warning" data-filter="warning"><span>{{index .UI "warnings"}}</span><strong>{{.Report.Summary.Warning}}</strong></button>
      <button class="summary-card critical" data-filter="critical"><span>{{index .UI "critical"}}</span><strong>{{.Report.Summary.Critical}}</strong></button>
      <button class="summary-card skipped" data-filter="skipped"><span>{{index .UI "skipped"}}</span><strong>{{.Report.Summary.Skipped}}</strong></button>
    </section>

    <section class="toolbar">
      <button class="filter active" data-filter="all">{{index .UI "all"}}</button>
      <button class="filter" data-filter="ok">{{index .UI "ok"}}</button>
      <button class="filter" data-filter="warning">{{index .UI "warnings"}}</button>
      <button class="filter" data-filter="critical">{{index .UI "critical"}}</button>
      <button class="filter" data-filter="skipped">{{index .UI "skipped"}}</button>
    </section>

    <section class="panel">
      <div class="panel-title">
        <h2>{{index .UI "checks"}}</h2>
        <span>{{len .Report.Checks}} {{index .UI "total"}}</span>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{{index .UI "category"}}</th>
              <th>{{index .UI "status"}}</th>
              <th>{{index .UI "check"}}</th>
              <th>{{index .UI "message"}}</th>
              <th>{{index .UI "suggested_fix"}}</th>
            </tr>
          </thead>
          <tbody>
          {{range .Report.Checks}}
            <tr data-status="{{.Status}}">
              <td>{{labelCategory .}}</td>
              <td><span class="badge {{.Status}}">{{labelStatus .}}</span></td>
              <td><strong>{{labelTitle .}}</strong><small>{{.ID}}</small></td>
              <td>{{.Message}}</td>
              <td>{{.Fix}}</td>
            </tr>
          {{end}}
          </tbody>
        </table>
      </div>
    </section>

    <section class="panel">
      <div class="panel-title">
        <h2>{{index .UI "suggested_fixes"}}</h2>
        <span>{{len .Fixes}} {{index .UI "open"}}</span>
      </div>
      {{if .Fixes}}
      <div class="fix-list">
        {{range .Fixes}}
        <article class="fix-item">
          <span class="badge {{.Status}}">{{labelStatus .}}</span>
          <div>
            <strong>{{labelTitle .}}</strong>
            <p>{{.Fix}}</p>
          </div>
        </article>
        {{end}}
      </div>
      {{else}}
      <p class="empty">{{index .UI "no_fixes"}}</p>
      {{end}}
    </section>
  </main>

  <script>
    const buttons = document.querySelectorAll('[data-filter]');
    const rows = document.querySelectorAll('tbody tr[data-status]');
    function applyFilter(filter) {
      rows.forEach(row => {
        row.hidden = filter !== 'all' && row.dataset.status !== filter;
      });
      document.querySelectorAll('.filter').forEach(button => {
        button.classList.toggle('active', button.dataset.filter === filter);
      });
    }
    buttons.forEach(button => {
      button.addEventListener('click', () => applyFilter(button.dataset.filter));
    });
  </script>
</body>
</html>`))

var errorTemplate = template.Must(template.New("error").Parse(`<!doctype html>
<html lang="{{.Language}}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{index .UI "dashboard"}}</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <main class="shell">
    <section class="error-panel">
      <p class="eyebrow">{{index .UI "dashboard"}}</p>
      <h1>{{index .UI "no_data_title"}}</h1>
      <p>{{.Message}}</p>
      <p class="muted">{{index .UI "no_data_hint"}}</p>
    </section>
  </main>
</body>
</html>`))

func main() {
	dataFile := getenv("OPSDOCTOR_DATA_FILE", defaultDataFile)
	port := getenv("OPSDOCTOR_WEB_PORT", defaultPort)
	configFile := getenv("OPSDOCTOR_CONFIG_FILE", defaultConfigFile)
	addr := net.JoinHostPort("0.0.0.0", port)

	mux := http.NewServeMux()
	mux.HandleFunc("/", dashboardHandler(dataFile, configFile))
	mux.HandleFunc("/api/status", apiStatusHandler(dataFile))
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/static/style.css", styleHandler)

	server := &http.Server{
		Addr:              addr,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("OpsDoctor web dashboard listening on http://%s", addr)
	log.Fatal(server.ListenAndServe())
}

func getenv(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func configLanguage(path string) string {
	content, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(content), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(key) != "OPSDOCTOR_LANG" {
			continue
		}
		return strings.Trim(strings.TrimSpace(value), `"'`)
	}
	return ""
}

func normalizeLanguage(raw string) string {
	raw = strings.TrimSpace(strings.ToLower(raw))
	if raw == "" {
		return ""
	}
	if i := strings.IndexAny(raw, ".@"); i >= 0 {
		raw = raw[:i]
	}
	raw = strings.ReplaceAll(raw, "-", "_")
	if i := strings.Index(raw, "_"); i >= 0 {
		raw = raw[:i]
	}
	switch raw {
	case "cn":
		return "zh"
	case "in":
		return "id"
	default:
		return raw
	}
}

func isSupportedLanguage(lang string) bool {
	switch lang {
	case "en", "ru", "es", "zh", "hi", "ar", "pt", "fr", "de", "ja", "ko", "it", "tr", "pl", "uk", "id", "vi", "fa", "bn", "ur", "nl", "cs", "sv", "ro":
		return true
	default:
		return false
	}
}

func systemLanguage() string {
	for _, key := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		lang := normalizeLanguage(os.Getenv(key))
		if isSupportedLanguage(lang) {
			return lang
		}
	}
	return "en"
}

func resolveLanguage(candidates ...string) string {
	for _, candidate := range candidates {
		lang := normalizeLanguage(candidate)
		if lang == "" || lang == "auto" {
			continue
		}
		if isSupportedLanguage(lang) {
			return lang
		}
	}
	return systemLanguage()
}

func uiLabels(lang string) map[string]string {
	labels := map[string]string{
		"dashboard":        "OpsDoctor Dashboard",
		"kernel":           "Kernel",
		"score":            "Score",
		"report_timestamp": "Report timestamp",
		"data_source":      "Data source",
		"auto_refresh":     "Auto-refresh",
		"seconds":          "seconds",
		"summary":          "Summary",
		"ok":               "OK",
		"warnings":         "Warnings",
		"critical":         "Critical",
		"skipped":          "Skipped",
		"all":              "All",
		"checks":           "Checks",
		"total":            "total",
		"category":         "Category",
		"status":           "Status",
		"check":            "Check",
		"message":          "Message",
		"suggested_fix":    "Suggested fix",
		"suggested_fixes":  "Suggested fixes",
		"open":             "open",
		"no_fixes":         "No warning or critical fixes in the latest report.",
		"no_data_title":    "No monitoring data yet",
		"no_data_hint":     "Run opsdoctor-agent run or enable the opsdoctor-agent.timer systemd timer.",
	}

	if lang == "ru" {
		return map[string]string{
			"dashboard":        "Панель OpsDoctor",
			"kernel":           "Ядро",
			"score":            "Оценка",
			"report_timestamp": "Время отчёта",
			"data_source":      "Источник данных",
			"auto_refresh":     "Автообновление",
			"seconds":          "секунд",
			"summary":          "Итог",
			"ok":               "OK",
			"warnings":         "Предупреждения",
			"critical":         "Критично",
			"skipped":          "Пропущено",
			"all":              "Все",
			"checks":           "Проверки",
			"total":            "всего",
			"category":         "Раздел",
			"status":           "Статус",
			"check":            "Проверка",
			"message":          "Сообщение",
			"suggested_fix":    "Рекомендация",
			"suggested_fixes":  "Рекомендации",
			"open":             "открыто",
			"no_fixes":         "В последнем отчёте нет warning или critical рекомендаций.",
			"no_data_title":    "Данных мониторинга пока нет",
			"no_data_hint":     "Запустите opsdoctor-agent run или включите systemd timer opsdoctor-agent.timer.",
		}
	}

	switch lang {
	case "es":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Puntuación", "Resumen", "Comprobaciones", "Advertencias", "Crítico", "Omitido", "Todo", "Correcciones sugeridas"
	case "zh":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "评分", "摘要", "检查", "警告", "严重", "已跳过", "全部", "建议修复"
	case "hi":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "स्कोर", "सारांश", "जांच", "चेतावनी", "गंभीर", "छोड़ा गया", "सभी", "सुझाए गए सुधार"
	case "ar":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "النتيجة", "الملخص", "الفحوصات", "تحذيرات", "حرج", "تم التخطي", "الكل", "الإصلاحات المقترحة"
	case "pt":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Pontuação", "Resumo", "Verificações", "Avisos", "Crítico", "Ignorado", "Todos", "Correções sugeridas"
	case "fr":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Score", "Résumé", "Contrôles", "Avertissements", "Critique", "Ignoré", "Tous", "Correctifs suggérés"
	case "de":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Bewertung", "Zusammenfassung", "Prüfungen", "Warnungen", "Kritisch", "Übersprungen", "Alle", "Empfohlene Korrekturen"
	case "ja":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "スコア", "概要", "チェック", "警告", "重大", "スキップ", "すべて", "推奨修正"
	case "ko":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "점수", "요약", "검사", "경고", "치명적", "건너뜀", "전체", "권장 수정"
	case "it":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Punteggio", "Riepilogo", "Controlli", "Avvisi", "Critico", "Saltato", "Tutti", "Correzioni suggerite"
	case "tr":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Puan", "Özet", "Kontroller", "Uyarılar", "Kritik", "Atlandı", "Tümü", "Önerilen düzeltmeler"
	case "pl":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Wynik", "Podsumowanie", "Sprawdzenia", "Ostrzeżenia", "Krytyczne", "Pominięte", "Wszystkie", "Sugerowane poprawki"
	case "uk":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Оцінка", "Підсумок", "Перевірки", "Попередження", "Критично", "Пропущено", "Усі", "Рекомендації"
	case "id":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Skor", "Ringkasan", "Pemeriksaan", "Peringatan", "Kritis", "Dilewati", "Semua", "Perbaikan yang disarankan"
	case "vi":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Điểm", "Tóm tắt", "Kiểm tra", "Cảnh báo", "Nghiêm trọng", "Bỏ qua", "Tất cả", "Cách khắc phục đề xuất"
	case "fa":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "امتیاز", "خلاصه", "بررسی‌ها", "هشدارها", "بحرانی", "رد شد", "همه", "راهکارهای پیشنهادی"
	case "bn":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "স্কোর", "সারাংশ", "পরীক্ষা", "সতর্কতা", "গুরুতর", "এড়ানো হয়েছে", "সব", "প্রস্তাবিত সমাধান"
	case "ur":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "اسکور", "خلاصہ", "جانچیں", "انتباہات", "سنگین", "چھوڑا گیا", "سب", "تجویز کردہ اصلاحات"
	case "nl":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Score", "Samenvatting", "Controles", "Waarschuwingen", "Kritiek", "Overgeslagen", "Alle", "Voorgestelde oplossingen"
	case "cs":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Skóre", "Souhrn", "Kontroly", "Varování", "Kritické", "Přeskočeno", "Vše", "Doporučené opravy"
	case "sv":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Poäng", "Sammanfattning", "Kontroller", "Varningar", "Kritiskt", "Hoppad", "Alla", "Föreslagna åtgärder"
	case "ro":
		labels["score"], labels["summary"], labels["checks"], labels["warnings"], labels["critical"], labels["skipped"], labels["all"], labels["suggested_fixes"] = "Scor", "Rezumat", "Verificări", "Avertismente", "Critic", "Omis", "Toate", "Remedieri sugerate"
	}

	return labels
}

func dashboardHandler(dataFile, configFile string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		report, err := readReport(dataFile)
		lang := resolveLanguage(getenv("OPSDOCTOR_WEB_LANG", ""), configLanguage(configFile), report.Language)
		ui := uiLabels(lang)
		if err != nil {
			w.WriteHeader(http.StatusNotFound)
			_ = errorTemplate.Execute(w, ErrorData{
				Language: lang,
				UI:       ui,
				Message:  err.Error(),
			})
			return
		}

		data := DashboardData{
			Report:      report,
			DataFile:    dataFile,
			GeneratedAt: time.Now().Format(time.RFC3339),
			Categories:  categories(report.Checks),
			Fixes:       suggestedFixes(report.Checks),
			Language:    lang,
			UI:          ui,
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := dashboardTemplate.Execute(w, data); err != nil {
			http.Error(w, "template rendering failed", http.StatusInternalServerError)
			return
		}
	}
}

func apiStatusHandler(dataFile string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		content, err := os.ReadFile(dataFile)
		if err != nil {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.WriteHeader(http.StatusNotFound)
			_ = json.NewEncoder(w).Encode(map[string]string{
				"error": "OpsDoctor report is not available",
				"file":  dataFile,
			})
			return
		}

		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write(content)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("ok\n"))
}

func styleHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/css; charset=utf-8")
	_, _ = w.Write([]byte(styleCSS))
}

func readReport(path string) (Report, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Report{}, errors.New("latest.json does not exist at " + path)
		}
		return Report{}, err
	}

	var report Report
	if err := json.Unmarshal(content, &report); err != nil {
		return Report{}, err
	}
	return report, nil
}

func categories(checks []Check) []string {
	seen := map[string]struct{}{}
	for _, check := range checks {
		category := check.Category
		if check.CategoryLabel != "" {
			category = check.CategoryLabel
		}
		if category == "" {
			continue
		}
		seen[category] = struct{}{}
	}
	result := make([]string, 0, len(seen))
	for category := range seen {
		result = append(result, category)
	}
	sort.Strings(result)
	return result
}

func suggestedFixes(checks []Check) []Check {
	result := make([]Check, 0)
	for _, check := range checks {
		if (check.Status == "warning" || check.Status == "critical") && strings.TrimSpace(check.Fix) != "" {
			result = append(result, check)
		}
	}
	return result
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
	})
}
