package main

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"math/big"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type Field struct {
	Type  string          `json:"type"`
	Label string          `json:"label,omitempty"`
	Unit  string          `json:"unit,omitempty"`
	Value json.RawMessage `json:"value"`
}
type Point struct {
	T      string  `json:"t"`
	Value  *string `json:"value,omitempty"`
	O      *string `json:"o,omitempty"`
	H      *string `json:"h,omitempty"`
	L      *string `json:"l,omitempty"`
	C      *string `json:"c,omitempty"`
	V      *string `json:"v,omitempty"`
	Closed *bool   `json:"is_closed,omitempty"`
}
type Series struct {
	Type     string  `json:"type"`
	Label    string  `json:"label,omitempty"`
	Unit     string  `json:"unit,omitempty"`
	Interval int64   `json:"interval_seconds"`
	Points   []Point `json:"points"`
}
type Item struct {
	ID     string            `json:"item_id"`
	Fields map[string]Field  `json:"fields"`
	Series map[string]Series `json:"series,omitempty"`
}
type State struct {
	Version  int               `json:"schema_version"`
	Source   string            `json:"source_updated_at"`
	TTL      *int64            `json:"valid_for_seconds,omitempty"`
	Title    string            `json:"title,omitempty"`
	Sequence *string           `json:"sequence,omitempty"`
	Fields   *map[string]Field `json:"fields,omitempty"`
	Items    *[]Item           `json:"items,omitempty"`
	Series   map[string]Series `json:"series,omitempty"`
}

var fieldKey = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,63}$`)
var decRE = regexp.MustCompile(`^-?[0-9]+(\.[0-9]+)?$`)
var intRE = regexp.MustCompile(`^-?[0-9]+$`)
var seqRE = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)

func utc(s string) (time.Time, error) {
	t, e := time.Parse(time.RFC3339Nano, s)
	if !strings.HasSuffix(s, "Z") || e != nil {
		return t, bad("invalid_time", "时间必须是 UTC RFC 3339。")
	}
	return t, nil
}
func decimal(s string, integer bool) (*big.Rat, error) {
	pattern := decRE
	if integer {
		pattern = intRE
	}
	parts := strings.Split(s, ".")
	digits := len(strings.ReplaceAll(strings.TrimPrefix(s, "-"), ".", ""))
	if !pattern.MatchString(s) || digits > 38 || (len(parts) == 2 && len(parts[1]) > 18) {
		return nil, bad("invalid_decimal", "数值须为最多38位、18位小数的十进制字符串。")
	}
	v, ok := new(big.Rat).SetString(s)
	if !ok {
		return nil, bad("invalid_decimal", "无效数值。")
	}
	return v, nil
}
func sequence(s string) (int64, error) {
	v, e := strconv.ParseInt(s, 10, 64)
	if e != nil || !seqRE.MatchString(s) || v < 1 {
		return 0, bad("invalid_sequence", "序号须为正整数字符串。")
	}
	return v, nil
}
func validateFields(fields map[string]Field) error {
	if len(fields) > 32 {
		return bad("field_limit", "每层最多32个字段。")
	}
	for key, f := range fields {
		if !fieldKey.MatchString(key) || len(f.Label) > 96 || len(f.Unit) > 96 || f.Value == nil {
			return bad("invalid_field", "字段标识、名称或单位无效，value为必填。")
		}
		if !contains([]string{"text", "decimal", "integer", "percent", "boolean", "datetime"}, f.Type) {
			return bad("invalid_type", "字段类型无效。")
		}
		if bytes.Equal(f.Value, []byte("null")) {
			continue
		}
		if f.Type == "boolean" {
			var b bool
			if json.Unmarshal(f.Value, &b) != nil {
				return bad("invalid_value", "布尔字段需传 true 或 false。")
			}
			continue
		}
		var text string
		if json.Unmarshal(f.Value, &text) != nil {
			return bad("invalid_value", "字段值须为字符串或null。")
		}
		switch f.Type {
		case "text":
			if len(text) > 512 {
				return bad("text_limit", "文本字段超过512字节。")
			}
		case "datetime":
			if _, e := utc(text); e != nil {
				return e
			}
		default:
			if _, e := decimal(text, f.Type == "integer"); e != nil {
				return e
			}
		}
	}
	return nil
}
func validateSeries(series map[string]Series) error {
	for key, s := range series {
		if !fieldKey.MatchString(key) || s.Interval <= 0 || len(s.Points) > 60 || s.Points == nil || (s.Type != "line" && s.Type != "ohlc") || len(s.Label) > 96 || len(s.Unit) > 96 {
			return bad("invalid_series", "序列格式无效或点数超过60。")
		}
		var previous time.Time
		for _, p := range s.Points {
			t, e := utc(p.T)
			if e != nil {
				return e
			}
			if !previous.IsZero() && !t.After(previous) {
				return bad("series_order", "序列时间须严格递增。")
			}
			previous = t
			if s.Type == "line" {
				if p.Value == nil {
					return bad("invalid_point", "折线缺少value。")
				}
				if _, e = decimal(*p.Value, false); e != nil {
					return e
				}
			} else {
				if p.O == nil || p.H == nil || p.L == nil || p.C == nil {
					return bad("invalid_point", "OHLC缺少开高低收。")
				}
				o, e := decimal(*p.O, false)
				if e != nil {
					return e
				}
				h, e := decimal(*p.H, false)
				if e != nil {
					return e
				}
				l, e := decimal(*p.L, false)
				if e != nil {
					return e
				}
				c, e := decimal(*p.C, false)
				if e != nil {
					return e
				}
				if h.Cmp(o) < 0 || h.Cmp(c) < 0 || l.Cmp(o) > 0 || l.Cmp(c) > 0 || h.Cmp(l) < 0 {
					return bad("ohlc_geometry", "OHLC高低关系错误。")
				}
				if p.V != nil {
					v, e := decimal(*p.V, false)
					if e != nil {
						return e
					}
					if v.Sign() < 0 {
						return bad("negative_volume", "成交量不可为负。")
					}
				}
			}
		}
	}
	return nil
}
func validateState(raw []byte) (State, error) {
	var s State
	if len(raw) > 64*1024 {
		return s, APIError{413, "state_limit", "状态超过64KiB。"}
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&s) != nil {
		return s, bad("invalid_state", "状态字段无效。")
	}
	if s.Version != 1 || (s.Fields == nil && s.Items == nil) || len(s.Title) > 256 {
		return s, bad("invalid_state", "需要版本1、来源时间以及fields或items。")
	}
	if _, e := utc(s.Source); e != nil {
		return s, e
	}
	if s.TTL != nil && *s.TTL <= 0 {
		return s, bad("invalid_ttl", "有效期须为正整数。")
	}
	if s.Sequence != nil {
		if _, e := sequence(*s.Sequence); e != nil {
			return s, e
		}
	}
	if s.Fields != nil {
		if e := validateFields(*s.Fields); e != nil {
			return s, e
		}
	}
	if e := validateSeries(s.Series); e != nil {
		return s, e
	}
	count := len(s.Series)
	if s.Items != nil {
		if len(*s.Items) > 20 {
			return s, bad("item_limit", "最多20个项目。")
		}
		seen := map[string]bool{}
		for _, item := range *s.Items {
			if item.ID == "" || len(item.ID) > 128 || seen[item.ID] || item.Fields == nil {
				return s, bad("invalid_item", "项目ID须唯一，且需要fields。")
			}
			seen[item.ID] = true
			if e := validateFields(item.Fields); e != nil {
				return s, e
			}
			if e := validateSeries(item.Series); e != nil {
				return s, e
			}
			count += len(item.Series)
		}
	}
	if count > 4 {
		return s, bad("series_limit", "整份状态最多4组序列。")
	}
	return s, nil
}
func idemBegin(ctx context.Context, tx pgx.Tx, p identity, op, key, bodyHash string) (int, []byte, error) {
	if key == "" {
		return 0, nil, nil
	}
	if len(key) > 128 || strings.TrimSpace(key) != key {
		return 0, nil, bad("invalid_idempotency_key", "幂等键无效。")
	}
	if e := txLock(ctx, tx, p.User+":"+op+":"+key); e != nil {
		return 0, nil, e
	}
	var h string
	var status int
	var b []byte
	e := tx.QueryRow(ctx, "SELECT hash,status,response FROM idempotency WHERE user_id=$1 AND operation=$2 AND key=$3 AND expires_at>now()", p.User, op, key).Scan(&h, &status, &b)
	if e == pgx.ErrNoRows {
		return 0, nil, nil
	}
	if e != nil {
		return 0, nil, e
	}
	if h != bodyHash {
		return 0, nil, conflict("idempotency_conflict", "同一幂等键不能提交不同内容。")
	}
	return status, b, nil
}
func idemSave(ctx context.Context, tx pgx.Tx, p identity, op, key, h string, status int, body any) error {
	if key == "" {
		return nil
	}
	_, e := tx.Exec(ctx, `INSERT INTO idempotency(user_id,operation,key,hash,status,response,expires_at) VALUES($1,$2,$3,$4,$5,$6,now()+interval '24 hours') ON CONFLICT(user_id,operation,key) DO UPDATE SET hash=excluded.hash,status=excluded.status,response=excluded.response,expires_at=excluded.expires_at`, p.User, op, key, h, status, canonical(body))
	return e
}
func stateETag(sid, revision string) string { return `"state-` + sid + `-` + revision + `"` }
func (a *App) state(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web", "sender", "delivery", "source")
	if e != nil {
		return e
	}
	if p.Kind == "web" && r.URL.Query().Get("device_id") != "" {
		p, e = a.webDevice(r, p, r.URL.Query().Get("device_id"))
		if e != nil {
			return e
		}
	}
	dataID := r.PathValue("data_id")
	if !dataKey.MatchString(dataID) {
		return notfound()
	}
	if (p.Kind == "sender" || p.Kind == "source") && (!contains(p.Scopes, "states:write") || !contains(p.DataIDs, dataID)) {
		return notfound()
	}
	var raw map[string]any
	if e = decode(r, &raw); e != nil {
		return e
	}
	if raw == nil {
		return bad("invalid_state", "状态须为 JSON 对象。")
	}
	requestHash := hash(string(canonical(raw)))
	simple := p.Kind == "source" || p.Kind == "delivery" || p.Kind == "web" && p.Device != ""
	if simple {
		if _, exists := raw["schema_version"]; !exists {
			raw["schema_version"] = 1
		}
		if _, exists := raw["source_updated_at"]; !exists {
			raw["source_updated_at"] = stamp(time.Now())
		}
	}
	payload := canonical(raw)
	s, e := validateState(payload)
	if e != nil {
		return e
	}
	h := hash(string(payload))
	ctx := r.Context()
	tx, e := a.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if p.Kind == "source" {
		var sourceID string
		e = tx.QueryRow(ctx, `SELECT c.id FROM card_sources c JOIN streams s ON s.id=c.stream_id WHERE s.user_id=$1 AND s.data_id=$2 FOR KEY SHARE OF c`, p.User, dataID).Scan(&sourceID)
		if e == pgx.ErrNoRows {
			return notfound()
		}
		if e != nil {
			return e
		}
	}

	op := "state:" + dataID
	key := r.Header.Get("Idempotency-Key")
	st, replay, e := idemBegin(ctx, tx, p, op, key, requestHash)
	if e != nil {
		return e
	}
	if replay != nil {
		write(w, st, json.RawMessage(replay))
		return nil
	}
	if simple {
		if e = txLock(ctx, tx, p.User+":stream-create"); e != nil {
			return e
		}
		var count int
		var exists bool
		if e = tx.QueryRow(ctx, "SELECT count(*),coalesce(bool_or(data_id=$2),false) FROM streams WHERE user_id=$1", p.User, dataID).Scan(&count, &exists); e != nil {
			return e
		}
		if !exists {
			if count >= 32 {
				return bad("stream_limit", "每台设备最多保存32个数据ID。")
			}
			if _, e = tx.Exec(ctx, "INSERT INTO streams(id,user_id,data_id,name,ordering) VALUES($1,$2,$3,$3,'server_order')", id("stream_"), p.User, dataID); e != nil {
				return e
			}
		}
	}
	var sid, ordering string
	var rev int64
	var seq *int64
	var oldHash *string
	var received *time.Time
	e = tx.QueryRow(ctx, "SELECT id,ordering,revision,sequence,state_hash,received_at FROM streams WHERE user_id=$1 AND data_id=$2 FOR UPDATE", p.User, dataID).Scan(&sid, &ordering, &rev, &seq, &oldHash, &received)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	if r.Header.Get("If-None-Match") == "*" && rev > 0 {
		return APIError{412, "precondition_failed", "此数据 ID 已有内容，请先读取后再修改。"}
	}
	if match := r.Header.Get("If-Match"); match != "" && match != stateETag(sid, strconv.FormatInt(rev, 10)) {
		return APIError{412, "precondition_failed", "数据已变化，请重新读取后再编辑。"}
	}
	var nextSeq *int64
	if ordering == "source_sequence" {
		if s.Sequence == nil {
			return bad("sequence_required", "此数据流需要sequence。")
		}
		v, _ := sequence(*s.Sequence)
		nextSeq = &v
		if seq != nil {
			if v < *seq {
				return conflict("stale_sequence", "旧序号不能覆盖新数据。")
			}
			if v == *seq && (oldHash == nil || *oldHash != h) {
				return conflict("sequence_conflict", "同序号内容不同。")
			}
		}
	} else if s.Sequence != nil {
		return bad("sequence_not_enabled", "此流未启用序号模式。")
	}
	status := 202
	dispatch := "no_subscribers"
	if oldHash != nil && *oldHash == h {
		status = 200
		dispatch = "unchanged"
	} else {
		if rev == 9223372036854775807 {
			return conflict("revision_exhausted", "请创建新的数据流。")
		}
		rev++
		now := time.Now().UTC()
		received = &now
		if _, e = tx.Exec(ctx, "UPDATE streams SET revision=$1,sequence=$2,state=$3,state_hash=$4,received_at=$5 WHERE id=$6", rev, nextSeq, payload, h, now, sid); e != nil {
			return e
		}
		rows, e := tx.Query(ctx, `SELECT d.id,d.user_id FROM devices d WHERE d.enabled AND NOT d.revoked AND ((d.user_id=$1 AND d.subscriptions ? $2) OR EXISTS(SELECT 1 FROM card_subscriptions cs JOIN card_templates t ON t.id=cs.card_id JOIN card_sources c ON c.id=t.source_id WHERE cs.device_id=d.id AND t.published IS NOT NULL AND c.stream_id=$3)) ORDER BY d.id`, p.User, dataID, sid)
		if e != nil {
			return e
		}
		targets := []string{}
		owners := map[string]string{}
		for rows.Next() {
			var d, owner string
			if e = rows.Scan(&d, &owner); e != nil {
				rows.Close()
				return e
			}
			targets = append(targets, d)
			owners[d] = owner
		}
		rows.Close()
		if e = rows.Err(); e != nil {
			return e
		}
		if len(targets) > 0 {
			dispatch = "queued"
		}
		for _, d := range targets {
			if _, e = tx.Exec(ctx, "UPDATE outbox SET status='superseded',updated_at=now() WHERE device_id=$1 AND kind='widget' AND resource_id=$2 AND status IN ('queued','retry','blocked')", d, dataID); e != nil {
				return e
			}
			if _, e = tx.Exec(ctx, "INSERT INTO outbox(id,user_id,device_id,kind,resource_id,payload,expires_at) VALUES($1,$2,$3,'widget',$4,$5,now()+interval '1 hour')", id("job_"), owners[d], d, dataID, canonical(map[string]any{"aps": map[string]bool{"content-changed": true}})); e != nil {
				return e
			}
		}
	}
	response := map[string]any{"data": map[string]any{"data_id": dataID, "revision": strconv.FormatInt(rev, 10), "received_at": stamp(*received), "status": "stored", "dispatch_status": dispatch}}
	if e = idemSave(ctx, tx, p, op, key, requestHash, status, response); e != nil {
		return e
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	w.Header().Set("ETag", stateETag(sid, strconv.FormatInt(rev, 10)))
	write(w, status, response)
	return nil
}
func (a *App) snapshot(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web", "device", "read")
	if e != nil {
		return e
	}
	if p.Kind == "web" && r.URL.Query().Get("device_id") != "" {
		p, e = a.webDevice(r, p, r.URL.Query().Get("device_id"))
		if e != nil {
			return e
		}
	}
	dataID := r.PathValue("data_id")
	if p.Kind != "web" {
		if e = a.activeDevice(r.Context(), p); e != nil {
			return e
		}
	}
	if p.Kind == "read" {
		var allowed bool
		e = a.db.QueryRow(r.Context(), "SELECT subscriptions ? $1 FROM devices WHERE id=$2", dataID, p.Device).Scan(&allowed)
		if e != nil {
			return e
		}
		if !allowed {
			return notfound()
		}
	}
	var sid, revision string
	var t time.Time
	var state []byte
	e = a.db.QueryRow(r.Context(), "SELECT id,revision::text,received_at,state FROM streams WHERE user_id=$1 AND data_id=$2 AND state IS NOT NULL", p.User, dataID).Scan(&sid, &revision, &t, &state)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	etag := stateETag(sid, revision)
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, no-cache, no-transform")
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(304)
		return nil
	}
	ok(w, map[string]any{"stream_id": sid, "data_id": dataID, "revision": revision, "received_at": stamp(t), "state": json.RawMessage(state)})
	return nil
}
