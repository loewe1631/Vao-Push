package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
	"net/http"
	"regexp"
	"strings"
	"time"
)

type identity struct {
	User, Device, Kind       string
	Scopes, Targets, DataIDs []string
	Session                  string
}

func contains(s []string, k string) bool {
	for _, v := range s {
		if v == k {
			return true
		}
	}
	return false
}
func (a *App) authenticate(r *http.Request, kinds ...string) (identity, error) {
	var p identity
	if h := r.Header.Get("Authorization"); h != "" {
		if !strings.HasPrefix(h, "Bearer ") || len(h) > 256 {
			return p, unauthorized()
		}
		var scopes, targets, dataIDs []byte
		e := a.db.QueryRow(r.Context(), `SELECT c.user_id,coalesce(c.device_id,''),c.kind,c.scopes,c.targets,c.data_ids FROM credentials c LEFT JOIN devices d ON c.device_id=d.id WHERE c.hash=$1 AND NOT c.revoked AND c.expires_at>now() AND (c.device_id IS NULL OR NOT d.revoked)`, hash(strings.TrimPrefix(h, "Bearer "))).Scan(&p.User, &p.Device, &p.Kind, &scopes, &targets, &dataIDs)
		if e != nil {
			return p, unauthorized()
		}
		_ = json.Unmarshal(scopes, &p.Scopes)
		_ = json.Unmarshal(targets, &p.Targets)
		_ = json.Unmarshal(dataIDs, &p.DataIDs)
	} else {
		cookie, e := r.Cookie("vao_session")
		if e != nil {
			return p, unauthorized()
		}
		var csrf string
		e = a.db.QueryRow(r.Context(), `SELECT user_id,csrf FROM sessions WHERE hash=$1 AND expires_at>now()`, hash(cookie.Value)).Scan(&p.User, &csrf)
		if e != nil {
			return p, unauthorized()
		}
		p.Kind = "web"
		p.Session = hash(cookie.Value)
		if r.Method != "GET" && r.Method != "HEAD" {
			if a.webOrigin() == "" || r.Header.Get("Origin") != a.webOrigin() {
				return p, APIError{403, "origin", "请从本服务控制台操作。"}
			}
			if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-CSRF-Token")), []byte(csrf)) != 1 {
				return p, APIError{403, "csrf", "页面已失效，请重新登录。"}
			}
		}
	}
	if !contains(kinds, p.Kind) {
		return p, APIError{403, "forbidden", "此凭证没有此项权限。"}
	}
	return p, nil
}
func (a *App) activeDevice(ctx context.Context, p identity) error {
	var enabled bool
	e := a.db.QueryRow(ctx, "SELECT enabled FROM devices WHERE id=$1 AND user_id=$2 AND NOT revoked", p.Device, p.User).Scan(&enabled)
	if e != nil {
		return unauthorized()
	}
	if !enabled {
		return APIError{403, "device_disabled", "此设备接收已暂停。"}
	}
	return nil
}
func (a *App) login(w http.ResponseWriter, r *http.Request) error {
	if a.webOrigin() != "" && r.Header.Get("Origin") != a.webOrigin() {
		return APIError{403, "origin", "请从本服务控制台登录。"}
	}
	host := clientIP(r)
	if !a.limiter.allow("login:"+host, time.Now()) {
		return APIError{429, "rate_limited", "登录尝试过多。"}
	}
	var b struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if e := decode(r, &b); e != nil {
		return e
	}
	if len(b.Password) > 128 || len(b.Username) > 80 {
		return unauthorized()
	}
	var uid string
	var password []byte
	e := a.db.QueryRow(r.Context(), "SELECT id,password FROM users WHERE username=$1", b.Username).Scan(&uid, &password)
	if e != nil {
		password = []byte("$2a$12$GYGoGl7loPae1zlrRwpR/OYNu9A2wkxKTIC5g9GVeQhzVknPf9aGa")
	}
	if bcrypt.CompareHashAndPassword(password, []byte(b.Password)) != nil || e != nil {
		return unauthorized()
	}
	session, csrf := token(), token()
	_, e = a.db.Exec(r.Context(), "INSERT INTO sessions(hash,user_id,csrf,expires_at) VALUES($1,$2,$3,$4)", hash(session), uid, csrf, time.Now().Add(12*time.Hour))
	if e != nil {
		return e
	}
	http.SetCookie(w, &http.Cookie{Name: "vao_session", Value: session, Path: "/", HttpOnly: true, Secure: a.secureWebCookie(), SameSite: http.SameSiteStrictMode, MaxAge: 43200})
	ok(w, map[string]any{"account_id": uid, "username": b.Username, "csrf_token": csrf})
	return nil
}
func (a *App) me(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var name, csrf string
	e = a.db.QueryRow(r.Context(), "SELECT u.username,s.csrf FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.hash=$1", p.Session).Scan(&name, &csrf)
	if e != nil {
		return e
	}
	ok(w, map[string]any{"account_id": p.User, "username": name, "csrf_token": csrf})
	return nil
}
func (a *App) logout(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	_, e = a.db.Exec(r.Context(), "DELETE FROM sessions WHERE hash=$1", p.Session)
	if e != nil {
		return e
	}
	http.SetCookie(w, &http.Cookie{Name: "vao_session", Value: "", Path: "/", HttpOnly: true, Secure: a.secureWebCookie(), SameSite: http.SameSiteStrictMode, MaxAge: -1})
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) changePassword(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		Current  string `json:"current_password"`
		Password string `json:"password"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if len(b.Password) < 12 || len(b.Password) > 72 {
		return bad("password_length", "新密码需为12至72字节。")
	}
	var old []byte
	if e = a.db.QueryRow(r.Context(), "SELECT password FROM users WHERE id=$1", p.User).Scan(&old); e != nil {
		return e
	}
	if bcrypt.CompareHashAndPassword(old, []byte(b.Current)) != nil {
		return unauthorized()
	}
	next, e := bcrypt.GenerateFromPassword([]byte(b.Password), 12)
	if e != nil {
		return e
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		return e
	}
	defer tx.Rollback(r.Context())
	if _, e = tx.Exec(r.Context(), "UPDATE users SET password=$1 WHERE id=$2", next, p.User); e != nil {
		return e
	}
	if _, e = tx.Exec(r.Context(), "DELETE FROM sessions WHERE user_id=$1 AND hash<>$2", p.User, p.Session); e != nil {
		return e
	}
	if e = tx.Commit(r.Context()); e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) createPair(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	code := strings.ToUpper(id("")[:12])
	until := time.Now().Add(10 * time.Minute)
	_, e = a.db.Exec(r.Context(), "INSERT INTO pairings(hash,user_id,expires_at) VALUES($1,$2,$3)", hash(code), p.User, until)
	if e != nil {
		return e
	}
	ok(w, map[string]any{"code": code, "expires_at": stamp(until), "server_url": a.cfg.PublicURL})
	return nil
}
func (a *App) claimPair(w http.ResponseWriter, r *http.Request) error {
	var b struct {
		Code     string `json:"code"`
		Name     string `json:"device_name"`
		Platform string `json:"platform"`
	}
	if e := decode(r, &b); e != nil {
		return e
	}
	b.Code = strings.ToUpper(strings.ReplaceAll(b.Code, " ", ""))
	if len(b.Code) != 12 || len(strings.TrimSpace(b.Name)) == 0 || len(b.Name) > 120 || b.Platform != "ios" {
		return bad("pairing_invalid", "配对信息无效。")
	}
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	var user string
	e = tx.QueryRow(ctx, "DELETE FROM pairings WHERE hash=$1 AND expires_at>now() RETURNING user_id", hash(b.Code)).Scan(&user)
	if e != nil {
		return bad("pairing_expired", "配对码不存在、已使用或已过期。")
	}
	var count int
	if e = tx.QueryRow(ctx, "SELECT count(*) FROM devices WHERE user_id=$1 AND NOT revoked", user).Scan(&count); e != nil {
		return e
	}
	if count >= 50 {
		return bad("device_limit", "设备数量已达上限。")
	}
	device, dt, rt := id("dev_"), token(), token()
	until := time.Now().Add(365 * 24 * time.Hour)
	if _, e = tx.Exec(ctx, "INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,$3,$4)", device, user, b.Name, b.Platform); e != nil {
		return e
	}
	for kind, t := range map[string]string{"device": dt, "read": rt} {
		if _, e = tx.Exec(ctx, "INSERT INTO credentials(hash,user_id,device_id,kind,expires_at) VALUES($1,$2,$3,$4,$5)", hash(t), user, device, kind, until); e != nil {
			return e
		}
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]any{"server_id": a.cfg.ID, "account_id": user, "binding_id": device, "device_token": dt, "read_token": rt, "expires_at": stamp(until)})
	return nil
}
func (a *App) createSender(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		Name    string   `json:"name"`
		Scopes  []string `json:"scopes"`
		Targets []string `json:"targets"`
		DataIDs []string `json:"data_ids"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if len(b.Name) < 1 || len(b.Name) > 80 || len(b.Scopes) == 0 || len(b.Scopes) > 2 || len(b.Targets) > 50 || len(b.DataIDs) > 32 {
		return bad("invalid_credential", "请填写名称与授权范围。")
	}
	for _, scope := range b.Scopes {
		if scope != "messages:write" && scope != "states:write" {
			return bad("invalid_scope", "未知权限。")
		}
	}
	if contains(b.Scopes, "messages:write") && len(b.Targets) == 0 {
		return bad("target_required", "请至少授权一个设备或分组。")
	}
	if contains(b.Scopes, "states:write") && len(b.DataIDs) == 0 {
		return bad("data_required", "请至少授权一个数据流。")
	}
	for _, target := range b.Targets {
		var exists bool
		e = a.db.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM devices WHERE id=$1 AND user_id=$2 AND NOT revoked UNION ALL SELECT 1 FROM groups WHERE id=$1 AND user_id=$2)", target, p.User).Scan(&exists)
		if e != nil {
			return e
		}
		if !exists {
			return notfound()
		}
	}
	for _, data := range b.DataIDs {
		var exists bool
		e = a.db.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM streams WHERE data_id=$1 AND user_id=$2)", data, p.User).Scan(&exists)
		if e != nil {
			return e
		}
		if !exists {
			return notfound()
		}
	}
	t := token()
	until := time.Now().Add(365 * 24 * time.Hour)
	_, e = a.db.Exec(r.Context(), "INSERT INTO credentials(hash,user_id,kind,name,scopes,targets,data_ids,expires_at) VALUES($1,$2,'sender',$3,$4,$5,$6,$7)", hash(t), p.User, b.Name, canonical(b.Scopes), canonical(b.Targets), canonical(b.DataIDs), until)
	if e != nil {
		return e
	}
	ok(w, map[string]any{"id": hash(t), "token": t, "expires_at": stamp(until)})
	return nil
}
func (a *App) revokeSender(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	tag, e := a.db.Exec(r.Context(), "UPDATE credentials SET revoked=true WHERE hash=$1 AND user_id=$2 AND kind='sender'", r.PathValue("id"), p.User)
	if e != nil {
		return e
	}
	if tag.RowsAffected() == 0 {
		return notfound()
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) createGroup(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		Name    string   `json:"name"`
		Devices []string `json:"devices"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if len(b.Name) < 1 || len(b.Name) > 80 || len(b.Devices) == 0 || len(b.Devices) > 50 {
		return bad("invalid_group", "请填写名称并选择1至50台设备。")
	}
	seen := map[string]bool{}
	list := []string{}
	for _, d := range b.Devices {
		if seen[d] {
			continue
		}
		seen[d] = true
		var exists bool
		if e = a.db.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM devices WHERE id=$1 AND user_id=$2 AND NOT revoked)", d, p.User).Scan(&exists); e != nil {
			return e
		}
		if !exists {
			return notfound()
		}
		list = append(list, d)
	}
	g := id("group_")
	_, e = a.db.Exec(r.Context(), "INSERT INTO groups(id,user_id,name,devices) VALUES($1,$2,$3,$4)", g, p.User, b.Name, canonical(list))
	if e != nil {
		return e
	}
	ok(w, map[string]string{"group_id": g})
	return nil
}

var dataKey = regexp.MustCompile(`^[a-z0-9_-]{1,64}$`)

func (a *App) createStream(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		DataID   string `json:"data_id"`
		Name     string `json:"name"`
		Ordering string `json:"ordering"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if b.Ordering == "" {
		b.Ordering = "server_order"
	}
	if !dataKey.MatchString(b.DataID) || len(b.Name) < 1 || len(b.Name) > 100 || (b.Ordering != "server_order" && b.Ordering != "source_sequence") {
		return bad("invalid_stream", "数据ID、名称或排序模式无效。")
	}
	var n int
	if e = a.db.QueryRow(r.Context(), "SELECT count(*) FROM streams WHERE user_id=$1", p.User).Scan(&n); e != nil {
		return e
	}
	if n >= 32 {
		return bad("stream_limit", "当前版本每个账号最多32个数据流。")
	}
	sid := id("stream_")
	tag, e := a.db.Exec(r.Context(), "INSERT INTO streams(id,user_id,data_id,name,ordering) VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING", sid, p.User, b.DataID, b.Name, b.Ordering)
	if e != nil {
		return e
	}
	if tag.RowsAffected() == 0 {
		return conflict("data_id_exists", "此数据ID已存在。")
	}
	ok(w, map[string]string{"stream_id": sid, "data_id": b.DataID})
	return nil
}
func (a *App) dashboard(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	out := map[string]any{"server_name": a.cfg.Name, "server_id": a.cfg.ID, "server_url": a.cfg.PublicURL}
	queries := map[string]string{
		"devices":     "SELECT id,name,platform,enabled,revoked,environment,(apns_token IS NOT NULL) AS has_apns_token,(widget_token IS NOT NULL) AS has_widget_token,subscriptions,created_at,updated_at FROM devices WHERE user_id=$1 OR id IN (SELECT device_id FROM device_keys WHERE owner_id=$1) ORDER BY created_at DESC LIMIT 250",
		"groups":      "SELECT id,name,devices FROM groups WHERE user_id=$1 ORDER BY name",
		"streams":     "SELECT s.id,s.data_id,s.name,s.ordering,s.revision::text,s.received_at,(s.state IS NOT NULL) AS has_state,d.id AS device_id,d.name AS device_name FROM streams s JOIN devices d ON d.user_id=s.user_id WHERE NOT d.revoked AND (d.user_id=$1 OR d.id IN (SELECT device_id FROM device_keys WHERE owner_id=$1)) ORDER BY d.name,s.data_id LIMIT 6400",
		"credentials": "SELECT hash AS id,name,scopes,targets,data_ids,revoked,expires_at FROM credentials WHERE user_id=$1 AND kind='sender' ORDER BY created_at DESC LIMIT 100",
		"messages":    "SELECT id AS message_id,title,body,received_at FROM messages WHERE user_id=$1 OR user_id IN (SELECT d.user_id FROM device_keys k JOIN devices d ON d.id=k.device_id WHERE k.owner_id=$1) ORDER BY seq DESC LIMIT 50",
		"deliveries":  "SELECT o.id,o.kind,o.resource_id,d.name AS device_name,o.status,o.attempts,o.error,o.apns_id,o.created_at,o.updated_at FROM outbox o JOIN devices d ON d.id=o.device_id WHERE o.user_id=$1 OR o.device_id IN (SELECT device_id FROM device_keys WHERE owner_id=$1) ORDER BY o.created_at DESC LIMIT 100",
	}
	for key, q := range queries {
		v, e := rowsJSON(r.Context(), a.db, q, p.User)
		if e != nil {
			return e
		}
		out[key] = v
	}
	ok(w, out)
	return nil
}
func txLock(ctx context.Context, tx pgx.Tx, key string) error {
	_, e := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", key)
	return e
}
