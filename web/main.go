package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
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

type Inventory struct {
	CollectedAt    string               `json:"collected_at"`
	Docker         DockerInventory      `json:"docker"`
	Screen         SessionInventory     `json:"screen"`
	Tmux           SessionInventory     `json:"tmux"`
	ListeningPorts ListeningPortInventory `json:"listening_ports"`
	FailedUnits    FailedUnitInventory  `json:"failed_units"`
}

type DockerInventory struct {
	Status  string            `json:"status"`
	Message string            `json:"message"`
	Items   []DockerContainer `json:"items"`
}

type DockerContainer struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Image  string `json:"image"`
	Status string `json:"status"`
	State  string `json:"state"`
	Ports  string `json:"ports"`
}

type SessionInventory struct {
	Status  string            `json:"status"`
	Message string            `json:"message"`
	Items   []TerminalSession `json:"items"`
}

type TerminalSession struct {
	Name     string `json:"name"`
	User     string `json:"user,omitempty"`
	Windows  string `json:"windows,omitempty"`
	Created  string `json:"created"`
	Attached string `json:"attached"`
	State    string `json:"state"`
	Source   string `json:"source"`
}

type ListeningPortInventory struct {
	Status  string          `json:"status"`
	Message string          `json:"message"`
	Items   []ListeningPort `json:"items"`
}

type ListeningPort struct {
	Protocol     string `json:"protocol"`
	State        string `json:"state"`
	LocalAddress string `json:"local_address"`
	Process      string `json:"process"`
}

type FailedUnitInventory struct {
	Status  string       `json:"status"`
	Message string       `json:"message"`
	Items   []FailedUnit `json:"items"`
}

type FailedUnit struct {
	Unit        string `json:"unit"`
	Load        string `json:"load"`
	Active      string `json:"active"`
	Sub         string `json:"sub"`
	Description string `json:"description"`
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

    <section class="tabs" aria-label="{{index .UI "dashboard_tabs"}}">
      <button class="tab active" data-tab="overview">{{index .UI "overview"}}</button>
      <button class="tab" data-tab="inventory">{{index .UI "live_inventory"}}</button>
    </section>

    <section class="tab-panel active" data-tab-panel="overview">
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
    </section>

    <section class="tab-panel" data-tab-panel="inventory" hidden>
      <section class="panel">
        <div class="panel-title">
          <div>
            <h2>{{index .UI "live_inventory"}}</h2>
            <span id="inventory-meta">{{index .UI "loading_inventory"}}</span>
          </div>
          <button class="filter" id="refresh-inventory" type="button">{{index .UI "refresh_inventory"}}</button>
        </div>
        <div class="inventory-grid">
          <section class="inventory-card">
            <div class="inventory-card-title"><h3>{{index .UI "docker_containers"}}</h3><span id="docker-status" class="section-status"></span></div>
            <div id="docker-inventory" class="inventory-content"></div>
          </section>
          <section class="inventory-card">
            <div class="inventory-card-title"><h3>{{index .UI "screen_sessions"}}</h3><span id="screen-status" class="section-status"></span></div>
            <div id="screen-inventory" class="inventory-content"></div>
          </section>
          <section class="inventory-card">
            <div class="inventory-card-title"><h3>{{index .UI "tmux_sessions"}}</h3><span id="tmux-status" class="section-status"></span></div>
            <div id="tmux-inventory" class="inventory-content"></div>
          </section>
          <section class="inventory-card">
            <div class="inventory-card-title"><h3>{{index .UI "listening_ports"}}</h3><span id="ports-status" class="section-status"></span></div>
            <div id="ports-inventory" class="inventory-content"></div>
          </section>
          <section class="inventory-card inventory-card-wide">
            <div class="inventory-card-title"><h3>{{index .UI "failed_units"}}</h3><span id="units-status" class="section-status"></span></div>
            <div id="units-inventory" class="inventory-content"></div>
          </section>
        </div>
      </section>
    </section>
  </main>

  <script>
    const ui = {
      loadingInventory: {{index .UI "loading_inventory"}},
      inventoryError: {{index .UI "inventory_error"}},
      noItems: {{index .UI "no_items"}},
      collectedAt: {{index .UI "collected_at"}},
      id: {{index .UI "id"}},
      name: {{index .UI "name"}},
      user: {{index .UI "user"}},
      image: {{index .UI "image"}},
      state: {{index .UI "state"}},
      status: {{index .UI "status"}},
      ports: {{index .UI "ports"}},
      session: {{index .UI "session"}},
      windows: {{index .UI "windows"}},
      created: {{index .UI "created"}},
      attached: {{index .UI "attached"}},
      protocol: {{index .UI "protocol"}},
      localAddress: {{index .UI "local_address"}},
      process: {{index .UI "process"}},
      unit: {{index .UI "unit"}},
      load: {{index .UI "load"}},
      active: {{index .UI "active"}},
      sub: {{index .UI "sub"}},
      description: {{index .UI "description"}}
    };

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

    const tabs = document.querySelectorAll('[data-tab]');
    const panels = document.querySelectorAll('[data-tab-panel]');
    let inventoryLoaded = false;
    function showTab(tabName) {
      tabs.forEach(tab => tab.classList.toggle('active', tab.dataset.tab === tabName));
      panels.forEach(panel => {
        const active = panel.dataset.tabPanel === tabName;
        panel.hidden = !active;
        panel.classList.toggle('active', active);
      });
      if (tabName === 'inventory' && !inventoryLoaded) {
        loadInventory();
      }
    }
    tabs.forEach(tab => {
      tab.addEventListener('click', () => showTab(tab.dataset.tab));
    });

    const refreshInventory = document.getElementById('refresh-inventory');
    if (refreshInventory) {
      refreshInventory.addEventListener('click', () => loadInventory());
    }

    function setSectionStatus(id, section) {
      const target = document.getElementById(id);
      if (!target) return;
      target.textContent = section.status + (section.message ? ' · ' + section.message : '');
      target.className = 'section-status ' + section.status;
    }

    function renderTable(targetId, items, columns) {
      const target = document.getElementById(targetId);
      if (!target) return;
      target.textContent = '';
      if (!items || items.length === 0) {
        const empty = document.createElement('p');
        empty.className = 'empty compact';
        empty.textContent = ui.noItems;
        target.appendChild(empty);
        return;
      }
      const wrapper = document.createElement('div');
      wrapper.className = 'table-wrap compact';
      const table = document.createElement('table');
      const thead = document.createElement('thead');
      const headRow = document.createElement('tr');
      columns.forEach(column => {
        const th = document.createElement('th');
        th.textContent = column.label;
        headRow.appendChild(th);
      });
      thead.appendChild(headRow);
      const tbody = document.createElement('tbody');
      items.forEach(item => {
        const row = document.createElement('tr');
        columns.forEach(column => {
          const td = document.createElement('td');
          td.textContent = item[column.key] || '';
          row.appendChild(td);
        });
        tbody.appendChild(row);
      });
      table.appendChild(thead);
      table.appendChild(tbody);
      wrapper.appendChild(table);
      target.appendChild(wrapper);
    }

    async function loadInventory() {
      const meta = document.getElementById('inventory-meta');
      if (meta) meta.textContent = ui.loadingInventory;
      try {
        const response = await fetch('/api/inventory', { cache: 'no-store' });
        if (!response.ok) throw new Error(response.status + ' ' + response.statusText);
        const inventory = await response.json();
        inventoryLoaded = true;
        if (meta) meta.textContent = ui.collectedAt + ': ' + inventory.collected_at;

        setSectionStatus('docker-status', inventory.docker);
        setSectionStatus('screen-status', inventory.screen);
        setSectionStatus('tmux-status', inventory.tmux);
        setSectionStatus('ports-status', inventory.listening_ports);
        setSectionStatus('units-status', inventory.failed_units);

        renderTable('docker-inventory', inventory.docker.items, [
          { key: 'id', label: ui.id },
          { key: 'name', label: ui.name },
          { key: 'image', label: ui.image },
          { key: 'state', label: ui.state },
          { key: 'status', label: ui.status },
          { key: 'ports', label: ui.ports }
        ]);
        renderTable('screen-inventory', inventory.screen.items, [
          { key: 'name', label: ui.session },
          { key: 'user', label: ui.user },
          { key: 'state', label: ui.state },
          { key: 'created', label: ui.created },
          { key: 'attached', label: ui.attached }
        ]);
        renderTable('tmux-inventory', inventory.tmux.items, [
          { key: 'name', label: ui.session },
          { key: 'windows', label: ui.windows },
          { key: 'created', label: ui.created },
          { key: 'attached', label: ui.attached }
        ]);
        renderTable('ports-inventory', inventory.listening_ports.items, [
          { key: 'protocol', label: ui.protocol },
          { key: 'state', label: ui.state },
          { key: 'local_address', label: ui.localAddress },
          { key: 'process', label: ui.process }
        ]);
        renderTable('units-inventory', inventory.failed_units.items, [
          { key: 'unit', label: ui.unit },
          { key: 'load', label: ui.load },
          { key: 'active', label: ui.active },
          { key: 'sub', label: ui.sub },
          { key: 'description', label: ui.description }
        ]);
      } catch (error) {
        inventoryLoaded = false;
        if (meta) meta.textContent = ui.inventoryError + ': ' + error.message;
      }
    }
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
	mux.HandleFunc("/api/inventory", inventoryHandler)
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
		"dashboard_tabs":   "Dashboard tabs",
		"overview":         "Overview",
		"live_inventory":   "Live inventory",
		"refresh_inventory": "Refresh inventory",
		"loading_inventory": "Loading live inventory",
		"inventory_error":  "Inventory load failed",
		"collected_at":     "Collected at",
		"docker_containers": "Docker containers",
		"screen_sessions":  "screen sessions",
		"tmux_sessions":    "tmux sessions",
		"listening_ports":  "Listening ports",
		"failed_units":     "Failed systemd units",
		"no_items":         "No items found.",
		"id":               "ID",
		"name":             "Name",
		"user":             "User",
		"image":            "Image",
		"state":            "State",
		"ports":            "Ports",
		"session":          "Session",
		"windows":          "Windows",
		"created":          "Created",
		"attached":         "Attached",
		"protocol":         "Protocol",
		"local_address":    "Local address",
		"process":          "Process",
		"unit":             "Unit",
		"load":             "Load",
		"active":           "Active",
		"sub":              "Sub",
		"description":      "Description",
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
			"dashboard_tabs":   "Вкладки панели",
			"overview":         "Обзор",
			"live_inventory":   "Живой инвентарь",
			"refresh_inventory": "Обновить инвентарь",
			"loading_inventory": "Загрузка живого инвентаря",
			"inventory_error":  "Ошибка загрузки инвентаря",
			"collected_at":     "Собрано",
			"docker_containers": "Docker-контейнеры",
			"screen_sessions":  "screen-сессии",
			"tmux_sessions":    "tmux-сессии",
			"listening_ports":  "Слушающие порты",
			"failed_units":     "Сбойные systemd units",
			"no_items":         "Нет элементов.",
			"id":               "ID",
			"name":             "Имя",
			"user":             "Пользователь",
			"image":            "Образ",
			"state":            "Состояние",
			"ports":            "Порты",
			"session":          "Сессия",
			"windows":          "Окна",
			"created":          "Создано",
			"attached":         "Подключено",
			"protocol":         "Протокол",
			"local_address":    "Локальный адрес",
			"process":          "Процесс",
			"unit":             "Unit",
			"load":             "Load",
			"active":           "Active",
			"sub":              "Sub",
			"description":      "Описание",
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

func inventoryHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if err := json.NewEncoder(w).Encode(collectInventory()); err != nil {
		http.Error(w, "inventory encoding failed", http.StatusInternalServerError)
	}
}

func collectInventory() Inventory {
	return Inventory{
		CollectedAt:    time.Now().Format(time.RFC3339),
		Docker:         collectDockerInventory(),
		Screen:         collectScreenInventory(),
		Tmux:           collectTmuxInventory(),
		ListeningPorts: collectListeningPorts(),
		FailedUnits:    collectFailedUnits(),
	}
}

func collectDockerInventory() DockerInventory {
	if _, err := exec.LookPath("docker"); err != nil {
		return DockerInventory{Status: "skipped", Message: "docker command is not installed"}
	}
	output, err := runInventoryCommand("docker", "ps", "-a", "--no-trunc", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.State}}\t{{.Ports}}")
	if err != nil {
		return DockerInventory{Status: "warning", Message: commandErrorMessage(err, output)}
	}

	items := make([]DockerContainer, 0)
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		for len(parts) < 6 {
			parts = append(parts, "")
		}
		items = append(items, DockerContainer{
			ID:     shortID(parts[0]),
			Name:   parts[1],
			Image:  parts[2],
			Status: parts[3],
			State:  parts[4],
			Ports:  parts[5],
		})
	}

	return DockerInventory{Status: "ok", Message: countMessage(len(items), "container"), Items: items}
}

func collectScreenInventory() SessionInventory {
	items := make([]TerminalSession, 0)
	seen := map[string]struct{}{}

	if _, err := exec.LookPath("screen"); err == nil {
		output, runErr := runInventoryCommand("screen", "-ls")
		if runErr != nil && !strings.Contains(output, "No Sockets found") {
			return SessionInventory{Status: "warning", Message: commandErrorMessage(runErr, output)}
		}
		for _, line := range strings.Split(output, "\n") {
			session, ok := parseScreenSession(line)
			if ok {
				items = append(items, session)
				seen[session.Source+"/"+session.Name] = struct{}{}
			}
		}
	}

	for _, session := range scanScreenSocketDirs() {
		key := session.Source + "/" + session.Name
		if _, ok := seen[key]; ok {
			continue
		}
		items = append(items, session)
	}

	if len(items) == 0 {
		if _, err := exec.LookPath("screen"); err != nil {
			return SessionInventory{Status: "skipped", Message: "screen command is not installed and no screen sockets were found"}
		}
	}
	return SessionInventory{Status: "ok", Message: countMessage(len(items), "screen session"), Items: items}
}

func collectTmuxInventory() SessionInventory {
	if _, err := exec.LookPath("tmux"); err != nil {
		return SessionInventory{Status: "skipped", Message: "tmux command is not installed"}
	}
	output, err := runInventoryCommand("tmux", "list-sessions", "-F", "#{session_name}\t#{session_windows}\t#{session_created_string}\t#{?session_attached,yes,no}")
	if err != nil {
		if strings.Contains(output, "no server running") {
			return SessionInventory{Status: "ok", Message: "No tmux sessions found"}
		}
		return SessionInventory{Status: "warning", Message: commandErrorMessage(err, output)}
	}

	items := make([]TerminalSession, 0)
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		for len(parts) < 4 {
			parts = append(parts, "")
		}
		items = append(items, TerminalSession{
			Name:     parts[0],
			Windows:  parts[1],
			Created:  parts[2],
			Attached: parts[3],
			State:    attachmentState(parts[3]),
			Source:   "tmux",
		})
	}
	return SessionInventory{Status: "ok", Message: countMessage(len(items), "tmux session"), Items: items}
}

func collectListeningPorts() ListeningPortInventory {
	if _, err := exec.LookPath("ss"); err != nil {
		return ListeningPortInventory{Status: "skipped", Message: "ss command is not installed"}
	}
	output, err := runInventoryCommand("ss", "-tulpenH")
	if err != nil {
		return ListeningPortInventory{Status: "warning", Message: commandErrorMessage(err, output)}
	}

	items := make([]ListeningPort, 0)
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		process := ""
		if len(fields) > 6 {
			process = strings.Join(fields[6:], " ")
		}
		items = append(items, ListeningPort{
			Protocol:     fields[0],
			State:        fields[1],
			LocalAddress: fields[4],
			Process:      process,
		})
		if len(items) >= 200 {
			break
		}
	}
	return ListeningPortInventory{Status: "ok", Message: countMessage(len(items), "listening socket"), Items: items}
}

func collectFailedUnits() FailedUnitInventory {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return FailedUnitInventory{Status: "skipped", Message: "systemctl command is not installed"}
	}
	output, err := runInventoryCommand("systemctl", "--failed", "--no-legend", "--plain")
	if err != nil {
		if strings.Contains(output, "System has not been booted") || strings.Contains(output, "Failed to connect") {
			return FailedUnitInventory{Status: "skipped", Message: "systemd is not available in this environment"}
		}
		return FailedUnitInventory{Status: "warning", Message: commandErrorMessage(err, output)}
	}

	items := make([]FailedUnit, 0)
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		description := ""
		if len(fields) > 4 {
			description = strings.Join(fields[4:], " ")
		}
		items = append(items, FailedUnit{
			Unit:        fields[0],
			Load:        fields[1],
			Active:      fields[2],
			Sub:         fields[3],
			Description: description,
		})
	}
	status := "ok"
	if len(items) > 0 {
		status = "warning"
	}
	return FailedUnitInventory{Status: status, Message: countMessage(len(items), "failed unit"), Items: items}
}

func runInventoryCommand(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return string(output), errors.New("command timed out")
	}
	return string(output), err
}

func parseScreenSession(line string) (TerminalSession, bool) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "There ") || strings.HasPrefix(line, "No ") || strings.Contains(line, "Socket") {
		return TerminalSession{}, false
	}
	fields := strings.Fields(line)
	if len(fields) == 0 || !strings.Contains(fields[0], ".") {
		return TerminalSession{}, false
	}
	parts := parenthesizedParts(line)
	state := ""
	created := ""
	if len(parts) > 0 {
		created = parts[0]
		state = parts[len(parts)-1]
	}
	return TerminalSession{
		Name:     fields[0],
		Created:  created,
		Attached: attachmentState(state),
		State:    state,
		Source:   "screen",
	}, true
}

func scanScreenSocketDirs() []TerminalSession {
	result := make([]TerminalSession, 0)
	for _, root := range []string{"/run/screen", "/var/run/screen"} {
		userDirs, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		for _, userDir := range userDirs {
			if !userDir.IsDir() || !strings.HasPrefix(userDir.Name(), "S-") {
				continue
			}
			user := strings.TrimPrefix(userDir.Name(), "S-")
			sessionDir := root + "/" + userDir.Name()
			entries, err := os.ReadDir(sessionDir)
			if err != nil {
				continue
			}
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				result = append(result, TerminalSession{
					Name:     entry.Name(),
					User:     user,
					Attached: "unknown",
					State:    "socket",
					Source:   "screen",
				})
			}
		}
	}
	return result
}

func parenthesizedParts(line string) []string {
	result := make([]string, 0)
	remaining := line
	for {
		start := strings.Index(remaining, "(")
		if start < 0 {
			break
		}
		remaining = remaining[start+1:]
		end := strings.Index(remaining, ")")
		if end < 0 {
			break
		}
		result = append(result, strings.TrimSpace(remaining[:end]))
		remaining = remaining[end+1:]
	}
	return result
}

func attachmentState(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "1" || value == "yes" || strings.Contains(value, "attached") {
		return "attached"
	}
	if value == "0" || value == "no" || strings.Contains(value, "detached") {
		return "detached"
	}
	return value
}

func commandErrorMessage(err error, output string) string {
	message := strings.TrimSpace(output)
	if message == "" && err != nil {
		message = err.Error()
	}
	return truncate(firstLine(message), 180)
}

func firstLine(value string) string {
	value = strings.TrimSpace(value)
	if i := strings.IndexAny(value, "\r\n"); i >= 0 {
		return strings.TrimSpace(value[:i])
	}
	return value
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	if limit <= 3 {
		return value[:limit]
	}
	return value[:limit-3] + "..."
}

func shortID(id string) string {
	id = strings.TrimSpace(id)
	if len(id) <= 12 {
		return id
	}
	return id[:12]
}

func countMessage(count int, singular string) string {
	if count == 1 {
		return "1 " + singular
	}
	return strconv.Itoa(count) + " " + singular + "s"
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
