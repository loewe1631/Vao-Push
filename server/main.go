package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed schema.sql
var schema string

type Config struct {
	Listen           string `json:"listen"`
	WebListen        string `json:"web_listen,omitempty"`
	WebURL           string `json:"web_url,omitempty"`
	APNsIdentityFile string `json:"apns_identity_file,omitempty"`
	DatabaseURL      string `json:"database_url"`
	Name             string `json:"server_name"`
	ID               string `json:"server_id"`
	MasterKey        string `json:"master_key"`
	Username         string `json:"bootstrap_username"`
	Password         string `json:"bootstrap_password"`
	PublicURL        string `json:"public_url"`
	WebDir           string `json:"web_dir"`
}
type App struct {
	db      *pgxpool.Pool
	cfg     Config
	mux     *http.ServeMux
	limiter *rateLimiter
	push    pushSender
}
type APIError struct {
	Status        int
	Code, Message string
}

func (e APIError) Error() string     { return e.Code }
func bad(code, message string) error { return APIError{422, code, message} }
func unauthorized() error {
	return APIError{401, "unauthorized", "登录或设备凭证已失效，请重新连接。"}
}
func notfound() error                     { return APIError{404, "not_found", "资源不存在或无权访问。"} }
func conflict(code, message string) error { return APIError{409, code, message} }
func id(prefix string) string {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return prefix + hex.EncodeToString(b)
}
func token() string        { return id("") + id("") }
func hash(s string) string { b := sha256.Sum256([]byte(s)); return hex.EncodeToString(b[:]) }
func canonical(v any) []byte {
	b, e := json.Marshal(v)
	if e != nil {
		panic(e)
	}
	return b
}
func stamp(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }
func write(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func ok(w http.ResponseWriter, v any) { write(w, 200, map[string]any{"data": v}) }
func failure(w http.ResponseWriter, e error) {
	var a APIError
	if !errors.As(e, &a) {
		a = APIError{500, "internal_error", "服务暂时不可用，请稍后重试。"}
		log.Print("request database or internal failure")
	}
	write(w, a.Status, map[string]any{"request_id": id("req_"), "error": map[string]string{"code": a.Code, "message": a.Message}})
}
func decode(r *http.Request, v any) error {
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		return APIError{415, "content_type", "请求须为 JSON。"}
	}
	d := json.NewDecoder(io.LimitReader(r.Body, 72*1024+1))
	d.DisallowUnknownFields()
	d.UseNumber()
	if e := d.Decode(v); e != nil {
		return bad("invalid_json", "JSON 字段或格式无效。")
	}
	var rest any
	if d.Decode(&rest) != io.EOF {
		return bad("invalid_json", "请求必须是单个 JSON 对象。")
	}
	return nil
}

type endpoint func(http.ResponseWriter, *http.Request) error

func (a *App) route(pattern string, f endpoint) {
	a.mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
		if e := f(w, r); e != nil {
			failure(w, e)
		}
	})
}
func (a *App) routes() {
	a.mux = http.NewServeMux()
	a.route("GET /v1/info", a.info)
	a.route("GET /healthz", a.health)
	a.route("POST /v1/auth/login", a.login)
	a.route("POST /v1/auth/logout", a.logout)
	a.route("PUT /v1/auth/password", a.changePassword)
	a.route("GET /v1/auth/me", a.me)
	a.route("GET /v1/dashboard", a.dashboard)
	a.route("POST /v1/register", a.registerDevice)
	a.route("GET /v1/device/access", a.deviceAccess)
	a.route("GET /v1/devices/{id}/access", a.deviceAccess)
	a.route("POST /v1/push/{key}", a.keyedMessage)
	a.route("PUT /v1/state/{key}/{data_id}", a.keyedState)
	a.route("POST /v1/pairings", a.createPair)
	a.route("POST /v1/pairings/claim", a.claimPair)
	a.route("POST /v1/credentials", a.createSender)
	a.route("DELETE /v1/credentials/{id}", a.revokeSender)
	a.route("POST /v1/groups", a.createGroup)
	a.route("POST /v1/streams", a.createStream)
	a.route("POST /v1/messages", a.message)
	a.route("GET /v1/card-sources/{id}", a.sourceSettings)
	a.route("GET /v1/card-sources/{id}/deletion", a.sourceDeletion)
	a.route("DELETE /v1/card-sources/{id}", a.sourceDeletion)
	a.route("PUT /v1/card-sources/{id}", a.updateSource)
	a.route("GET /v1/card-sources", a.cardSources)
	a.route("POST /v1/card-sources", a.createCardSource)
	a.route("GET /v1/card-sources/{id}/access", a.sourceAccess)
	a.route("PUT /v1/card-sources/{id}/data", a.sourceState)
	a.route("PUT /v1/card-sources/{id}/enabled", a.setSourceEnabled)
	a.route("POST /v1/card-sources/{id}/poll", a.pollCardSource)
	a.route("PUT /v1/card-data/{key}", a.cardData)
	a.route("POST /v1/cards/validate", a.validateCardCode)
	a.route("GET /v1/cards", a.cards)
	a.route("POST /v1/cards", a.saveCard)
	a.route("PUT /v1/cards/{id}", a.saveCard)
	a.route("GET /v1/cards/{id}/deletion", a.cardDeletion)
	a.route("DELETE /v1/cards/{id}", a.cardDeletion)
	a.route("POST /v1/cards/{id}/publish", a.publishCard)
	a.route("POST /v1/cards/{id}/codes", a.cardCode)
	a.route("DELETE /v1/cards/{id}/codes", a.revokeCardCodes)
	a.route("GET /v1/cards/{id}/subscribers", a.cardSubscribers)
	a.route("DELETE /v1/cards/{id}/subscribers/{device}", a.revokeCardSubscription)
	a.route("POST /v1/cards/redeem", a.redeemCard)
	a.route("GET /v1/card-subscriptions", a.cardSubscriptions)
	a.route("GET /v1/card-subscriptions/{id}", a.subscribedCard)
	a.route("DELETE /v1/card-subscriptions/{id}", a.unsubscribeCard)

	a.route("GET /v1/message-route", a.messageRoute)
	a.route("PUT /v1/message-route", a.saveMessageRoute)
	a.route("PUT /v1/widgets/{data_id}/state", a.state)
	a.route("GET /v1/widgets/{data_id}/state", a.snapshot)
	a.route("GET /v1/device/sync", a.syncDevice)
	a.route("PUT /v1/device/registration", a.registration)
	a.route("PUT /v1/device/subscriptions", a.subscriptions)
	a.route("PUT /v1/device/status", a.deviceStatus)
	a.route("PUT /v1/device/name", a.renameDevice)
	a.route("DELETE /v1/device", a.revokeDevice)
	a.route("DELETE /v1/devices/{id}", a.adminRevokeDevice)
	a.route("GET /v1/apns", a.apnsInfo)
	a.route("PUT /v1/apns", a.apnsSave)
	a.mux.Handle("/", http.FileServer(http.Dir(a.cfg.WebDir)))
}
func (a *App) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
	if strings.HasPrefix(r.URL.Path, "/v1/") {
		if strings.Contains(r.URL.RawPath, "%2f") || strings.Contains(r.URL.RawPath, "%2F") {
			failure(w, bad("invalid_path", "路径无效。"))
			return
		}
		if r.ContentLength > 72*1024 {
			failure(w, APIError{413, "payload_too_large", "请求过大。"})
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 72*1024)
		key := clientIP(r)
		if !a.limiter.allow(key, time.Now()) {
			failure(w, APIError{429, "rate_limited", "请求过于频繁，请稍后重试。"})
			return
		}
	}
	a.mux.ServeHTTP(w, r)
}
func (a *App) info(w http.ResponseWriter, r *http.Request) error {
	ok(w, map[string]any{"protocol_version": 1, "server_id": a.cfg.ID, "name": a.cfg.Name, "registration": "automatic"})
	return nil
}
func (a *App) health(w http.ResponseWriter, r *http.Request) error {
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	if e := a.db.Ping(ctx); e != nil {
		return e
	}
	ok(w, map[string]string{"status": "ok"})
	return nil
}
func main() {
	path := os.Getenv("VAO_CONFIG")
	if path == "" {
		log.Fatal("VAO_CONFIG must name a private config file")
	}
	b, e := os.ReadFile(path)
	if e != nil {
		log.Fatal("cannot read config")
	}
	var cfg Config
	if json.Unmarshal(b, &cfg) != nil || cfg.validate() != nil {
		log.Fatal("invalid config")
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	db, e := pgxpool.New(ctx, cfg.DatabaseURL)
	if e != nil {
		log.Fatal("database configuration failed")
	}
	defer db.Close()
	if _, e = db.Exec(ctx, schema); e != nil {
		log.Fatal("database migration failed: ", e)
	}
	var n int
	_ = db.QueryRow(ctx, "SELECT count(*) FROM users").Scan(&n)
	if n == 0 {
		if len(cfg.Password) < 20 {
			log.Fatal("bootstrap password must be generated")
		}
		p, _ := bcrypt.GenerateFromPassword([]byte(cfg.Password), 12)
		if _, e = db.Exec(ctx, "INSERT INTO users(id,username,password) VALUES($1,$2,$3)", id("acct_"), cfg.Username, p); e != nil {
			log.Fatal("bootstrap failed")
		}
	}
	a := &App{db: db, cfg: cfg, limiter: newLimiter()}
	a.push = &APNsSender{app: a, client: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	if e = a.isolateCardSources(ctx); e != nil {
		log.Fatal("card source migration failed")
	}
	if e = a.importInstalledAPNsIdentity(ctx); e != nil {
		log.Fatal("installed APNs identity is invalid or unavailable")
	}
	a.routes()
	go a.worker(ctx)
	go a.sourceWorker(ctx)
	if e = a.serveConfiguredHTTP(ctx); e != nil {
		log.Fatal(e)
	}
}

type rateBucket struct {
	at time.Time
	n  int
}
type rateLimiter struct {
	mu      sync.Mutex
	entries map[string]rateBucket
}

func newLimiter() *rateLimiter { return &rateLimiter{entries: map[string]rateBucket{}} }
func (l *rateLimiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if _, exists := l.entries[key]; !exists && len(l.entries) >= 10000 {
		for k, v := range l.entries {
			if now.Sub(v.at) > time.Minute {
				delete(l.entries, k)
			}
		}
		if len(l.entries) >= 10000 {
			return false
		}
	}
	b := l.entries[key]
	if now.Sub(b.at) > time.Minute {
		b = rateBucket{at: now}
	}
	b.n++
	l.entries[key] = b
	if len(l.entries) > 10000 {
		for k, v := range l.entries {
			if now.Sub(v.at) > time.Minute {
				delete(l.entries, k)
			}
		}
	}
	limit := 300
	if strings.HasPrefix(key, "login:") {
		limit = 10
	}
	return b.n <= limit
}
func clientIP(r *http.Request) string {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if host == "127.0.0.1" || host == "::1" {
		if ip := net.ParseIP(r.Header.Get("CF-Connecting-IP")); ip != nil {
			return ip.String()
		}
	}
	return host
}

func validHTTPS(s string) bool {
	u, e := url.Parse(s)
	return e == nil && u.Scheme == "https" && u.Host != "" && u.User == nil
}
func rowsJSON(ctx context.Context, tx interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}, sql string, args ...any) ([]map[string]any, error) {
	rows, e := tx.Query(ctx, sql, args...)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		v, e := rows.Values()
		if e != nil {
			return nil, e
		}
		m := map[string]any{}
		for i, f := range rows.FieldDescriptions() {
			m[f.Name] = v[i]
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
