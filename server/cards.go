package main

import (
	"context"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func (a *App) cards(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	rows, e := rowsJSON(r.Context(), a.db, "SELECT id,source_id,draft,draft_revision::text,published,revision::text,updated_at FROM card_templates WHERE user_id=$1 ORDER BY updated_at DESC LIMIT 64", p.User)
	if e != nil {
		return e
	}
	ok(w, map[string]any{"cards": rows})
	return nil
}
func (a *App) saveCard(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		Source string          `json:"source_id"`
		Design json.RawMessage `json:"design"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	design, e := validateDesign(b.Design)
	if e != nil {
		return e
	}
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if e = cardLifecycleLock(ctx, tx, p.User); e != nil {
		return e
	}
	cid := r.PathValue("id")
	var revision int64 = 1
	if cid == "" {
		if e = txLock(ctx, tx, p.User+":cards"); e != nil {
			return e
		}
		var count int
		if e = tx.QueryRow(ctx, "SELECT count(*) FROM card_templates WHERE user_id=$1", p.User).Scan(&count); e != nil {
			return e
		}
		if count >= 64 {
			return bad("card_limit", "最多保存64张Web卡片。")
		}
		var source string
		if e = tx.QueryRow(ctx, "SELECT id FROM card_sources WHERE id=$1 AND user_id=$2", b.Source, p.User).Scan(&source); e == pgx.ErrNoRows {
			return notfound()
		}
		if e != nil {
			return e
		}
		cid = id("card_")
		_, e = tx.Exec(ctx, "INSERT INTO card_templates(id,user_id,source_id,draft) VALUES($1,$2,$3,$4)", cid, p.User, b.Source, canonical(design))
	} else {
		var source string
		e = tx.QueryRow(ctx, "SELECT draft_revision,source_id FROM card_templates WHERE id=$1 AND user_id=$2 FOR UPDATE", cid, p.User).Scan(&revision, &source)
		if e == pgx.ErrNoRows {
			return notfound()
		}
		if e != nil {
			return e
		}
		if b.Source != "" && b.Source != source {
			return bad("fixed_source", "更换数据源请复制为新卡片。")
		}
		if r.Header.Get("If-Match") != `"draft-`+strconv.FormatInt(revision, 10)+`"` {
			return APIError{412, "draft_conflict", "草稿已变化，请重新读取后编辑。"}
		}
		revision++
		_, e = tx.Exec(ctx, "UPDATE card_templates SET draft=$2,draft_revision=$3,updated_at=now() WHERE id=$1", cid, canonical(design), revision)
	}
	if e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]any{"id": cid, "draft_revision": strconv.FormatInt(revision, 10)})
	return nil
}
func queueCardUpdate(ctx context.Context, tx pgx.Tx, card string) error {
	rows, e := rowsJSON(ctx, tx, "SELECT d.id,d.user_id FROM card_subscriptions cs JOIN devices d ON d.id=cs.device_id WHERE cs.card_id=$1 AND d.enabled AND NOT d.revoked", card)
	if e != nil {
		return e
	}
	for _, d := range rows {
		if _, e = tx.Exec(ctx, "UPDATE outbox SET status='superseded',updated_at=now() WHERE device_id=$1 AND kind='widget' AND resource_id=$2 AND status IN ('queued','retry','blocked')", d["id"], card); e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, "INSERT INTO outbox(id,user_id,device_id,kind,resource_id,payload,expires_at) VALUES($1,$2,$3,'widget',$4,$5,now()+interval '1 hour')", id("job_"), d["user_id"], d["id"], card, canonical(map[string]any{"aps": map[string]bool{"content-changed": true}})); e != nil {
			return e
		}
	}
	return nil
}
func (a *App) publishCard(w http.ResponseWriter, r *http.Request) error {
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
	if e = cardLifecycleLock(ctx, tx, p.User); e != nil {
		return e
	}
	var raw []byte
	var draft, revision int64
	var hasData bool
	e = tx.QueryRow(ctx, `SELECT t.draft,t.draft_revision,t.revision,s.state IS NOT NULL FROM card_templates t JOIN card_sources c ON c.id=t.source_id JOIN streams s ON s.id=c.stream_id WHERE t.id=$1 AND t.user_id=$2 FOR UPDATE OF t`, r.PathValue("id"), p.User).Scan(&raw, &draft, &revision, &hasData)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	if r.Header.Get("If-Match") != `"draft-`+strconv.FormatInt(draft, 10)+`"` {
		return APIError{412, "draft_conflict", "请先保存当前草稿，再发布对应版本。"}
	}
	if !hasData {
		return bad("no_source_data", "请先发送或采集一份有效数据，再发布卡片。")
	}
	if _, e = validateDesign(raw); e != nil {
		return e
	}
	revision++
	if _, e = tx.Exec(ctx, "UPDATE card_templates SET published=draft,revision=$2,updated_at=now() WHERE id=$1", r.PathValue("id"), revision); e != nil {
		return e
	}
	if e = queueCardUpdate(ctx, tx, r.PathValue("id")); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]any{"revision": strconv.FormatInt(revision, 10)})
	return nil
}
func (a *App) cardCode(w http.ResponseWriter, r *http.Request) error {
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
	if e = cardLifecycleLock(ctx, tx, p.User); e != nil {
		return e
	}
	var exists bool
	if e = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM card_templates WHERE id=$1 AND user_id=$2 AND published IS NOT NULL)", r.PathValue("id"), p.User).Scan(&exists); e != nil {
		return e
	}
	if !exists {
		return notfound()
	}
	code := "VP-" + strings.ToUpper(token()[:24])
	until := time.Now().Add(time.Hour)
	if _, e = tx.Exec(ctx, "INSERT INTO card_import_codes(hash,card_id,expires_at) VALUES($1,$2,$3)", hash(code), r.PathValue("id"), until); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]any{"code": code, "expires_at": stamp(until), "max_uses": 10, "link": a.cfg.PublicURL + "/?card_code=" + code})
	return nil
}

func (a *App) revokeCardCodes(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var exists bool
	if e = a.db.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM card_templates WHERE id=$1 AND user_id=$2)", r.PathValue("id"), p.User).Scan(&exists); e != nil {
		return e
	}
	if !exists {
		return notfound()
	}
	_, e = a.db.Exec(r.Context(), "UPDATE card_import_codes SET revoked=true WHERE card_id=$1", r.PathValue("id"))
	if e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) redeemCard(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device")
	if e != nil {
		return e
	}
	if e = a.activeDevice(r.Context(), p); e != nil {
		return e
	}
	if !a.limiter.allow("card-code:"+p.Device, time.Now()) {
		return APIError{429, "rate_limited", "导入尝试过多，请稍后重试。"}
	}
	var b struct {
		Code string `json:"code"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	code := strings.ToUpper(strings.TrimSpace(b.Code))
	if len(code) != 27 || !strings.HasPrefix(code, "VP-") {
		return bad("invalid_card_code", "请输入有效卡片订阅码。")
	}
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	var cid, owner string
	if e = tx.QueryRow(ctx, "SELECT t.user_id FROM card_import_codes c JOIN card_templates t ON t.id=c.card_id WHERE c.hash=$1", hash(code)).Scan(&owner); e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	if e = cardLifecycleLock(ctx, tx, owner); e != nil {
		return e
	}

	var used, max int
	var expires time.Time
	var revoked bool
	e = tx.QueryRow(ctx, `SELECT c.card_id,t.user_id,c.uses,c.max_uses,c.expires_at,c.revoked FROM card_import_codes c JOIN card_templates t ON t.id=c.card_id WHERE c.hash=$1 AND t.published IS NOT NULL FOR UPDATE OF c`, hash(code)).Scan(&cid, &owner, &used, &max, &expires, &revoked)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	if revoked || !time.Now().Before(expires) {
		return bad("expired_card_code", "订阅码已失效，请重新生成。")
	}
	var allowed bool
	if e = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM devices d LEFT JOIN device_keys k ON k.device_id=d.id WHERE d.id=$1 AND NOT d.revoked AND (d.user_id=$2 OR k.owner_id=$2))`, p.Device, owner).Scan(&allowed); e != nil {
		return e
	}
	if !allowed {
		return notfound()
	}
	if e = txLock(ctx, tx, p.Device+":card-subscriptions"); e != nil {
		return e
	}
	var existing bool
	if e = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM card_subscriptions WHERE card_id=$1 AND device_id=$2)", cid, p.Device).Scan(&existing); e != nil {
		return e
	}
	if !existing {
		if used >= max {
			return bad("code_used", "订阅码使用次数已达上限。")
		}
		var n int
		if e = tx.QueryRow(ctx, "SELECT count(*) FROM card_subscriptions WHERE device_id=$1", p.Device).Scan(&n); e != nil {
			return e
		}
		if n >= 16 {
			return bad("subscription_limit", "每台设备最多订阅16张Web卡片。")
		}
		if _, e = tx.Exec(ctx, "INSERT INTO card_subscriptions(card_id,device_id) VALUES($1,$2) ON CONFLICT DO NOTHING", cid, p.Device); e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, "UPDATE card_import_codes SET uses=uses+1 WHERE hash=$1", hash(code)); e != nil {
			return e
		}
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]string{"card_id": cid})
	return nil
}
func (a *App) cardSubscriptions(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device")
	if e != nil {
		return e
	}
	if e = a.activeDevice(r.Context(), p); e != nil {
		return e
	}
	rows, e := rowsJSON(r.Context(), a.db, "SELECT t.id AS card_id,t.revision::text,t.published->>'name' AS name FROM card_subscriptions cs JOIN card_templates t ON t.id=cs.card_id WHERE cs.device_id=$1 ORDER BY t.id LIMIT 16", p.Device)
	if e != nil {
		return e
	}
	ok(w, map[string]any{"cards": rows})
	return nil
}
func (a *App) subscribedCard(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device", "read")
	if e != nil {
		return e
	}
	if e = a.activeDevice(r.Context(), p); e != nil {
		return e
	}
	rows, e := rowsJSON(r.Context(), a.db, `SELECT t.id AS card_id,t.revision::text,t.published AS design,s.id AS stream_id,s.data_id,s.revision::text AS data_revision,s.received_at,s.state FROM card_subscriptions cs JOIN card_templates t ON t.id=cs.card_id JOIN card_sources c ON c.id=t.source_id JOIN streams s ON s.id=c.stream_id WHERE cs.device_id=$1 AND t.id=$2 AND t.published IS NOT NULL`, p.Device, r.PathValue("id"))
	if e != nil {
		return e
	}
	if len(rows) != 1 {
		return notfound()
	}
	row := rows[0]
	data := map[string]any{"card_id": row["card_id"], "revision": row["revision"], "design": row["design"], "snapshot": map[string]any{"stream_id": row["stream_id"], "data_id": row["data_id"], "revision": row["data_revision"], "received_at": row["received_at"], "state": row["state"]}}
	ok(w, data)
	return nil
}
func (a *App) unsubscribeCard(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device")
	if e != nil {
		return e
	}
	_, e = a.db.Exec(r.Context(), "DELETE FROM card_subscriptions WHERE card_id=$1 AND device_id=$2", r.PathValue("id"), p.Device)
	if e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) cardSubscribers(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var owner string
	e = a.db.QueryRow(r.Context(), "SELECT user_id FROM card_templates WHERE id=$1 AND user_id=$2", r.PathValue("id"), p.User).Scan(&owner)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	rows, e := rowsJSON(r.Context(), a.db, "SELECT d.id,d.name,d.enabled FROM card_subscriptions cs JOIN devices d ON d.id=cs.device_id WHERE cs.card_id=$1 AND NOT d.revoked", r.PathValue("id"))
	if e != nil {
		return e
	}
	ok(w, map[string]any{"devices": rows})
	return nil
}
func (a *App) revokeCardSubscription(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	result, e := a.db.Exec(r.Context(), "DELETE FROM card_subscriptions cs USING card_templates t WHERE t.id=cs.card_id AND t.user_id=$1 AND cs.card_id=$2 AND cs.device_id=$3", p.User, r.PathValue("id"), r.PathValue("device"))
	if e != nil {
		return e
	}
	if result.RowsAffected() != 1 {
		return notfound()
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}

func (a *App) validateCardCode(w http.ResponseWriter, r *http.Request) error {
	if _, e := a.authenticate(r, "web"); e != nil {
		return e
	}
	var b struct {
		Design json.RawMessage `json:"design"`
	}
	if e := decode(r, &b); e != nil {
		return e
	}
	design, e := validateDesign(b.Design)
	if e != nil {
		return e
	}
	ok(w, design)
	return nil
}
