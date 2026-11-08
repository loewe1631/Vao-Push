package main

import (
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

func (a *App) namedRoutes(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	rows, e := rowsJSON(r.Context(), a.db, "SELECT id,name,secret,devices,revision::text FROM named_message_routes WHERE user_id=$1 ORDER BY name,id", p.User)
	if e != nil {
		return e
	}
	result := []map[string]any{}
	for _, row := range rows {
		sealed, ok := row["secret"].([]byte)
		if !ok {
			return bad("route_read", "列表配置无效。")
		}
		var devices []string
		if e = json.Unmarshal(canonical(row["devices"]), &devices); e != nil {
			return e
		}
		rev, e := strconv.ParseInt(row["revision"].(string), 10, 64)
		if e != nil {
			return e
		}
		data, e := a.routeData(sealed, devices, rev)
		if e != nil {
			return e
		}
		data["id"] = row["id"]
		data["name"] = row["name"]
		result = append(result, data)
	}
	ok(w, map[string]any{"routes": result})
	return nil
}
func (a *App) saveNamedRoute(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		Name    string   `json:"name"`
		Devices []string `json:"device_ids"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	b.Name = strings.TrimSpace(b.Name)
	if b.Name == "" || len(b.Name) > 120 || b.Devices == nil || len(b.Devices) > 250 {
		return bad("invalid_route", "列表名称或设备选择无效。")
	}
	sort.Strings(b.Devices)
	devices := []string{}
	for _, d := range b.Devices {
		if len(devices) == 0 || devices[len(devices)-1] != d {
			devices = append(devices, d)
		}
	}
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if e = txLock(ctx, tx, p.User+":message-route"); e != nil {
		return e
	}
	rid := r.PathValue("id")
	var rev int64 = 1
	var sealed []byte
	if rid == "" {
		var n int
		if e = tx.QueryRow(ctx, "SELECT count(*) FROM named_message_routes WHERE user_id=$1", p.User).Scan(&n); e != nil {
			return e
		}
		if n >= 32 {
			return bad("route_limit", "最多32个命名列表。")
		}
		rid = id("route_")
		key := token()
		sealed, e = a.seal(canonical(map[string]any{"send_key": key}))
		if e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, "INSERT INTO credentials(hash,user_id,kind,name,expires_at)VALUES($1,$2,'channel',$3,$4)", hash(key), p.User, b.Name, time.Now().Add(3650*24*time.Hour)); e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, "INSERT INTO named_message_routes(id,user_id,name,key_hash,secret,devices)VALUES($1,$2,$3,$4,$5,$6)", rid, p.User, b.Name, hash(key), sealed, canonical(devices)); e != nil {
			return e
		}
	} else {
		e = tx.QueryRow(ctx, "SELECT revision,secret FROM named_message_routes WHERE id=$1 AND user_id=$2 FOR UPDATE", rid, p.User).Scan(&rev, &sealed)
		if e == pgx.ErrNoRows {
			return notfound()
		}
		if e != nil {
			return e
		}
		if r.Header.Get("If-Match") != routeETag(rev) {
			return APIError{412, "route_conflict", "列表已变化，请重新读取。"}
		}
		rev++
		if _, e = tx.Exec(ctx, "UPDATE named_message_routes SET name=$3,devices=$4,revision=$5 WHERE id=$1 AND user_id=$2", rid, p.User, b.Name, canonical(devices), rev); e != nil {
			return e
		}
	}
	for _, d := range devices {
		var enabled bool
		e = tx.QueryRow(ctx, "SELECT d.enabled FROM devices d LEFT JOIN device_keys k ON k.device_id=d.id WHERE d.id=$1 AND NOT d.revoked AND(d.user_id=$2 OR k.owner_id=$2) FOR SHARE OF d", d, p.User).Scan(&enabled)
		if e == pgx.ErrNoRows {
			return notfound()
		}
		if e != nil {
			return e
		}
		if !enabled {
			return bad("device_disabled", "设备已停用。")
		}
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	data, e := a.routeData(sealed, devices, rev)
	if e != nil {
		return e
	}
	data["id"] = rid
	data["name"] = b.Name
	w.Header().Set("ETag", routeETag(rev))
	ok(w, data)
	return nil
}
func (a *App) deleteNamedRoute(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if e = txLock(ctx, tx, p.User+":message-route"); e != nil {
		return e
	}
	var rev int64
	var key string
	e = tx.QueryRow(ctx, "SELECT revision,key_hash FROM named_message_routes WHERE id=$1 AND user_id=$2 FOR UPDATE", r.PathValue("id"), p.User).Scan(&rev, &key)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	if r.Header.Get("If-Match") != routeETag(rev) {
		return APIError{412, "route_conflict", "请重新检查列表后确认删除。"}
	}
	if _, e = tx.Exec(ctx, "UPDATE credentials SET revoked=true WHERE hash=$1", key); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "DELETE FROM named_message_routes WHERE id=$1 AND user_id=$2", r.PathValue("id"), p.User); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
