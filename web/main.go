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
	defaultPort     = "7357"
	defaultDataFile = "/var/lib/opsdoctor/latest.json"
)

//go:embed static/style.css
var styleCSS string

type Report struct {
	Tool      string    `json:"tool"`
	Version   string    `json:"version"`
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
	ID       string `json:"id"`
	Category string `json:"category"`
	Title    string `json:"title"`
	Status   string `json:"status"`
	Message  string `json:"message"`
	Fix      string `json:"fix"`
}

type DashboardData struct {
	Report      Report
	DataFile    string
	GeneratedAt string
	Categories  []string
	Fixes       []Check
}

var dashboardTemplate = template.Must(template.New("dashboard").Funcs(template.FuncMap{
	"upper": strings.ToUpper,
}).Parse(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="30">
  <title>OpsDoctor Dashboard</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <main class="shell">
    <header class="topbar">
      <div>
        <p class="eyebrow">OpsDoctor Dashboard</p>
        <h1>{{.Report.Host.Hostname}}</h1>
        <p class="muted">{{.Report.Host.OS}} · Kernel {{.Report.Host.Kernel}}</p>
      </div>
      <div class="score score-{{if ge .Report.Score 90}}ok{{else if ge .Report.Score 70}}warning{{else}}critical{{end}}">
        <span>Score</span>
        <strong>{{.Report.Score}}</strong>
        <small>/100</small>
      </div>
    </header>

    <section class="meta-grid">
      <div class="meta"><span>Report timestamp</span><strong>{{.Report.Timestamp}}</strong></div>
      <div class="meta"><span>Data source</span><strong>{{.DataFile}}</strong></div>
      <div class="meta"><span>Auto-refresh</span><strong>30 seconds</strong></div>
    </section>

    <section class="summary-grid" aria-label="Summary">
      <button class="summary-card ok" data-filter="ok"><span>OK</span><strong>{{.Report.Summary.OK}}</strong></button>
      <button class="summary-card warning" data-filter="warning"><span>Warnings</span><strong>{{.Report.Summary.Warning}}</strong></button>
      <button class="summary-card critical" data-filter="critical"><span>Critical</span><strong>{{.Report.Summary.Critical}}</strong></button>
      <button class="summary-card skipped" data-filter="skipped"><span>Skipped</span><strong>{{.Report.Summary.Skipped}}</strong></button>
    </section>

    <section class="toolbar">
      <button class="filter active" data-filter="all">All</button>
      <button class="filter" data-filter="ok">OK</button>
      <button class="filter" data-filter="warning">Warnings</button>
      <button class="filter" data-filter="critical">Critical</button>
      <button class="filter" data-filter="skipped">Skipped</button>
    </section>

    <section class="panel">
      <div class="panel-title">
        <h2>Checks</h2>
        <span>{{len .Report.Checks}} total</span>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Category</th>
              <th>Status</th>
              <th>Check</th>
              <th>Message</th>
              <th>Suggested fix</th>
            </tr>
          </thead>
          <tbody>
          {{range .Report.Checks}}
            <tr data-status="{{.Status}}">
              <td>{{.Category}}</td>
              <td><span class="badge {{.Status}}">{{upper .Status}}</span></td>
              <td><strong>{{.Title}}</strong><small>{{.ID}}</small></td>
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
        <h2>Suggested fixes</h2>
        <span>{{len .Fixes}} open</span>
      </div>
      {{if .Fixes}}
      <div class="fix-list">
        {{range .Fixes}}
        <article class="fix-item">
          <span class="badge {{.Status}}">{{upper .Status}}</span>
          <div>
            <strong>{{.Title}}</strong>
            <p>{{.Fix}}</p>
          </div>
        </article>
        {{end}}
      </div>
      {{else}}
      <p class="empty">No warning or critical fixes in the latest report.</p>
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
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpsDoctor Dashboard</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <main class="shell">
    <section class="error-panel">
      <p class="eyebrow">OpsDoctor Dashboard</p>
      <h1>No monitoring data yet</h1>
      <p>{{.}}</p>
      <p class="muted">Run <code>opsdoctor-agent run</code> or enable the <code>opsdoctor-agent.timer</code> systemd timer.</p>
    </section>
  </main>
</body>
</html>`))

func main() {
	dataFile := getenv("OPSDOCTOR_DATA_FILE", defaultDataFile)
	port := getenv("OPSDOCTOR_WEB_PORT", defaultPort)
	addr := net.JoinHostPort("0.0.0.0", port)

	mux := http.NewServeMux()
	mux.HandleFunc("/", dashboardHandler(dataFile))
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

func dashboardHandler(dataFile string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}

		report, err := readReport(dataFile)
		if err != nil {
			w.WriteHeader(http.StatusNotFound)
			_ = errorTemplate.Execute(w, err.Error())
			return
		}

		data := DashboardData{
			Report:      report,
			DataFile:    dataFile,
			GeneratedAt: time.Now().Format(time.RFC3339),
			Categories:  categories(report.Checks),
			Fixes:       suggestedFixes(report.Checks),
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
		if check.Category == "" {
			continue
		}
		seen[check.Category] = struct{}{}
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
