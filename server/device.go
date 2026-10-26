package main

import (
	"encoding/hex"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

type MessageRequest struct {
	Version int `json:"schema_version"`
	Target  struct {
		Device  string   `json:"device_id,omitempty"`
		Group   string   `json:"group_id,omitempty"`
		All     bool     `json:"all_devices,omitempty"`
		Devices []string `json:"device_ids,omitempty"`
	} `json:"target"`
	Title        string `json:"title"`
	Body         string `json:"body"`
	Notification struct {
		Level string `json:"level"`
		Sound string `json:"sound"`
	} `json:"notification"`
	URL string `json:"url,omitempty"`
	TTL int    `json:"ttl_seconds,omitempty"`
}

func (a *App) message(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web", "sender", "delivery", "channel")
	if e != nil {
		return e
	}
	if p.Kind == "sender" && !contains(p.Scopes, "messages:write") {
		return APIError{403, "forbidden", "凭证无消息发送权限。"}
	}
	var b MessageRequest
	if e = decode(r, &b); e != nil {
		return e
	}
	if (b.Target.All || b.Target.Devices != nil) && p.Kind != "web" {
		return APIError{403, "forbidden", "设备多选及全部设备仅供服务器管理员手动发送。"}
	}
	if b.Target.Devices != nil {
		if len(b.Target.Devices) == 0 || len(b.Target.Devices) > 250 {
			return bad("invalid_targets", "请选择1至250台接收设备。")
		}
		// A selection is a set: normalize before hashing and lock rows in stable order.
		sort.Strings(b.Target.Devices)
		unique := make([]string, 0, len(b.Target.Devices))
		for _, device := range b.Target.Devices {
			if device == "" {
				return bad("invalid_targets", "接收设备标识不能为空。")
			}
			if len(unique) == 0 || unique[len(unique)-1] != device {
				unique = append(unique, device)
			}
		}
		b.Target.Devices = unique
	}
	if p.Kind == "channel" {
		if b.Target.Device != "" || b.Target.Group != "" || b.Target.All || b.Target.Devices != nil {
			return bad("fixed_route", "统一消息地址使用Web保存的接收列表，无需指定目标。")
		}
		if b.Version == 0 {
			b.Version = 1
		}
	}
	if p.Kind == "delivery" {
		if b.Target.Device != "" && b.Target.Device != p.Device || b.Target.Group != "" {
			return notfound()
		}
		b.Target.Device = p.Device
		if b.Version == 0 {
			b.Version = 1
		}
	}
	if p.Kind == "web" && b.Target.Device != "" {
		p, e = a.webDevice(r, p, b.Target.Device)
		if e != nil {
			return e
		}
	}
	if b.TTL == 0 {
		b.TTL = 3600
	}
	if b.Notification.Level == "" {
		b.Notification.Level = "active"
	}
	if b.Notification.Sound == "" {
		b.Notification.Sound = "default"
	}
	targetCount := 0
	for _, selected := range []bool{b.Target.Device != "", b.Target.Group != "", b.Target.All, b.Target.Devices != nil} {
		if selected {
			targetCount++
		}
	}
	if b.Version != 1 || strings.TrimSpace(b.Body) == "" || len(b.Body) > 2500 || len(b.Title) > 200 || b.TTL < 1 || b.TTL > 86400 || (targetCount != 1 && !(p.Kind == "channel" && targetCount == 0)) || !contains([]string{"active", "passive"}, b.Notification.Level) || !contains([]string{"default", "none"}, b.Notification.Sound) || (b.URL != "" && (!validHTTPS(b.URL) || len(b.URL) > 1024)) {
		return bad("invalid_message", "请检查消息、目标、通知选项与有效期。")
	}
	target := b.Target.Device
	if target == "" {
		target = b.Target.Group
	}
	if p.Kind == "sender" && !contains(p.Targets, target) {
		return notfound()
	}
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	h := hash(string(canonical(b)))
	key := r.Header.Get("Idempotency-Key")
	st, replay, e := idemBegin(ctx, tx, p, "message", key, h)
	if e != nil {
		return e
	}
	if replay != nil {
		write(w, st, json.RawMessage(replay))
		return nil
	}
	list := []string{}
	owners := map[string]string{}
	if b.Target.All || p.Kind == "channel" {
		var routeDevices []string
		if p.Kind == "channel" {
			var raw []byte
			err := tx.QueryRow(ctx, "SELECT devices FROM message_routes WHERE user_id=$1 AND key_hash=$2 FOR SHARE", p.User, hash(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))).Scan(&raw)
			if err == pgx.ErrNoRows {
				return unauthorized()
			}
			if err != nil {
				return err
			}
			if err = json.Unmarshal(raw, &routeDevices); err != nil {
				return err
			}
			if routeDevices == nil {
				routeDevices = []string{}
			}
		}
		rows, err := tx.Query(ctx, `SELECT d.id,d.user_id FROM devices d LEFT JOIN device_keys k ON k.device_id=d.id WHERE (d.user_id=$1 OR k.owner_id=$1) AND d.enabled AND NOT d.revoked AND ($2::text[] IS NULL OR d.id=ANY($2::text[])) ORDER BY d.id FOR SHARE OF d`, p.User, routeDevices)
		if err != nil {
			return err
		}
		for rows.Next() {
			var device, owner string
			if err = rows.Scan(&device, &owner); err != nil {
				rows.Close()
				return err
			}
			list = append(list, device)
			owners[device] = owner
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return err
		}
	} else if b.Target.Devices != nil {
		list = b.Target.Devices
		for _, device := range list {
			var owner string
			err := tx.QueryRow(ctx, `SELECT d.user_id FROM devices d LEFT JOIN device_keys k ON k.device_id=d.id WHERE d.id=$1 AND NOT d.revoked AND (d.user_id=$2 OR k.owner_id=$2) FOR SHARE OF d`, device, p.User).Scan(&owner)
			if err == pgx.ErrNoRows {
				return notfound()
			}
			if err != nil {
				return err
			}
			owners[device] = owner
		}
	} else if b.Target.Device != "" {
		list = append(list, b.Target.Device)
	} else {
		var raw []byte
		e = tx.QueryRow(ctx, "SELECT devices FROM groups WHERE id=$1 AND user_id=$2", b.Target.Group, p.User).Scan(&raw)
		if e == pgx.ErrNoRows {
			return notfound()
		}
		if e != nil {
			return e
		}
		_ = json.Unmarshal(raw, &list)
	}
	targets := []string{}
	seen := map[string]bool{}
	for _, d := range list {
		if seen[d] {
			continue
		}
		seen[d] = true
		var enabled bool
		owner := p.User
		if b.Target.All || b.Target.Devices != nil || p.Kind == "channel" {
			owner = owners[d]
		}
		e = tx.QueryRow(ctx, "SELECT enabled FROM devices WHERE id=$1 AND user_id=$2 AND NOT revoked FOR SHARE", d, owner).Scan(&enabled)
		if e == pgx.ErrNoRows {
			if b.Target.Device != "" {
				return notfound()
			}
			continue
		}
		if e != nil {
			return e
		}
		if enabled {
			targets = append(targets, d)
			owners[d] = owner
		} else if b.Target.Devices != nil {
			return bad("device_disabled", "选中的设备已暂停接收，请检查设备选择后再发送。")
		}
	}
	if len(targets) == 0 {
		return bad("no_targets", "没有启用接收的有效设备。")
	}
	// Lock every receiving namespace before allocating the sequence, so a concurrent
	// single-device send cannot commit out of cursor order. Freeze targets for retries.
	lockOwners := map[string]bool{p.User: true}
	for _, d := range targets {
		lockOwners[owners[d]] = true
	}
	orderedOwners := make([]string, 0, len(lockOwners))
	for owner := range lockOwners {
		orderedOwners = append(orderedOwners, owner)
	}
	sort.Strings(orderedOwners)
	for _, owner := range orderedOwners {
		if e = txLock(ctx, tx, owner+":message-order"); e != nil {
			return e
		}
	}
	message, now := id("msg_"), time.Now().UTC()
	_, e = tx.Exec(ctx, "INSERT INTO messages(id,user_id,title,body,received_at,notification,url) VALUES($1,$2,$3,$4,$5,$6,$7)", message, p.User, b.Title, b.Body, now, canonical(b.Notification), b.URL)
	if e != nil {
		return e
	}
	for _, d := range targets {
		aps := map[string]any{"alert": map[string]string{"title": b.Title, "body": b.Body}, "mutable-content": 1, "interruption-level": b.Notification.Level}
		if b.Notification.Sound == "default" {
			aps["sound"] = "default"
		}
		push := map[string]any{"version": 1, "kind": "message", "server_id": a.cfg.ID, "account_id": owners[d], "binding_id": d, "message_id": message, "received_at": stamp(now)}
		if b.URL != "" {
			push["url"] = b.URL
		}
		payload := canonical(map[string]any{"aps": aps, "vao_push": push})
		if len(payload) > 4096 {
			return bad("notification_too_large", "消息超出苹果推送载荷，请缩短文本或链接。")
		}
		if _, e = tx.Exec(ctx, "INSERT INTO message_targets(message_id,device_id) VALUES($1,$2)", message, d); e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, "INSERT INTO outbox(id,user_id,device_id,kind,resource_id,payload,expires_at) VALUES($1,$2,$3,'message',$4,$5,$6)", id("job_"), owners[d], d, message, payload, now.Add(time.Duration(b.TTL)*time.Second)); e != nil {
			return e
		}
	}
	response := map[string]any{"data": map[string]any{"message_id": message, "status": "queued", "target_count": len(targets), "received_at": stamp(now)}}
	if e = idemSave(ctx, tx, p, "message", key, h, 202, response); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	write(w, 202, response)
	return nil
}
func (a *App) syncDevice(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device")
	if e != nil {
		return e
	}
	if e = a.activeDevice(r.Context(), p); e != nil {
		return e
	}
	cursor := int64(0)
	if c := r.URL.Query().Get("cursor"); c != "" {
		cursor, e = strconv.ParseInt(c, 10, 64)
		if e != nil || cursor < 0 {
			return bad("invalid_cursor", "同步游标无效。")
		}
	}
	ctx := r.Context()
	tx, e := a.db.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	var deviceName string
	if e = tx.QueryRow(ctx, "SELECT name FROM devices WHERE id=$1 AND user_id=$2 AND NOT revoked", p.Device, p.User).Scan(&deviceName); e != nil {
		return unauthorized()
	}
	snaps, e := rowsJSON(ctx, tx, "SELECT id AS stream_id,data_id,revision::text,received_at,state FROM streams WHERE user_id=$1 AND state IS NOT NULL ORDER BY data_id LIMIT 32", p.User)
	if e != nil {
		return e
	}
	messages, e := rowsJSON(ctx, tx, "SELECT m.seq,m.id AS message_id,m.title,m.body,m.received_at FROM messages m JOIN message_targets t ON m.id=t.message_id WHERE t.device_id=$1 AND m.seq>$2 ORDER BY m.seq LIMIT 101", p.Device, cursor)
	if e != nil {
		return e
	}
	more := len(messages) > 100
	if more {
		messages = messages[:100]
	}
	for _, m := range messages {
		cursor = m["seq"].(int64)
		delete(m, "seq")
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]any{"server_id": a.cfg.ID, "account_id": p.User, "binding_id": p.Device, "device_name": deviceName, "snapshots": snaps, "messages": messages, "cursor": strconv.FormatInt(cursor, 10), "has_more": more})
	return nil
}
func tokenValid(t string) bool {
	if len(t) < 32 || len(t) > 2048 || len(t)%2 != 0 {
		return false
	}
	_, e := hex.DecodeString(t)
	return e == nil
}
func (a *App) registration(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device", "read")
	if e != nil {
		return e
	}
	if e = a.activeDevice(r.Context(), p); e != nil {
		return e
	}
	var b struct {
		Environment string  `json:"environment"`
		APNs        *string `json:"apns_token"`
		Widget      *string `json:"widget_token"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if !contains([]string{"sandbox", "production"}, b.Environment) || (b.APNs != nil && !tokenValid(*b.APNs)) || (b.Widget != nil && !tokenValid(*b.Widget)) {
		return bad("invalid_registration", "推送环境或token无效。")
	}
	if p.Kind == "read" && b.APNs != nil {
		return APIError{403, "forbidden", "只读凭证不能注册通知token。"}
	}
	// Environment is part of token identity; changing it invalidates both prior tokens.
	_, e = a.db.Exec(r.Context(), `UPDATE devices SET apns_token=CASE WHEN $1::text IS NOT NULL THEN $1 WHEN environment<>$3 THEN NULL ELSE apns_token END,widget_token=CASE WHEN $2::text IS NOT NULL THEN $2 WHEN environment<>$3 THEN NULL ELSE widget_token END,environment=$3,updated_at=now() WHERE id=$4 AND NOT revoked`, b.APNs, b.Widget, b.Environment, p.Device)
	if e != nil {
		return e
	}
	if b.APNs != nil || b.Widget != nil {
		_, e = a.db.Exec(r.Context(), "UPDATE outbox SET status='queued',available_at=now(),error=NULL WHERE device_id=$1 AND status='blocked' AND expires_at>now()", p.Device)
		if e != nil {
			return e
		}
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) subscriptions(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device")
	if e != nil {
		return e
	}
	if e = a.activeDevice(r.Context(), p); e != nil {
		return e
	}
	var b struct {
		DataIDs []string `json:"data_ids"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if b.DataIDs == nil || len(b.DataIDs) > 32 {
		return bad("invalid_subscriptions", "最多关注32个数据流。")
	}
	seen := map[string]bool{}
	list := []string{}
	for _, d := range b.DataIDs {
		if seen[d] {
			continue
		}
		seen[d] = true
		var exists bool
		if e = a.db.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM streams WHERE user_id=$1 AND data_id=$2)", p.User, d).Scan(&exists); e != nil {
			return e
		}
		if !exists {
			return notfound()
		}
		list = append(list, d)
	}
	_, e = a.db.Exec(r.Context(), "UPDATE devices SET subscriptions=$1,updated_at=now() WHERE id=$2 AND NOT revoked", canonical(list), p.Device)
	if e != nil {
		return e
	}
	_, e = a.db.Exec(r.Context(), "UPDATE outbox SET status='cancelled',updated_at=now() WHERE device_id=$1 AND kind='widget' AND NOT ($2::jsonb ? resource_id) AND status IN ('queued','retry','blocked')", p.Device, canonical(list))
	if e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) deviceStatus(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device")
	if e != nil {
		return e
	}
	var b struct {
		Enabled *bool `json:"enabled"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if b.Enabled == nil {
		return bad("enabled_required", "请指定是否启用接收。")
	}
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if _, e = tx.Exec(ctx, "UPDATE devices SET enabled=$1,updated_at=now() WHERE id=$2 AND NOT revoked", *b.Enabled, p.Device); e != nil {
		return e
	}
	if !*b.Enabled {
		if _, e = tx.Exec(ctx, "UPDATE outbox SET status='cancelled',updated_at=now() WHERE device_id=$1 AND status IN ('queued','retry','blocked')", p.Device); e != nil {
			return e
		}
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) revoke(w http.ResponseWriter, r *http.Request, p identity, device string) error {
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	tag, e := tx.Exec(ctx, "UPDATE devices SET revoked=true,enabled=false,apns_token=NULL,widget_token=NULL,updated_at=now() WHERE id=$1 AND user_id=$2", device, p.User)
	if e != nil {
		return e
	}
	if tag.RowsAffected() == 0 {
		return notfound()
	}
	if _, e = tx.Exec(ctx, "UPDATE credentials SET revoked=true WHERE device_id=$1", device); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "UPDATE outbox SET status='cancelled',updated_at=now() WHERE device_id=$1 AND status IN ('queued','retry','blocked','sending')", device); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) revokeDevice(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device")
	if e != nil {
		return e
	}
	return a.revoke(w, r, p, p.Device)
}
func (a *App) adminRevokeDevice(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	p, e = a.webDevice(r, p, r.PathValue("id"))
	if e != nil {
		return e
	}
	return a.revoke(w, r, p, p.Device)
}
