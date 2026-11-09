package main

import (
	"context"
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

func v3Design() CardDesign {
	old := LayoutNode{ID: "root", Type: "column", Children: []LayoutNode{{ID: "value", Type: "number", Bind: "fields.progress"}}}
	n := old
	n.Children = []LayoutNode{{ID: "value", Type: "number", Bind: "fields.progress", Prefix: "$", Colors: &ColorPair{Light: "#153047", Dark: "#E6EDF3"}}, {ID: "icon", Type: "icon", Symbol: "sf:server.rack"}, {ID: "trend", Type: "sparkline", Bind: "series.history"}}
	return CardDesign{Version: 3, Name: "Test", Family: "medium", Layout: n, Fallback: &CardFallback{Layout: old}}
}
func TestV3ProjectionValidation(t *testing.T) {
	d := v3Design()
	if _, e := validateDesign(canonical(d)); e != nil {
		t.Fatal(e)
	}
	for _, schema := range []int{1, 2, 3} {
		p := projectCard(d, schema)
		if p.Version != schema {
			t.Fatal("wrong representation")
		}
		if _, e := validateDesign(canonical(p)); e != nil {
			t.Fatal(e)
		}
	}
	for _, mutate := range []func(*CardDesign){func(d *CardDesign) { d.Fallback = nil }, func(d *CardDesign) { d.Fallback.Layout.Children[0].Prefix = "bad" }, func(d *CardDesign) { d.Layout.Children[1].ImageURL = "https://127.0.0.1/a.png" }, func(d *CardDesign) { d.Layout.Children[2].Height = 81 }, func(d *CardDesign) { d.Layout.Children[0].States = map[string]NodeStateStyle{"bad": {}} }} {
		d := v3Design()
		mutate(&d)
		if _, e := validateDesign(canonical(d)); e == nil {
			t.Fatal("invalid v3 accepted")
		}
	}
	d.Version = 2
	d.Fallback = nil
	if _, e := validateDesign(canonical(d)); e == nil {
		t.Fatal("legacy accepted new attributes")
	}
	if _, e := validateDesign(append(canonical(v3Design()), []byte(` {}`)...)); e == nil {
		t.Fatal("trailing JSON accepted")
	}
}
func TestOptionalBindingDoesNotSkipChildren(t *testing.T) {
	d := v3Design()
	d.Layout.Bind = "fields.absent"
	d.Layout.HideIfEmpty = true
	d.Layout.Children[0].Bind = "fields.bad"
	if e := validateDesignBindings(d, canonical(goodState())); e == nil {
		t.Fatal("child binding bypassed")
	}
}
func TestHistoryZeroNullGapRetention(t *testing.T) {
	rule := HistoryRule{Field: "fields.rate", Key: "rate_history", Interval: 60, Retention: 1, Limit: 2, StatusField: "fields.status", Accepted: []string{"ok"}}
	now := time.Now().UTC()
	fields := map[string]Field{"rate": {Type: "decimal", Value: json.RawMessage(`"0"`)}, "status": {Type: "text", Value: json.RawMessage(`"ok"`)}}
	s := State{Version: 1, Source: stamp(now.Add(-5 * time.Minute)), Fields: &fields}
	samples, series := buildHistory([]HistoryRule{rule}, nil, s, now)
	if len(series[rule.Key].Points) != 1 || *samples[rule.Key][0].Value != "0" {
		t.Fatal("zero lost")
	}
	fields["rate"] = Field{Type: "decimal", Value: json.RawMessage(`null`)}
	s.Source = stamp(now.Add(-4 * time.Minute))
	samples, _ = buildHistory([]HistoryRule{rule}, samples, s, now)
	if len(samples[rule.Key]) != 1 {
		t.Fatal("null generated sample")
	}
	fields["rate"] = Field{Type: "decimal", Value: json.RawMessage(`"3.2"`)}
	fields["status"] = Field{Type: "text", Value: json.RawMessage(`"warming"`)}
	samples, _ = buildHistory([]HistoryRule{rule}, samples, s, now)
	if len(samples[rule.Key]) != 1 {
		t.Fatal("warming generated sample")
	}
	fields["status"] = Field{Type: "text", Value: json.RawMessage(`"ok"`)}
	s.Source = stamp(now)
	samples, _ = buildHistory([]HistoryRule{rule}, samples, s, now)
	if len(samples[rule.Key]) != 2 {
		t.Fatal("valid sample lost")
	}
	again, _ := buildHistory([]HistoryRule{rule}, samples, s, now)
	if len(again[rule.Key]) != 2 {
		t.Fatal("duplicate sample")
	}
	s.Source = stamp(now.Add(-10 * time.Minute))
	again, _ = buildHistory([]HistoryRule{rule}, samples, s, now)
	if len(again[rule.Key]) != 2 {
		t.Fatal("old report generated sample")
	}
	again, _ = buildHistory([]HistoryRule{rule}, samples, s, now.Add(2*time.Hour))
	if len(again[rule.Key]) != 0 {
		t.Fatal("retention not applied")
	}
}
func TestHistoryScopeAndTransactionalAccumulation(t *testing.T) {
	f := setup(t)
	source := result(t, f.request("POST", "/v1/card-sources", map[string]any{"name": "History test", "mode": "push"}, "web", nil), 200)
	path := "/v1/card-sources/" + source["id"].(string)
	rule := HistoryRule{Field: "fields.progress", Key: "progress_history", Interval: 60, Retention: 24, Limit: 60}
	result(t, f.request("PUT", path+"/history", map[string]any{"rules": []HistoryRule{rule}}, "web", map[string]string{"If-Match": `"history-0"`}), 200)
	result(t, f.request("PUT", path+"/history", map[string]any{"rules": []HistoryRule{rule}}, "web", map[string]string{"If-Match": `"history-0"`}), 412)
	result(t, f.request("GET", path+"/history", nil, "", nil), 401)
	state := goodState()
	state["source_updated_at"] = stamp(time.Now().UTC())
	result(t, f.request("PUT", path+"/data", state, "web", nil), 202)
	result(t, f.request("PUT", path+"/data", state, "web", nil), 200)
	var raw []byte
	if e := f.a.db.QueryRow(context.Background(), "SELECT samples FROM card_source_history WHERE source_id=$1", source["id"]).Scan(&raw); e != nil {
		t.Fatal(e)
	}
	var samples map[string][]Point
	_ = json.Unmarshal(raw, &samples)
	if len(samples[rule.Key]) != 1 {
		t.Fatal("replay accumulated a second point")
	}
	var streamRaw []byte
	_ = f.a.db.QueryRow(context.Background(), "SELECT state FROM streams WHERE data_id=$1", source["data_id"]).Scan(&streamRaw)
	var stored State
	_ = json.Unmarshal(streamRaw, &stored)
	if len(stored.Series[rule.Key].Points) != 1 {
		t.Fatal("history missing from snapshot")
	}
	if _, e := validateState(streamRaw); e != nil {
		t.Fatal(e)
	}
	state["source_updated_at"] = stamp(time.Now().UTC().Add(time.Minute))
	state["series"] = map[string]Series{rule.Key: {Type: "line", Interval: 60, Points: []Point{}}}
	result(t, f.request("PUT", path+"/data", state, "web", nil), 409)
	var unchanged []byte
	_ = f.a.db.QueryRow(context.Background(), "SELECT samples FROM card_source_history WHERE source_id=$1", source["id"]).Scan(&unchanged)
	if !strings.EqualFold(string(raw), string(unchanged)) {
		t.Fatal("rejected write changed history")
	}
}
func TestHistoryPreservesNonOptInPayload(t *testing.T) {
	f := setup(t)
	s := f.cardSource(t)
	raw := []byte(`{"schema_version":1,"source_updated_at":"2026-11-09T00:00:00Z","fields":{"n":{"type":"text","value":"","label":"","unit":""}}}`)
	state, e := validateState(raw)
	if e != nil {
		t.Fatal(e)
	}
	tx, e := f.a.db.Begin(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(context.Background())
	var sid string
	_ = f.a.db.QueryRow(context.Background(), "SELECT id FROM streams WHERE data_id=$1", s["data_id"]).Scan(&sid)
	output, e := accumulateHistory(context.Background(), tx, sid, state, raw)
	if e != nil || string(raw) != string(output) {
		t.Fatal("non-opt-in state changed")
	}
}

func TestV3SubscriptionRepresentations(t *testing.T) {
	f := setup(t)
	s := result(t, f.request("POST", "/v1/card-sources", map[string]any{"name": "Compatibility", "mode": "push"}, "web", nil), 200)
	state := goodState()
	result(t, f.request("PUT", "/v1/card-sources/"+s["id"].(string)+"/data", state, "web", nil), 202)
	d := v3Design()
	card := result(t, f.request("POST", "/v1/cards", map[string]any{"source_id": s["id"], "design": d}, "web", nil), 200)
	cid := card["id"].(string)
	result(t, f.request("POST", "/v1/cards/"+cid+"/publish", map[string]any{}, "web", map[string]string{"If-Match": `"draft-1"`}), 200)
	device := f.automatic(t, "Compat")
	code := result(t, f.request("POST", "/v1/cards/"+cid+"/codes", map[string]any{}, "web", nil), 200)
	result(t, f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, device["device_token"].(string), nil), 200)
	export := map[string]any{}
	for _, schema := range []int{1, 2, 3} {
		headers := map[string]string{}
		if schema > 1 {
			headers["X-Vao-Card-Schema"] = strconv.Itoa(schema)
		}
		response := f.request("GET", "/v1/card-subscriptions/"+cid, nil, device["read_token"].(string), headers)
		data := result(t, response, 200)
		var actual CardDesign
		_ = json.Unmarshal(canonical(data["design"]), &actual)
		if actual.Version != schema || data["revision"] != "1" {
			t.Fatal("wrong negotiated representation")
		}
		if schema < 3 && actual.Fallback != nil {
			t.Fatal("fallback leaked")
		}
		if _, e := validateDesign(canonical(actual)); e != nil {
			t.Fatal(e)
		}
		export[strconv.Itoa(schema)] = data
	}
	if path := os.Getenv("VAO_TEST_COMPAT_EXPORT"); path != "" {
		if e := os.WriteFile(path, canonical(export), 0600); e != nil {
			t.Fatal(e)
		}
	}
	if e := f.a.pruneHistory(context.Background()); e != nil {
		t.Fatal(e)
	}
}

func TestNodeImageURLBoundaries(t *testing.T) {
	for _, raw := range []string{"http://example.com/icon.png", "https://u:p@example.com/icon.png", "https://127.1/x", "https://10.example.com/x", "https://192.168.example.com/x", "https://a.1.2.3.4/x", "https://example.com:444/x", "https://localhost/x", "https://[::1]/x", "https://example.com/x#fragment", "https://example.com/x#"} {
		if validNodeImage(raw) {
			t.Fatal("native-incompatible URL accepted")
		}
	}
	if !validNodeImage("https://images.example.com/icon.png") {
		t.Fatal("public HTTPS URL rejected")
	}
}

func TestHistoryConfigurationReservesSnapshotCapacity(t *testing.T) {
	f := setup(t)
	source := f.cardSource(t)
	path := "/v1/card-sources/" + source["id"].(string)
	state := goodState()
	state["series"] = map[string]Series{"a": {Type: "line", Interval: 60, Points: []Point{}}, "b": {Type: "line", Interval: 60, Points: []Point{}}, "c": {Type: "line", Interval: 60, Points: []Point{}}}
	result(t, f.request("PUT", path+"/data", state, "web", nil), 202)
	rules := []HistoryRule{{Field: "fields.progress", Key: "h1", Interval: 60, Retention: 24, Limit: 60}, {Field: "fields.progress", Key: "h2", Interval: 60, Retention: 24, Limit: 60}}
	result(t, f.request("PUT", path+"/history", map[string]any{"rules": rules}, "web", map[string]string{"If-Match": `"history-0"`}), 422)
	current := result(t, f.request("GET", path+"/history", nil, "web", nil), 200)
	if current["revision"] != "0" {
		t.Fatal("invalid configuration was saved")
	}
	result(t, f.request("PUT", path+"/history", map[string]any{"rules": rules[:1]}, "web", map[string]string{"If-Match": `"history-0"`}), 200)
}
