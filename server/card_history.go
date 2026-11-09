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

type HistoryRule struct {
	Field       string   `json:"field"`
	Key         string   `json:"series_key"`
	Interval    int64    `json:"interval_seconds"`
	Retention   int      `json:"retention_hours"`
	Limit       int      `json:"limit"`
	StatusField string   `json:"status_field,omitempty"`
	Accepted    []string `json:"accepted_statuses,omitempty"`
}

func validateHistory(rules []HistoryRule, state State) error {
	if len(rules) > 4 {
		return bad("history_limit", "每源最多4组历史序列。")
	}
	count := len(state.Series) + len(rules)
	if state.Items != nil {
		for _, item := range *state.Items {
			count += len(item.Series)
		}
	}
	if count > 4 {
		return bad("history_series_limit", "历史规则与已有序列合计最多4组，请减少规则或已有序列。")
	}
	seen := map[string]bool{}
	for _, r := range rules {
		key := strings.TrimPrefix(r.Field, "fields.")
		if !strings.HasPrefix(r.Field, "fields.") || !fieldKey.MatchString(key) || !fieldKey.MatchString(r.Key) || seen[r.Key] || r.Interval < 60 || r.Interval > 86400 || r.Retention < 1 || r.Retention > 168 || r.Limit < 2 || r.Limit > 60 {
			return bad("invalid_history", "历史配置须使用根数值字段、唯一序列名、60至86400秒间隔、1至168小时保留和2至60个点。")
		}
		seen[r.Key] = true
		if r.StatusField != "" && (!strings.HasPrefix(r.StatusField, "fields.") || !fieldKey.MatchString(strings.TrimPrefix(r.StatusField, "fields.")) || len(r.Accepted) < 1 || len(r.Accepted) > 16) {
			return bad("invalid_history_status", "状态过滤需填写字段与1至16个有效状态。")
		}
		if r.StatusField == "" && len(r.Accepted) > 0 {
			return bad("invalid_history_status", "有效状态须配合状态字段。")
		}
		for _, v := range r.Accepted {
			if len(v) < 1 || len(v) > 120 {
				return bad("invalid_history_status", "有效状态无效。")
			}
		}
		if state.Fields != nil {
			if f, ok := (*state.Fields)[key]; ok && !contains([]string{"decimal", "integer", "percent"}, f.Type) {
				return bad("history_type", "历史积累只能读取数值字段。")
			}
		}
		if _, ok := state.Series[r.Key]; ok {
			return conflict("history_series_conflict", "上游已提供同名序列，请换一个历史序列名。")
		}
	}
	return nil
}
func buildHistory(rules []HistoryRule, samples map[string][]Point, state State, now time.Time) (map[string][]Point, map[string]Series) {
	output := map[string][]Point{}
	series := map[string]Series{}
	t, _ := utc(state.Source)
	for _, r := range rules {
		cutoff := now.Add(-time.Duration(r.Retention) * time.Hour)
		points := []Point{}
		for _, p := range samples[r.Key] {
			pt, e := utc(p.T)
			if e == nil && !pt.Before(cutoff) {
				points = append(points, p)
			}
		}
		var field Field
		if state.Fields != nil {
			field = (*state.Fields)[strings.TrimPrefix(r.Field, "fields.")]
		}
		validStatus := true
		if r.StatusField != "" {
			var v string
			if state.Fields != nil {
				f := (*state.Fields)[strings.TrimPrefix(r.StatusField, "fields.")]
				_ = json.Unmarshal(f.Value, &v)
			}
			validStatus = contains(r.Accepted, v)
		}
		var value string
		e := json.Unmarshal(field.Value, &value)
		_, numberError := decimal(value, false)
		if e == nil && numberError == nil && contains([]string{"decimal", "integer", "percent"}, field.Type) && validStatus && !t.Before(cutoff) && !t.After(now.Add(5*time.Minute)) {
			eligible := len(points) == 0
			if len(points) > 0 {
				last, _ := utc(points[len(points)-1].T)
				eligible = t.Sub(last) >= time.Duration(r.Interval)*time.Second
			}
			if eligible {
				v := value
				points = append(points, Point{T: state.Source, Value: &v})
			}
		}
		if len(points) > r.Limit {
			points = points[len(points)-r.Limit:]
		}
		output[r.Key] = points
		series[r.Key] = Series{Type: "line", Label: field.Label, Unit: field.Unit, Interval: r.Interval, Points: points}
	}
	return output, series
}
func accumulateHistory(ctx context.Context, tx pgx.Tx, stream string, state State, original []byte) ([]byte, error) {
	var source string
	var rulesRaw, samplesRaw []byte
	e := tx.QueryRow(ctx, `SELECT h.source_id,h.rules,h.samples FROM card_source_history h JOIN card_sources c ON c.id=h.source_id WHERE c.stream_id=$1 FOR UPDATE OF h`, stream).Scan(&source, &rulesRaw, &samplesRaw)
	if e == pgx.ErrNoRows {
		return original, nil
	}
	if e != nil {
		return nil, e
	}
	var rules []HistoryRule
	var samples map[string][]Point
	if e = json.Unmarshal(rulesRaw, &rules); e != nil {
		return nil, e
	}
	if e = json.Unmarshal(samplesRaw, &samples); e != nil {
		return nil, e
	}
	if len(rules) == 0 {
		return original, nil
	}
	if e = validateHistory(rules, state); e != nil {
		return nil, e
	}
	next, series := buildHistory(rules, samples, state, time.Now().UTC())
	if state.Series == nil {
		state.Series = map[string]Series{}
	}
	for key, s := range series {
		state.Series[key] = s
	}
	raw := canonical(state)
	if _, e = validateState(raw); e != nil {
		return nil, e
	}
	_, e = tx.Exec(ctx, "UPDATE card_source_history SET samples=$2 WHERE source_id=$1", source, canonical(next))
	return raw, e
}
func (a *App) sourceHistory(w http.ResponseWriter, r *http.Request) error {
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
	var stream string
	var stateRaw []byte
	e = tx.QueryRow(ctx, `SELECT s.id,s.state FROM card_sources c JOIN streams s ON s.id=c.stream_id WHERE c.id=$1 AND c.user_id=$2 FOR UPDATE OF s`, r.PathValue("id"), p.User).Scan(&stream, &stateRaw)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	var revision int64
	rulesRaw := []byte("[]")
	samplesRaw := []byte("{}")
	e = tx.QueryRow(ctx, "SELECT revision,rules,samples FROM card_source_history WHERE source_id=$1", r.PathValue("id")).Scan(&revision, &rulesRaw, &samplesRaw)
	if e != nil && e != pgx.ErrNoRows {
		return e
	}
	etag := `"history-` + strconv.FormatInt(revision, 10) + `"`
	if r.Method == "PUT" {
		if r.Header.Get("If-Match") != etag {
			return APIError{412, "history_conflict", "历史配置已变化，请重新读取。"}
		}
		var b struct {
			Rules []HistoryRule `json:"rules"`
		}
		if e = decode(r, &b); e != nil {
			return e
		}
		if b.Rules == nil {
			b.Rules = []HistoryRule{}
		}
		var state State
		_ = json.Unmarshal(stateRaw, &state)
		var previous []HistoryRule
		_ = json.Unmarshal(rulesRaw, &previous)
		// Remove only our known generated series for collision checks; upstream cannot write these keys while accumulation is enabled.
		for _, old := range previous {
			delete(state.Series, old.Key)
		}
		if e = validateHistory(b.Rules, state); e != nil {
			return e
		}
		var samples map[string][]Point
		_ = json.Unmarshal(samplesRaw, &samples)
		next := map[string][]Point{}
		for _, rule := range b.Rules {
			for _, old := range previous {
				if string(canonical(rule)) == string(canonical(old)) {
					next[rule.Key] = samples[rule.Key]
				}
			}
		}
		revision++
		rulesRaw = canonical(b.Rules)
		samplesRaw = canonical(next)
		_, e = tx.Exec(ctx, `INSERT INTO card_source_history(source_id,revision,rules,samples) VALUES($1,$2,$3,$4) ON CONFLICT(source_id) DO UPDATE SET revision=excluded.revision,rules=excluded.rules,samples=excluded.samples`, r.PathValue("id"), revision, rulesRaw, samplesRaw)
		if e != nil {
			return e
		}
		etag = `"history-` + strconv.FormatInt(revision, 10) + `"`
	}
	if e = tx.Commit(ctx); e != nil {
		return e
	}
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "no-store")
	ok(w, map[string]any{"revision": strconv.FormatInt(revision, 10), "rules": json.RawMessage(rulesRaw), "samples": json.RawMessage(samplesRaw), "max_points_per_source": 240})
	return nil
}

func (a *App) pruneHistory(ctx context.Context) error {
	// One SQL statement retains only points within each configured rule's wall-clock retention.
	_, e := a.db.Exec(ctx, `UPDATE card_source_history h SET samples=coalesce((SELECT jsonb_object_agg(r->>'series_key',coalesce((SELECT jsonb_agg(p ORDER BY p->>'t') FROM jsonb_array_elements(coalesce(h.samples->(r->>'series_key'),'[]'::jsonb)) p WHERE (p->>'t')::timestamptz>=now()-((r->>'retention_hours')::int)*interval '1 hour'),'[]'::jsonb)) FROM jsonb_array_elements(h.rules) r),'{}'::jsonb)`)
	return e
}
