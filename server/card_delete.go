package main

import (
	"context"
	"github.com/jackc/pgx/v5"
	"net/http"
)

type deletionCard struct {
	ID                string           `json:"id"`
	Name              string           `json:"name"`
	DraftRevision     int64            `json:"draft_revision"`
	PublishedRevision int64            `json:"published_revision"`
	Devices           []map[string]any `json:"devices"`
	codeHashes        []string
}

type deletionPreview struct {
	Kind        string         `json:"kind"`
	ID          string         `json:"id"`
	Name        string         `json:"name"`
	Cards       []deletionCard `json:"cards"`
	DeviceCount int            `json:"device_count"`
	Token       string         `json:"confirmation_token"`
}

func cardLifecycleLock(ctx context.Context, tx pgx.Tx, owner string) error {
	return txLock(ctx, tx, owner+":card-lifecycle")
}

func deletionCards(ctx context.Context, tx pgx.Tx, owner, source, card string) ([]deletionCard, error) {
	rows, e := tx.Query(ctx, `SELECT id,draft->>'name',draft_revision,revision FROM card_templates WHERE user_id=$1 AND (($2<>'' AND source_id=$2) OR ($3<>'' AND id=$3)) ORDER BY id FOR UPDATE`, owner, source, card)
	if e != nil {
		return nil, e
	}
	cards := []deletionCard{}
	for rows.Next() {
		var c deletionCard
		if e = rows.Scan(&c.ID, &c.Name, &c.DraftRevision, &c.PublishedRevision); e != nil {
			rows.Close()
			return nil, e
		}
		cards = append(cards, c)
	}
	rows.Close()
	if e = rows.Err(); e != nil {
		return nil, e
	}
	for i := range cards {
		cards[i].Devices, e = rowsJSON(ctx, tx, `SELECT d.id,d.name FROM card_subscriptions cs JOIN devices d ON d.id=cs.device_id WHERE cs.card_id=$1 ORDER BY d.id`, cards[i].ID)
		if e != nil {
			return nil, e
		}
		if cards[i].Devices == nil {
			cards[i].Devices = []map[string]any{}
		}
		codes, err := tx.Query(ctx, "SELECT hash FROM card_import_codes WHERE card_id=$1 ORDER BY hash FOR UPDATE", cards[i].ID)
		if err != nil {
			return nil, err
		}
		for codes.Next() {
			var h string
			if e = codes.Scan(&h); e != nil {
				codes.Close()
				return nil, e
			}
			cards[i].codeHashes = append(cards[i].codeHashes, h)
		}
		codes.Close()
		if e = codes.Err(); e != nil {
			return nil, e
		}
	}
	return cards, nil
}

func deletionToken(p deletionPreview) string {
	// Bind confirmation to exact card revisions, subscriptions, and import-code identities.
	codes := [][]string{}
	for _, c := range p.Cards {
		codes = append(codes, c.codeHashes)
	}
	p.Token = ""
	return `"delete-` + hash(string(canonical(map[string]any{"preview": p, "codes": codes}))) + `"`
}

func finishDeletionPreview(p *deletionPreview) {
	devices := map[string]bool{}
	for _, c := range p.Cards {
		for _, d := range c.Devices {
			devices[d["id"].(string)] = true
		}
	}
	p.DeviceCount = len(devices)
	p.Token = deletionToken(*p)
}

func requireDeletionVersion(r *http.Request, token string) error {
	if r.Header.Get("If-Match") == "" {
		return APIError{428, "deletion_confirmation_required", "请先查看删除影响，再确认删除。"}
	}
	if r.Header.Get("If-Match") != token {
		return APIError{412, "deletion_changed", "卡片或订阅已变化，请重新查看删除影响后确认。"}
	}
	return nil
}

func deleteCardRows(ctx context.Context, tx pgx.Tx, cards []deletionCard) error {
	for _, c := range cards {
		if _, e := tx.Exec(ctx, `UPDATE outbox SET status='cancelled',error='resource_deleted',lease_until=NULL,updated_at=now() WHERE kind='widget' AND resource_id=$1 AND status IN ('queued','retry','blocked','sending')
  AND device_id IN (SELECT device_id FROM card_subscriptions WHERE card_id=$1)
  AND NOT EXISTS (SELECT 1 FROM streams s WHERE s.user_id=outbox.user_id AND s.data_id=outbox.resource_id)`, c.ID); e != nil {
			return e
		}
		for _, table := range []string{"card_import_codes", "card_subscriptions"} {
			if _, e := tx.Exec(ctx, "DELETE FROM "+table+" WHERE card_id=$1", c.ID); e != nil {
				return e
			}
		}
		if _, e := tx.Exec(ctx, "DELETE FROM card_templates WHERE id=$1", c.ID); e != nil {
			return e
		}
	}
	return nil
}

func (a *App) cardDeletion(w http.ResponseWriter, r *http.Request) error {
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
	cards, e := deletionCards(ctx, tx, p.User, "", r.PathValue("id"))
	if e != nil {
		return e
	}
	if len(cards) != 1 {
		return notfound()
	}
	preview := deletionPreview{Kind: "card", ID: cards[0].ID, Name: cards[0].Name, Cards: cards}
	finishDeletionPreview(&preview)
	if r.Method == "GET" {
		if e = tx.Commit(ctx); e != nil {
			return e
		}
		w.Header().Set("Cache-Control", "no-store")
		ok(w, preview)
		return nil
	}
	if e = requireDeletionVersion(r, preview.Token); e != nil {
		return e
	}
	if e = deleteCardRows(ctx, tx, cards); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]any{"deleted": true, "deleted_cards": 1, "source_preserved": true})
	return nil
}

func (a *App) sourceDeletion(w http.ResponseWriter, r *http.Request) error {
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
	var name, stream, sourceUser, dataID string
	e = tx.QueryRow(ctx, `SELECT name,stream_id FROM card_sources WHERE id=$1 AND user_id=$2 FOR UPDATE`, r.PathValue("id"), p.User).Scan(&name, &stream)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	if e = tx.QueryRow(ctx, "SELECT user_id,data_id FROM streams WHERE id=$1 FOR UPDATE", stream).Scan(&sourceUser, &dataID); e != nil {
		return e
	}
	cards, e := deletionCards(ctx, tx, p.User, r.PathValue("id"), "")
	if e != nil {
		return e
	}
	preview := deletionPreview{Kind: "source", ID: r.PathValue("id"), Name: name, Cards: cards}
	finishDeletionPreview(&preview)
	if r.Method == "GET" {
		if e = tx.Commit(ctx); e != nil {
			return e
		}
		w.Header().Set("Cache-Control", "no-store")
		ok(w, preview)
		return nil
	}
	if r.ContentLength != 0 {
		var empty struct{}
		if e = decode(r, &empty); e != nil {
			return e
		}
	}
	if e = requireDeletionVersion(r, preview.Token); e != nil {
		return e
	}
	if len(cards) > 0 {
		return conflict("source_in_use", "这个数据源仍有关联卡片，不能删除。请先处理全部关联卡片，再删除数据源。")
	}
	// A source has no card references here. The worker rechecks authorization for old
	// signals; cancelling by data_id alone could affect independent device streams.
	if _, e = tx.Exec(ctx, "DELETE FROM card_sources WHERE id=$1", preview.ID); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "DELETE FROM credentials WHERE user_id=$1 AND kind='source' AND data_ids ? $2", sourceUser, dataID); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "DELETE FROM streams WHERE id=$1", stream); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, "DELETE FROM idempotency WHERE user_id=$1 AND operation=$2", sourceUser, "state:"+dataID); e != nil {
		return e
	}
	// Only remove the reserved empty-password internal source principal if no live resources reference it.
	if _, e = tx.Exec(ctx, `DELETE FROM users u WHERE u.id=$1 AND u.username=$2 AND octet_length(u.password)=0
  AND NOT EXISTS(SELECT 1 FROM credentials WHERE user_id=u.id) AND NOT EXISTS(SELECT 1 FROM devices WHERE user_id=u.id)
  AND NOT EXISTS(SELECT 1 FROM streams WHERE user_id=u.id) AND NOT EXISTS(SELECT 1 FROM sessions WHERE user_id=u.id)
  AND NOT EXISTS(SELECT 1 FROM pairings WHERE user_id=u.id) AND NOT EXISTS(SELECT 1 FROM groups WHERE user_id=u.id)
  AND NOT EXISTS(SELECT 1 FROM messages WHERE user_id=u.id) AND NOT EXISTS(SELECT 1 FROM outbox WHERE user_id=u.id)
  AND NOT EXISTS(SELECT 1 FROM device_keys WHERE owner_id=u.id) AND NOT EXISTS(SELECT 1 FROM message_routes WHERE user_id=u.id)
  AND NOT EXISTS(SELECT 1 FROM card_sources WHERE user_id=u.id) AND NOT EXISTS(SELECT 1 FROM card_templates WHERE user_id=u.id)`, sourceUser, "source:"+preview.ID); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	ok(w, map[string]any{"deleted": true, "deleted_cards": len(cards), "ingress_revoked": true})
	return nil
}
