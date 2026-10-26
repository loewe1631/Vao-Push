package main

import (
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

func routeETag(revision int64) string { return `"route-` + strconv.FormatInt(revision, 10) + `"` }

func (a *App) routeData(sealed []byte, devices []string, revision int64) (map[string]any, error) {
	if devices == nil {
		devices = []string{}
	}
	out := map[string]any{"configured": revision > 0, "device_ids": devices, "revision": strconv.FormatInt(revision, 10)}
	if revision > 0 {
		raw, e := a.unseal(sealed)
		if e != nil {
			return nil, e
		}
		var secret struct {
			Key string `json:"send_key"`
		}
		if e = json.Unmarshal(raw, &secret); e != nil {
			return nil, e
		}
		out["message_url"] = a.cfg.PublicURL + "/v1/push/" + secret.Key
	}
	return out, nil
}

func (a *App) messageRoute(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var sealed, raw []byte
	var revision int64
	e = a.db.QueryRow(r.Context(), "SELECT secret,devices,revision FROM message_routes WHERE user_id=$1", p.User).Scan(&sealed, &raw, &revision)
	if e != nil && e != pgx.ErrNoRows {
		return e
	}
	devices := []string{}
	if raw != nil {
		if e = json.Unmarshal(raw, &devices); e != nil {
			return e
		}
	}
	data, e := a.routeData(sealed, devices, revision)
	if e != nil {
		return e
	}
	w.Header().Set("ETag", routeETag(revision))
	ok(w, data)
	return nil
}

func (a *App) saveMessageRoute(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		Devices []string `json:"device_ids"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if b.Devices == nil || len(b.Devices) > 250 {
		return bad("invalid_targets", "请选择至多250台设备；空列表表示暂停自动分发。")
	}
	sort.Strings(b.Devices)
	devices := make([]string, 0, len(b.Devices))
	for _, d := range b.Devices {
		if d == "" {
			return bad("invalid_targets", "设备标识不能为空。")
		}
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
	var sealed, previous []byte
	var revision int64
	e = tx.QueryRow(ctx, "SELECT secret,devices,revision FROM message_routes WHERE user_id=$1 FOR UPDATE", p.User).Scan(&sealed, &previous, &revision)
	if e != nil && e != pgx.ErrNoRows {
		return e
	}
	if r.Header.Get("If-Match") != routeETag(revision) {
		return APIError{412, "route_conflict", "自动接收列表已被修改，请重新读取后保存。"}
	}
	for _, d := range devices {
		var enabled bool
		e = tx.QueryRow(ctx, `SELECT d.enabled FROM devices d LEFT JOIN device_keys k ON k.device_id=d.id WHERE d.id=$1 AND NOT d.revoked AND (d.user_id=$2 OR k.owner_id=$2) FOR SHARE OF d`, d, p.User).Scan(&enabled)
		if e == pgx.ErrNoRows {
			return notfound()
		}
		if e != nil {
			return e
		}
		if !enabled {
			return bad("device_disabled", "选中的设备已暂停接收，请检查后保存。")
		}
	}
	if revision == 0 {
		key := token()
		sealed, e = a.seal(canonical(map[string]any{"send_key": key}))
		if e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, "INSERT INTO credentials(hash,user_id,kind,name,expires_at) VALUES($1,$2,'channel','Default message route',$3)", hash(key), p.User, time.Now().Add(3650*24*time.Hour)); e != nil {
			return e
		}
		revision = 1
		if _, e = tx.Exec(ctx, "INSERT INTO message_routes(user_id,key_hash,secret,devices,revision) VALUES($1,$2,$3,$4,$5)", p.User, hash(key), sealed, canonical(devices), revision); e != nil {
			return e
		}
	} else {
		var existing []string
		if e = json.Unmarshal(previous, &existing); e != nil {
			return e
		}
		if string(canonical(existing)) != string(canonical(devices)) {
			revision++
			if _, e = tx.Exec(ctx, "UPDATE message_routes SET devices=$2,revision=$3 WHERE user_id=$1", p.User, canonical(devices), revision); e != nil {
				return e
			}
		}
	}
	data, e := a.routeData(sealed, devices, revision)
	if e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	w.Header().Set("ETag", routeETag(revision))
	ok(w, data)
	return nil
}
