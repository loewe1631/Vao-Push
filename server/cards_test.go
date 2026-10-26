package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func sampleDesign() map[string]any {
	return map[string]any{"schema_version": 1, "name": "行情卡片", "family": "medium", "layout": map[string]any{"id": "quotes", "type": "list", "source": "items", "limit": 3, "row": map[string]any{"id": "row", "type": "row", "children": []any{map[string]any{"id": "symbol", "type": "text", "bind": "fields.symbol"}, map[string]any{"id": "price", "type": "number", "bind": "fields.price", "decimals": 2}, map[string]any{"id": "change", "type": "badge", "bind": "fields.change", "color_rule": "signed"}}}}}
}
func (f fixture) cardSource(t *testing.T) map[string]any {
	t.Helper()
	source := result(t, f.request("POST", "/v1/card-sources", map[string]any{"name": "共享行情", "mode": "push"}, "web", nil), 200)
	body := map[string]any{"items": []any{map[string]any{"item_id": "BTCUSDT", "fields": map[string]any{"symbol": map[string]any{"type": "text", "value": "BTC/USDT"}, "price": map[string]any{"type": "decimal", "value": "80970.01"}, "change": map[string]any{"type": "percent", "value": "-0.99"}}}}}
	result(t, f.request("PUT", strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL), body, "", nil), 202)
	return source
}
func (f fixture) publishedCard(t *testing.T, source map[string]any) map[string]any {
	t.Helper()
	card := result(t, f.request("POST", "/v1/cards", map[string]any{"source_id": source["id"], "design": sampleDesign()}, "web", nil), 200)
	result(t, f.request("POST", "/v1/cards/"+card["id"].(string)+"/publish", map[string]any{}, "web", map[string]string{"If-Match": `"draft-1"`}), 200)
	return card
}
func TestPublishedCardsSubscriptionsAndIsolation(t *testing.T) {
	f := setup(t)
	source := f.cardSource(t)
	card := f.publishedCard(t, source)
	cid := card["id"].(string)
	a, b := f.automatic(t, "订阅A"), f.automatic(t, "未订阅B")
	legacy := f.paired(t)
	legacyPage := result(t, f.request("GET", "/v1/device/sync", nil, legacy["device_token"].(string), nil), 200)
	if len(legacyPage["snapshots"].([]any)) != 0 {
		t.Fatal("legacy account inherited private card source")
	}
	if f.request("GET", "/v1/widgets/"+source["data_id"].(string)+"/state", nil, legacy["device_token"].(string), nil).Code != 404 {
		t.Fatal("legacy account read raw shared source")
	}
	code := result(t, f.request("POST", "/v1/cards/"+cid+"/codes", map[string]any{}, "web", nil), 200)
	for i := 0; i < 2; i++ {
		result(t, f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, a["device_token"].(string), nil), 200)
	}
	if result(t, f.request("GET", "/v1/card-subscriptions/"+cid, nil, a["read_token"].(string), nil), 200)["revision"] != "1" {
		t.Fatal("published card missing")
	}
	if f.request("GET", "/v1/card-subscriptions/"+cid, nil, b["read_token"].(string), nil).Code != 404 {
		t.Fatal("unsubscribed device read private card")
	}
	if f.request("GET", "/v1/widgets/"+source["data_id"].(string)+"/state", nil, a["read_token"].(string), nil).Code != 404 {
		t.Fatal("card grant escaped to raw source")
	}
	for _, path := range []string{"/v1/card-sources", "/v1/cards"} {
		if f.request("GET", path, nil, a["device_token"].(string), nil).Code != 403 {
			t.Fatal("device read author controls")
		}
	}
	if f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, a["read_token"].(string), nil).Code != 403 {
		t.Fatal("widget credential added a subscription")
	}
	draft := sampleDesign()
	draft["name"] = "新版行情"
	result(t, f.request("PUT", "/v1/cards/"+cid, map[string]any{"design": draft}, "web", map[string]string{"If-Match": `"draft-1"`}), 200)
	current := result(t, f.request("GET", "/v1/card-subscriptions/"+cid, nil, a["read_token"].(string), nil), 200)
	if current["design"].(map[string]any)["name"] != "行情卡片" {
		t.Fatal("unpublished draft leaked")
	}
	if f.request("POST", "/v1/cards/"+cid+"/publish", map[string]any{}, "web", map[string]string{"If-Match": `"draft-1"`}).Code != 412 {
		t.Fatal("stale publish succeeded")
	}
	result(t, f.request("POST", "/v1/cards/"+cid+"/publish", map[string]any{}, "web", map[string]string{"If-Match": `"draft-2"`}), 200)
	current = result(t, f.request("GET", "/v1/card-subscriptions/"+cid, nil, a["read_token"].(string), nil), 200)
	if current["revision"] != "2" || current["design"].(map[string]any)["name"] != "新版行情" {
		t.Fatal("published revision not visible")
	}
	// Shared source writes retain each subscribing installation's APNs namespace.
	result(t, f.request("PUT", strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL), map[string]any{"fields": map[string]any{"progress": map[string]any{"type": "percent", "value": "79"}}}, "", nil), 202)
	var n int
	var user string
	if e := f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM outbox WHERE device_id=$1 AND kind='widget'", a["binding_id"]).Scan(&n); e != nil || n < 2 {
		t.Fatal("card updates not queued")
	}
	if e := f.a.db.QueryRow(context.Background(), "SELECT user_id FROM outbox WHERE device_id=$1 ORDER BY created_at DESC LIMIT 1", a["binding_id"]).Scan(&user); e != nil || user != a["account_id"] {
		t.Fatal("wrong APNs namespace")
	}
	if e := f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM outbox WHERE device_id=$1", b["binding_id"]).Scan(&n); e != nil || n != 0 {
		t.Fatal("unsubscribed device was notified")
	}
	result(t, f.request("DELETE", "/v1/cards/"+cid+"/codes", nil, "web", nil), 200)
	if f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, b["device_token"].(string), nil).Code != 422 {
		t.Fatal("revoked code redeemed")
	}
	result(t, f.request("GET", "/v1/card-subscriptions/"+cid, nil, a["read_token"].(string), nil), 200)
	result(t, f.request("DELETE", "/v1/cards/"+cid+"/subscribers/"+a["binding_id"].(string), nil, "web", nil), 200)
	if f.request("GET", "/v1/card-subscriptions/"+cid, nil, a["read_token"].(string), nil).Code != 404 {
		t.Fatal("revoked subscription still read")
	}
}
func TestCardDesignAndSourceValidation(t *testing.T) {
	f := setup(t)
	for _, url := range []string{"http://example.com/data", "https://127.0.0.1/data", "https://169.254.169.254/", "https://user:pass@example.com/"} {
		if f.request("POST", "/v1/card-sources", map[string]any{"name": "Bad", "mode": "http", "config": map[string]any{"url": url, "fields": []any{map[string]any{"key": "price", "path": "price", "type": "decimal"}}}}, "web", nil).Code != 422 {
			t.Fatal("invalid API address accepted")
		}
	}
	good := sampleDesign()
	raw, _ := json.Marshal(good)
	if _, e := validateDesign(raw); e != nil {
		t.Fatal(e)
	}
	for _, kind := range []string{"webview", "javascript", "html"} {
		good["layout"] = map[string]any{"id": "bad", "type": kind}
		raw, _ = json.Marshal(good)
		if _, e := validateDesign(raw); e == nil {
			t.Fatal("executable layout accepted")
		}
	}
	if _, e := validateDesign([]byte(`{"schema_version":1,"name":"Bad","family":"medium","layout":{"id":"root","type":"text","text":"x","onclick":"evil"}}`)); e == nil {
		t.Fatal("unknown code property accepted")
	}
	cfg := SourceConfig{Fields: []FieldMapping{{Key: "price", Path: "amount", Type: "decimal"}, {Key: "change", Path: "change", Type: "percent"}}}
	state, e := mapSource(cfg, map[string]any{"amount": json.Number("12345678901234567890.12345678"), "change": "-1.25"})
	if e != nil {
		t.Fatal(e)
	}
	if state["fields"].(map[string]any)["price"].(map[string]any)["value"] != "12345678901234567890.12345678" {
		t.Fatal("API decimal lost precision")
	}
	if _, err := mapSource(cfg, map[string]any{"error": "temporary API error"}); err == nil {
		t.Fatal("an API error document erased valid data")
	}
	cfg.ItemIDPath = "symbol"
	empty, err := mapSource(cfg, []any{})
	if err != nil || len(empty["items"].([]any)) != 0 {
		t.Fatal("an explicitly empty API list was not preserved")
	}
	source := f.cardSource(t)
	key := strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL+"/v1/card-data/")
	if f.request("GET", "/v1/card-sources", nil, key, nil).Code != 403 {
		t.Fatal("source write key read source config")
	}
	if f.request("POST", "/v1/push/"+key, map[string]any{"body": "wrong kind"}, "", nil).Code != 403 {
		t.Fatal("source key sent a message")
	}
	if f.request("PUT", "/v1/widgets/other/state", goodState(), key, nil).Code != 404 {
		t.Fatal("source key wrote another data id")
	}
}

func TestCardSourceMigrationAndPrivateSettings(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	source := f.cardSource(t)
	// Reproduce an earlier schema layout, then verify repeatable migration preserves IDs/keys.
	var originalOwner string
	if e := f.a.db.QueryRow(ctx, "SELECT user_id FROM streams WHERE data_id=$1", source["data_id"]).Scan(&originalOwner); e != nil {
		t.Fatal(e)
	}
	if _, e := f.a.db.Exec(ctx, "UPDATE streams SET user_id=$2 WHERE data_id=$1", source["data_id"], f.uid); e != nil {
		t.Fatal(e)
	}
	if _, e := f.a.db.Exec(ctx, "UPDATE credentials SET user_id=$2 WHERE user_id=$1 AND kind='source'", originalOwner, f.uid); e != nil {
		t.Fatal(e)
	}
	if e := f.a.isolateCardSources(ctx); e != nil {
		t.Fatal(e)
	}
	if e := f.a.isolateCardSources(ctx); e != nil {
		t.Fatal(e)
	}
	var after string
	if e := f.a.db.QueryRow(ctx, "SELECT user_id FROM streams WHERE data_id=$1", source["data_id"]).Scan(&after); e != nil || after == f.uid {
		t.Fatal("shared source migration did not isolate ownership")
	}
	result(t, f.request("PUT", strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL), map[string]any{"fields": map[string]any{"progress": map[string]any{"type": "percent", "value": "79"}}}, "", nil), 202)
	httpSource := result(t, f.request("POST", "/v1/card-sources", map[string]any{"name": "API config", "mode": "http", "config": map[string]any{"url": "https://example.com/data", "headers": map[string]string{"Authorization": "Bearer test-only-placeholder"}, "fields": []any{map[string]any{"key": "lastPrice", "path": "data.price", "type": "decimal"}}}}, "web", nil), 200)
	read := result(t, f.request("GET", "/v1/card-sources/"+httpSource["id"].(string), nil, "web", nil), 200)
	if read["headers_configured"] != true || read["config"].(map[string]any)["headers"] != nil {
		t.Fatal("API secret leaked through settings")
	}
	result(t, f.request("PUT", "/v1/card-sources/"+httpSource["id"].(string), map[string]any{"name": "API edited", "interval_seconds": 120, "config": read["config"]}, "web", nil), 200)
	var sealed []byte
	if e := f.a.db.QueryRow(ctx, "SELECT config FROM card_sources WHERE id=$1", httpSource["id"]).Scan(&sealed); e != nil {
		t.Fatal(e)
	}
	raw, e := f.a.unseal(sealed)
	if e != nil {
		t.Fatal(e)
	}
	var cfg SourceConfig
	if json.Unmarshal(raw, &cfg) != nil || cfg.Headers["Authorization"] != "Bearer test-only-placeholder" {
		t.Fatal("empty editor input erased saved auth")
	}
}
