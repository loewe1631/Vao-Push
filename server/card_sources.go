package main

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"net/http"
	"net/http/httptest"
	"strings"
	"time"
)

type FieldMapping struct {
	Key   string `json:"key"`
	Path  string `json:"path"`
	Type  string `json:"type"`
	Label string `json:"label,omitempty"`
	Unit  string `json:"unit,omitempty"`
}
type SourceConfig struct {
	URL        string            `json:"url,omitempty"`
	Headers    map[string]string `json:"headers,omitempty"`
	ListPath   string            `json:"list_path,omitempty"`
	ItemIDPath string            `json:"item_id_path,omitempty"`
	Fields     []FieldMapping    `json:"fields,omitempty"`
}

func (a *App) cardSources(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	rows, e := rowsJSON(r.Context(), a.db, `SELECT c.id,c.name,c.mode,c.enabled,c.interval_seconds,c.last_success,c.last_error,s.data_id,s.id AS stream_id,s.revision::text,s.state FROM card_sources c JOIN streams s ON s.id=c.stream_id WHERE c.user_id=$1 ORDER BY c.id`, p.User)
	if e != nil {
		return e
	}
	ok(w, map[string]any{"sources": rows})
	return nil
}
func (a *App) createCardSource(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		Name     string       `json:"name"`
		Mode     string       `json:"mode"`
		Config   SourceConfig `json:"config"`
		Interval int          `json:"interval_seconds"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if len(strings.TrimSpace(b.Name)) == 0 || len(b.Name) > 120 || !contains([]string{"push", "http"}, b.Mode) {
		return bad("invalid_source", "请填写数据源名称与接入方式。")
	}
	if b.Interval == 0 {
		b.Interval = 300
	}
	if b.Interval < 60 || b.Interval > 86400 {
		return bad("invalid_interval", "采集周期须为60至86400秒。")
	}
	if b.Mode == "http" {
		if e = validateSourceConfig(b.Config); e != nil {
			return e
		}
	}
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if e = txLock(ctx, tx, p.User+":card-sources"); e != nil {
		return e
	}
	var n int
	if e = tx.QueryRow(ctx, "SELECT count(*) FROM card_sources WHERE user_id=$1", p.User).Scan(&n); e != nil {
		return e
	}
	if n >= 32 {
		return bad("source_limit", "此管理作用域最多32个数据源。")
	}
	sid, cid, key := id("stream_"), id("src_"), token()
	sourceUser := id("acct_")
	if _, e = tx.Exec(ctx, "INSERT INTO users(id,username,password) VALUES($1,$2,$3)", sourceUser, "source:"+cid, []byte{}); e != nil {
		return e
	}
	dataID := "card_" + strings.TrimPrefix(cid, "src_")
	config, e := a.seal(canonical(b.Config))
	if e != nil {
		return e
	}
	ingress, e := a.seal(canonical(map[string]string{"key": key}))
	if e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "INSERT INTO streams(id,user_id,data_id,name,ordering) VALUES($1,$2,$3,$4,'server_order')", sid, sourceUser, dataID, b.Name); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "INSERT INTO credentials(hash,user_id,kind,name,scopes,data_ids,expires_at) VALUES($1,$2,'source',$3,$4,$5,now()+interval '10 years')", hash(key), sourceUser, b.Name, canonical([]string{"states:write"}), canonical([]string{dataID})); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "INSERT INTO card_sources(id,user_id,stream_id,name,mode,config,ingress,interval_seconds) VALUES($1,$2,$3,$4,$5,$6,$7,$8)", cid, p.User, sid, b.Name, b.Mode, config, ingress, b.Interval); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]any{"id": cid, "data_id": dataID, "data_url": a.cfg.PublicURL + "/v1/card-data/" + key})
	return nil
}
func (a *App) sourceKey(ctx context.Context, user, source string) (string, error) {
	var sealed []byte
	e := a.db.QueryRow(ctx, "SELECT ingress FROM card_sources WHERE id=$1 AND user_id=$2", source, user).Scan(&sealed)
	if e == pgx.ErrNoRows {
		return "", notfound()
	}
	if e != nil {
		return "", e
	}
	raw, e := a.unseal(sealed)
	if e != nil {
		return "", e
	}
	var out struct {
		Key string `json:"key"`
	}
	e = json.Unmarshal(raw, &out)
	return out.Key, e
}
func (a *App) sourceAccess(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	key, e := a.sourceKey(r.Context(), p.User, r.PathValue("id"))
	if e != nil {
		return e
	}
	ok(w, map[string]string{"data_url": a.cfg.PublicURL + "/v1/card-data/" + key})
	return nil
}
func (a *App) sourceState(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	key, e := a.sourceKey(r.Context(), p.User, r.PathValue("id"))
	if e != nil {
		return e
	}
	req := r.Clone(r.Context())
	req.SetPathValue("key", key)
	return a.cardData(w, req)
}
func (a *App) cardData(w http.ResponseWriter, r *http.Request) error {
	key := r.PathValue("key")
	if len(key) != 64 || !tokenValid(key) {
		return unauthorized()
	}
	req := r.Clone(r.Context())
	req.Header.Set("Authorization", "Bearer "+key)
	p, e := a.authenticate(req, "source")
	if e != nil {
		return e
	}
	if len(p.DataIDs) != 1 {
		return unauthorized()
	}
	req.SetPathValue("data_id", p.DataIDs[0])
	return a.state(w, req)
}
func (a *App) setSourceEnabled(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		Enabled bool `json:"enabled"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	result, e := a.db.Exec(r.Context(), "UPDATE card_sources SET enabled=$3 WHERE id=$1 AND user_id=$2", r.PathValue("id"), p.User, b.Enabled)
	if e != nil {
		return e
	}
	if result.RowsAffected() != 1 {
		return notfound()
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) pollCardSource(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	if e = a.pollSource(r.Context(), r.PathValue("id"), p.User); e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
func (a *App) pollSource(ctx context.Context, source, user string) error {
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	var locked bool
	if e = tx.QueryRow(ctx, "SELECT pg_try_advisory_xact_lock(hashtextextended($1,0))", "source-poll:"+source).Scan(&locked); e != nil {
		return e
	}
	if !locked {
		return conflict("source_busy", "数据源正在采集，请稍后查看。")
	}
	var config []byte
	var mode string
	var enabled bool
	var interval int
	e = tx.QueryRow(ctx, "SELECT config,mode,enabled,interval_seconds FROM card_sources WHERE id=$1 AND user_id=$2", source, user).Scan(&config, &mode, &enabled, &interval)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	if mode != "http" || !enabled {
		return bad("source_disabled", "该数据源未启用HTTP采集。")
	}
	raw, e := a.unseal(config)
	if e != nil {
		return e
	}
	var cfg SourceConfig
	if e = json.Unmarshal(raw, &cfg); e != nil {
		return e
	}
	state, fetchError := fetchSource(ctx, cfg)
	if fetchError == nil {
		state["valid_for_seconds"] = interval * 2
		key, err := a.sourceKey(ctx, user, source)
		if err != nil {
			return err
		}
		req, _ := http.NewRequestWithContext(ctx, "PUT", "https://internal.invalid/v1/card-data/", bytes.NewReader(canonical(state)))
		req.SetPathValue("key", key)
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		fetchError = a.cardData(rec, req)
	}
	if fetchError != nil {
		if _, e = tx.Exec(ctx, "UPDATE card_sources SET last_error=$2,next_poll=now()+$3*interval '1 second' WHERE id=$1", source, "采集失败，请检查API地址、鉴权、字段映射及可达性。", interval); e != nil {
			return e
		}
	} else {
		if _, e = tx.Exec(ctx, "UPDATE card_sources SET last_success=now(),last_error=NULL,next_poll=now()+$2*interval '1 second' WHERE id=$1", source, interval); e != nil {
			return e
		}
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	if fetchError != nil {
		return bad("source_fetch_failed", "采集失败，保留上次有效数据；请检查API、鉴权与字段映射。")
	}
	return nil
}
func (a *App) sourceWorker(ctx context.Context) {
	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			rows, e := rowsJSON(ctx, a.db, "SELECT id,user_id FROM card_sources WHERE enabled AND mode='http' AND next_poll<=now() ORDER BY next_poll LIMIT 4")
			if e != nil {
				continue
			}
			for _, row := range rows {
				_ = a.pollSource(ctx, row["id"].(string), row["user_id"].(string))
			}
		}
	}
}

func (a *App) sourceSettings(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var raw []byte
	var name, mode string
	var interval int
	e = a.db.QueryRow(r.Context(), "SELECT name,mode,config,interval_seconds FROM card_sources WHERE id=$1 AND user_id=$2", r.PathValue("id"), p.User).Scan(&name, &mode, &raw, &interval)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	decoded, e := a.unseal(raw)
	if e != nil {
		return e
	}
	var cfg SourceConfig
	if e = json.Unmarshal(decoded, &cfg); e != nil {
		return e
	}
	configured := len(cfg.Headers) > 0
	cfg.Headers = nil
	ok(w, map[string]any{"id": r.PathValue("id"), "name": name, "mode": mode, "config": cfg, "headers_configured": configured, "interval_seconds": interval})
	return nil
}
func (a *App) updateSource(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var b struct {
		Name     string       `json:"name"`
		Config   SourceConfig `json:"config"`
		Interval int          `json:"interval_seconds"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	if strings.TrimSpace(b.Name) == "" || len(b.Name) > 120 || b.Interval < 60 || b.Interval > 86400 {
		return bad("invalid_source", "请检查名称和采集周期。")
	}
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if e = txLock(ctx, tx, "source-settings:"+r.PathValue("id")); e != nil {
		return e
	}
	var mode string
	var raw []byte
	e = tx.QueryRow(ctx, "SELECT mode,config FROM card_sources WHERE id=$1 AND user_id=$2 FOR UPDATE", r.PathValue("id"), p.User).Scan(&mode, &raw)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	if mode == "http" {
		decoded, err := a.unseal(raw)
		if err != nil {
			return err
		}
		var old SourceConfig
		if err = json.Unmarshal(decoded, &old); err != nil {
			return err
		}
		if b.Config.Headers == nil {
			b.Config.Headers = old.Headers
		}
		if e = validateSourceConfig(b.Config); e != nil {
			return e
		}
	}
	sealed, e := a.seal(canonical(b.Config))
	if e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "UPDATE card_sources SET name=$3,config=$4,interval_seconds=$5,next_poll=now() WHERE id=$1 AND user_id=$2", r.PathValue("id"), p.User, b.Name, sealed, b.Interval); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}

func (a *App) isolateCardSources(ctx context.Context) error {
	rows, e := rowsJSON(ctx, a.db, `SELECT c.id,c.user_id,c.stream_id,s.data_id FROM card_sources c JOIN streams s ON s.id=c.stream_id WHERE s.user_id=c.user_id`)
	if e != nil {
		return e
	}
	for _, row := range rows {
		tx, err := a.db.Begin(ctx)
		if err != nil {
			return err
		}
		err = txLock(ctx, tx, "isolate-source:"+row["id"].(string))
		if err == nil {
			var old string
			err = tx.QueryRow(ctx, "SELECT user_id FROM streams WHERE id=$1 FOR UPDATE", row["stream_id"]).Scan(&old)
			if err == nil && old == row["user_id"] {
				var owner string
				err = tx.QueryRow(ctx, `INSERT INTO users(id,username,password) VALUES($1,$2,$3) ON CONFLICT(username) DO UPDATE SET username=EXCLUDED.username WHERE octet_length(users.password)=0 RETURNING id`, id("acct_"), "source:"+row["id"].(string), []byte{}).Scan(&owner)
				if err == nil {
					_, err = tx.Exec(ctx, "UPDATE streams SET user_id=$2 WHERE id=$1", row["stream_id"], owner)
				}
				if err == nil {
					_, err = tx.Exec(ctx, "UPDATE credentials SET user_id=$3 WHERE user_id=$1 AND kind='source' AND data_ids ? $2", old, row["data_id"], owner)
				}
			}
		}
		if err == nil {
			err = tx.Commit(ctx)
		} else {
			_ = tx.Rollback(ctx)
		}
		if err != nil {
			return err
		}
	}
	return nil
}
