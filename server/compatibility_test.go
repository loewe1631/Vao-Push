package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestLayoutVariantsLegacyProjection(t *testing.T) {
	f := setup(t)
	d := f.automatic(t, "Legacy")
	s := f.cardSource(t)
	design := sampleDesign()
	design["schema_version"] = 2
	design["layouts"] = map[string]any{"small": map[string]any{"id": "quotes", "type": "text", "text": "compact"}, "large": sampleDesign()["layout"]}
	card := result(t, f.request("POST", "/v1/cards", map[string]any{"source_id": s["id"], "design": design}, "web", nil), 200)
	cid := card["id"].(string)
	result(t, f.request("POST", "/v1/cards/"+cid+"/publish", map[string]any{}, "web", map[string]string{"If-Match": `"draft-1"`}), 200)
	code := result(t, f.request("POST", "/v1/cards/"+cid+"/codes", map[string]any{}, "web", nil), 200)
	result(t, f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, d["device_token"].(string), nil), 200)
	path := "/v1/card-subscriptions/" + cid
	old := result(t, f.request("GET", path, nil, d["device_token"].(string), nil), 200)
	new := result(t, f.request("GET", path, nil, d["read_token"].(string), map[string]string{"X-Vao-Card-Schema": "2"}), 200)
	legacy := old["design"].(map[string]any)
	if legacy["schema_version"] != float64(1) || legacy["layouts"] != nil {
		t.Fatal("legacy schema contaminated")
	}
	if old["revision"] != new["revision"] || new["design"].(map[string]any)["layouts"] == nil {
		t.Fatal("variant publication not atomic")
	}
	if _, e := validateDesign(canonical(legacy)); e != nil {
		t.Fatal("legacy projection invalid", e)
	}
	again := result(t, f.request("GET", path, nil, d["read_token"].(string), nil), 200)
	if string(canonical(again["design"])) != string(canonical(legacy)) {
		t.Fatal("another client changed representation")
	}
}
func TestVariantsValidateEveryTree(t *testing.T) {
	d := sampleDesign()
	d["schema_version"] = 2
	d["layouts"] = map[string]any{"small": map[string]any{"id": "quotes", "type": "text", "text": "valid"}}
	if _, e := validateDesign(canonical(d)); e != nil {
		t.Fatal(e)
	}
	d["layouts"] = map[string]any{"small": map[string]any{"id": "quotes", "type": "script", "text": "bad"}}
	if _, e := validateDesign(canonical(d)); e == nil {
		t.Fatal("bad non-default tree accepted")
	}
	d["layouts"] = map[string]any{"huge": sampleDesign()["layout"]}
	if _, e := validateDesign(canonical(d)); e == nil {
		t.Fatal("unknown family")
	}
	d["schema_version"] = 1
	d["layouts"] = map[string]any{"small": sampleDesign()["layout"]}
	if _, e := validateDesign(canonical(d)); e == nil {
		t.Fatal("v1 extension accepted")
	}
}
func TestNamedRouteIsolationIdempotencyAndRemoval(t *testing.T) {
	f := setup(t)
	a := f.automatic(t, "A")
	b := f.automatic(t, "B")
	legacy := f.saveRoute(t, []string{a["binding_id"].(string)})
	create := func(name string, device any) map[string]any {
		return result(t, f.request("POST", "/v1/message-routes", map[string]any{"name": name, "device_ids": []any{device}}, "web", nil), 200)
	}
	x, y := create("X", a["binding_id"]), create("Y", b["binding_id"])
	if result(t, f.request("GET", "/v1/message-routes", nil, "web", nil), 200)["routes"] == nil {
		t.Fatal("missing routes")
	}
	send := func(route map[string]any) map[string]any {
		return result(t, f.request("POST", strings.TrimPrefix(route["message_url"].(string), f.a.cfg.PublicURL), map[string]any{"body": "same body"}, "", map[string]string{"Idempotency-Key": "same-retry"}), 202)
	}
	first, second := send(x), send(y)
	if first["message_id"] == second["message_id"] {
		t.Fatal("idempotency leaked across routes")
	}
	x2 := result(t, f.request("PUT", "/v1/message-routes/"+x["id"].(string), map[string]any{"name": "X renamed", "device_ids": []any{b["binding_id"]}}, "web", map[string]string{"If-Match": `"route-1"`}), 200)
	if x2["message_url"] != x["message_url"] || send(x)["message_id"] != first["message_id"] {
		t.Fatal("changed frozen retry or stable URL")
	}
	if f.request("DELETE", "/v1/message-routes/"+x["id"].(string), nil, "web", map[string]string{"If-Match": `"route-1"`}).Code != 412 {
		t.Fatal("stale deletion accepted")
	}
	result(t, f.request("DELETE", "/v1/message-routes/"+x["id"].(string), nil, "web", map[string]string{"If-Match": `"route-2"`}), 200)
	if f.request("POST", strings.TrimPrefix(x["message_url"].(string), f.a.cfg.PublicURL), map[string]any{"body": "after delete"}, "", nil).Code != 401 {
		t.Fatal("deleted URL remains usable")
	}
	if result(t, f.request("GET", "/v1/message-route", nil, "web", nil), 200)["message_url"] != legacy["message_url"] {
		t.Fatal("default changed")
	}
	var n int
	if e := f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM messages").Scan(&n); e != nil || n != 2 {
		t.Fatal("history changed or retries duplicated", n, e)
	}
}
func TestOptionalIconKeepsLegacyEnvelope(t *testing.T) {
	f := setup(t)
	d := f.automatic(t, "Legacy")
	body := messageBody(d["binding_id"].(string))
	body["icon"] = "https://example.com/sol.png"
	sent := result(t, f.request("POST", "/v1/messages", body, "web", nil), 202)
	page := result(t, f.request("GET", "/v1/device/sync", nil, d["device_token"].(string), nil), 200)
	m := page["messages"].([]any)[0].(map[string]any)
	if m["icon"] != body["icon"] || m["body"] != body["body"] {
		t.Fatal("sync lost legacy text")
	}
	var raw []byte
	if e := f.a.db.QueryRow(context.Background(), "SELECT payload FROM outbox WHERE resource_id=$1", sent["message_id"]).Scan(&raw); e != nil {
		t.Fatal(e)
	}
	var envelope map[string]any
	json.Unmarshal(raw, &envelope)
	push := envelope["vao_push"].(map[string]any)
	if push["version"] != float64(1) || push["kind"] != "message" || push["icon"] != body["icon"] {
		t.Fatal("legacy envelope changed")
	}
	body["icon"] = "http://unsafe.example/icon.png"
	if f.request("POST", "/v1/messages", body, "web", nil).Code != 422 {
		t.Fatal("insecure icon accepted")
	}
}
func TestSystemUpdateAdminOnlyAndUnconfigured(t *testing.T) {
	f := setup(t)
	d := f.automatic(t, "Device")
	if f.request("POST", "/v1/system/update/install", map[string]any{}, d["device_token"].(string), nil).Code != 403 {
		t.Fatal("device can install")
	}
	state := result(t, f.request("GET", "/v1/system/update", nil, "web", nil), 200)
	if state["configured"] != false {
		t.Fatal("unconfigured agent advertised")
	}
}

func TestHiddenVariantCannotEscapeBindingValidation(t *testing.T) {
	f := setup(t)
	s := f.cardSource(t)
	d := sampleDesign()
	d["schema_version"] = 2
	d["layouts"] = map[string]any{"large": map[string]any{"id": "missing", "type": "text", "bind": "fields.nonexistent"}}
	card := result(t, f.request("POST", "/v1/cards", map[string]any{"source_id": s["id"], "design": d}, "web", nil), 200)
	if f.request("POST", "/v1/cards/"+card["id"].(string)+"/publish", map[string]any{}, "web", map[string]string{"If-Match": `"draft-1"`}).Code != 422 {
		t.Fatal("unmatched non-default binding was published")
	}
}
