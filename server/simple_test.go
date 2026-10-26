package main

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
)

func (f fixture) automatic(t *testing.T, name string) map[string]any {
	t.Helper()
	return result(t, f.request("POST", "/v1/register", map[string]any{"device_name": name, "platform": "ios", "registration_token": token()}, "", nil), 200)
}

func TestAutomaticRegistrationAndKeyBoundaries(t *testing.T) {
	f := setup(t)
	registration := map[string]any{"device_name": "Auto iPhone", "platform": "ios", "registration_token": token()}
	first := result(t, f.request("POST", "/v1/register", registration, "", nil), 200)
	// Simulate a lost registration response followed by concurrent retries.
	var wg sync.WaitGroup
	ids := make(chan string, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := f.request("POST", "/v1/register", registration, "", nil)
			if w.Code != 200 {
				t.Errorf("registration retry HTTP %d", w.Code)
				return
			}
			ids <- string(w.Body.Bytes())
		}()
	}
	wg.Wait()
	close(ids)
	for raw := range ids {
		if !strings.Contains(raw, first["binding_id"].(string)) {
			t.Fatal("registration created duplicate device")
		}
	}
	second := f.automatic(t, "Second iPhone")
	sk, dt, rt := first["send_key"].(string), first["device_token"].(string), first["read_token"].(string)
	access := result(t, f.request("GET", "/v1/device/access", nil, dt, nil), 200)
	if access["send_key"] != sk {
		t.Fatal("access changed send key")
	}
	result(t, f.request("GET", "/v1/devices/"+first["binding_id"].(string)+"/access", nil, "web", nil), 200)
	for _, path := range []string{"/v1/device/sync", "/v1/device/access", "/v1/widgets/status/state", "/v1/dashboard"} {
		if f.request("GET", path, nil, sk, nil).Code != 403 {
			t.Fatalf("send key read %s", path)
		}
	}
	if f.request("PUT", "/v1/device/registration", map[string]any{"environment": "sandbox", "apns_token": strings.Repeat("ab", 32)}, sk, nil).Code != 403 {
		t.Fatal("send key replaced APNs token")
	}
	if f.request("DELETE", "/v1/device", nil, sk, nil).Code != 403 {
		t.Fatal("send key revoked device")
	}
	if f.request("GET", "/v1/devices/"+second["binding_id"].(string)+"/access", nil, dt, nil).Code != 404 {
		t.Fatal("device obtained another key")
	}
	body := map[string]any{"title": "Simple push", "body": "No target or account setup"}
	m := result(t, f.request("POST", "/v1/push/"+sk, body, "", nil), 202)
	if m["target_count"].(float64) != 1 {
		t.Fatal("unexpected targets")
	}
	page := result(t, f.request("GET", "/v1/device/sync", nil, dt, nil), 200)
	if len(page["messages"].([]any)) != 1 {
		t.Fatal("simple message missing")
	}
	page = result(t, f.request("GET", "/v1/device/sync", nil, second["device_token"].(string), nil), 200)
	if len(page["messages"].([]any)) != 0 {
		t.Fatal("message leaked to other device")
	}
	body["target"] = map[string]any{"device_id": second["binding_id"]}
	if f.request("POST", "/v1/push/"+sk, body, "", nil).Code != 404 {
		t.Fatal("send key targeted another device")
	}
	if f.request("POST", "/v1/push/"+dt, map[string]any{"body": "wrong kind"}, "", nil).Code != 403 {
		t.Fatal("device token accepted as send URL")
	}
	result(t, f.request("POST", "/v1/messages", messageBody(first["binding_id"].(string)), "web", nil), 202)
	// An unrelated administrator session cannot manage this server owner's registrations.
	otherUser, otherSession := id("acct_"), token()
	_, e := f.a.db.Exec(context.Background(), "INSERT INTO users(id,username,password) VALUES($1,'other',$2)", otherUser, []byte{})
	if e != nil {
		t.Fatal(e)
	}
	_, e = f.a.db.Exec(context.Background(), "INSERT INTO sessions(hash,user_id,csrf,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')", hash(otherSession), otherUser, f.csrf)
	if e != nil {
		t.Fatal(e)
	}
	outsider := fixture{f.a, otherUser, otherSession, f.csrf}
	if outsider.request("GET", "/v1/devices/"+first["binding_id"].(string)+"/access", nil, "web", nil).Code != 404 {
		t.Fatal("another administrator accessed key")
	}
	dash := result(t, outsider.request("GET", "/v1/dashboard", nil, "web", nil), 200)
	if len(dash["devices"].([]any)) != 0 {
		t.Fatal("device list leaked")
	}
	result(t, f.request("DELETE", "/v1/devices/"+first["binding_id"].(string), nil, "web", nil), 200)
	for _, auth := range []string{dt, rt, sk} {
		if f.request("GET", "/v1/device/sync", nil, auth, nil).Code != 401 {
			t.Fatal("revoked credential survived")
		}
	}
	if f.request("POST", "/v1/register", registration, "", nil).Code != 401 {
		t.Fatal("revoked installation resumed")
	}
	if f.request("POST", "/v1/push/"+sk, map[string]any{"body": "revoked"}, "", nil).Code != 401 {
		t.Fatal("revoked key wrote")
	}
}

func TestAutomaticStateIsolationAndManualUpdates(t *testing.T) {
	f := setup(t)
	a, b := f.automatic(t, "Phone A"), f.automatic(t, "Phone B")
	path := "/v1/state/" + a["send_key"].(string) + "/status"
	body := map[string]any{"fields": map[string]any{"progress": map[string]any{"type": "percent", "value": "68"}}}
	headers := map[string]string{"Idempotency-Key": "minimal-first"}
	first := result(t, f.request("PUT", path, body, "", headers), 202)
	retry := result(t, f.request("PUT", path, body, "", headers), 202)
	if first["revision"] != retry["revision"] {
		t.Fatal("timestamp default broke retry idempotency")
	}
	result(t, f.request("PUT", "/v1/state/"+b["send_key"].(string)+"/status", goodState(), "", nil), 202)
	for _, device := range []map[string]any{a, b} {
		page := result(t, f.request("GET", "/v1/device/sync", nil, device["device_token"].(string), nil), 200)
		if len(page["snapshots"].([]any)) != 1 {
			t.Fatal("same ID not isolated")
		}
	}
	if f.request("GET", "/v1/widgets/status/state", nil, a["read_token"].(string), nil).Code != 404 {
		t.Fatal("unsubscribed snapshot readable")
	}
	result(t, f.request("PUT", "/v1/device/subscriptions", map[string]any{"data_ids": []string{"status"}}, a["device_token"].(string), nil), 200)
	result(t, f.request("GET", "/v1/widgets/status/state", nil, a["read_token"].(string), nil), 200)
	webPath := "/v1/widgets/status/state?device_id=" + a["binding_id"].(string)
	w := f.request("GET", webPath, nil, "web", nil)
	result(t, w, 200)
	body["fields"].(map[string]any)["progress"] = map[string]any{"type": "percent", "value": "79"}
	result(t, f.request("PUT", webPath, body, "web", map[string]string{"If-Match": w.Header().Get("ETag")}), 202)
	if f.request("PUT", webPath, body, "web", map[string]string{"If-Match": w.Header().Get("ETag")}).Code != 412 {
		t.Fatal("stale Web editor overwrote state")
	}
	if f.request("PUT", webPath, body, "web", map[string]string{"If-None-Match": "*"}).Code != 412 {
		t.Fatal("new editor overwrote existing ID")
	}
	result(t, f.request("PUT", "/v1/widgets/new_id/state?device_id="+a["binding_id"].(string), body, "web", map[string]string{"If-None-Match": "*"}), 202)
	if f.request("PUT", path, json.RawMessage("null"), "", nil).Code != 422 {
		t.Fatal("null state accepted")
	}
	// Invalid input must not leave a partially created data ID.
	if f.request("PUT", "/v1/state/"+a["send_key"].(string)+"/invalid", map[string]any{"fields": map[string]any{"price": map[string]any{"type": "decimal", "value": "oops"}}}, "", nil).Code != 422 {
		t.Fatal("invalid state accepted")
	}
	var n int
	if e := f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM streams WHERE data_id='invalid'").Scan(&n); e != nil || n != 0 {
		t.Fatal("invalid request created stream")
	}
	legacy := f.paired(t)
	before := result(t, f.request("GET", "/v1/device/access", nil, legacy["device_token"].(string), nil), 200)
	after := result(t, f.request("GET", "/v1/device/access", nil, legacy["device_token"].(string), nil), 200)
	if before["send_key"] != after["send_key"] {
		t.Fatal("legacy upgrade changed key")
	}
	result(t, f.request("POST", "/v1/push/"+before["send_key"].(string), map[string]any{"body": "legacy remains usable"}, "", nil), 202)
}

func TestWebBroadcastSnapshotAndIsolation(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	legacy := f.paired(t)
	a, b := f.automatic(t, "Broadcast A"), f.automatic(t, "Broadcast B")
	paused, removed := f.automatic(t, "Paused"), f.automatic(t, "Removed")
	result(t, f.request("PUT", "/v1/device/status", map[string]any{"enabled": false}, paused["device_token"].(string), nil), 200)
	result(t, f.request("DELETE", "/v1/device", nil, removed["device_token"].(string), nil), 200)
	outsiderUser, outsiderDevice := id("acct_"), id("dev_")
	if _, e := f.a.db.Exec(ctx, "INSERT INTO users(id,username,password) VALUES($1,$1,$2)", outsiderUser, []byte{}); e != nil {
		t.Fatal(e)
	}
	if _, e := f.a.db.Exec(ctx, "INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'Outsider','ios')", outsiderDevice, outsiderUser); e != nil {
		t.Fatal(e)
	}
	body := map[string]any{"schema_version": 1, "target": map[string]any{"all_devices": true}, "title": "Broadcast", "body": "Same content, explicit device targets"}
	headers := map[string]string{"Idempotency-Key": "all-once"}
	// Only a Web administrator can select all, and target choices cannot be mixed.
	if f.request("POST", "/v1/push/"+a["send_key"].(string), body, "", nil).Code != 403 {
		t.Fatal("delivery key broadcast")
	}
	sender := result(t, f.request("POST", "/v1/credentials", map[string]any{"name": "Limited", "scopes": []string{"messages:write"}, "targets": []string{legacy["binding_id"].(string)}, "data_ids": []string{}}, "web", nil), 200)
	if f.request("POST", "/v1/messages", body, sender["token"].(string), nil).Code != 403 {
		t.Fatal("limited sender broadcast")
	}
	mixed := map[string]any{"schema_version": 1, "target": map[string]any{"all_devices": true, "device_id": a["binding_id"]}, "body": "Invalid mixed target"}
	if f.request("POST", "/v1/messages", mixed, "web", nil).Code != 422 {
		t.Fatal("ambiguous target accepted")
	}
	first := result(t, f.request("POST", "/v1/messages", body, "web", headers), 202)
	if first["target_count"].(float64) != 3 {
		t.Fatal("wrong active device count")
	}
	later := f.automatic(t, "Added after submission")
	retry := result(t, f.request("POST", "/v1/messages", body, "web", headers), 202)
	if retry["message_id"] != first["message_id"] || retry["target_count"] != first["target_count"] {
		t.Fatal("broadcast retry changed targets")
	}
	for _, device := range []map[string]any{legacy, a, b} {
		page := result(t, f.request("GET", "/v1/device/sync", nil, device["device_token"].(string), nil), 200)
		messages := page["messages"].([]any)
		if len(messages) != 1 || messages[0].(map[string]any)["message_id"] != first["message_id"] {
			t.Fatal("broadcast missing or duplicated")
		}
		var user, account string
		if e := f.a.db.QueryRow(ctx, "SELECT user_id,payload->'vao_push'->>'account_id' FROM outbox WHERE resource_id=$1 AND device_id=$2", first["message_id"], device["binding_id"]).Scan(&user, &account); e != nil {
			t.Fatal(e)
		}
		if user != device["account_id"] || account != user {
			t.Fatal("broadcast lost receiving namespace")
		}
	}
	page := result(t, f.request("GET", "/v1/device/sync", nil, later["device_token"].(string), nil), 200)
	if len(page["messages"].([]any)) != 0 {
		t.Fatal("late device joined retry")
	}
	var n int
	if e := f.a.db.QueryRow(ctx, "SELECT count(*) FROM message_targets WHERE message_id=$1", first["message_id"]).Scan(&n); e != nil || n != 3 {
		t.Fatal("target snapshot incorrect")
	}
	if e := f.a.db.QueryRow(ctx, "SELECT count(*) FROM outbox WHERE resource_id=$1 AND device_id=ANY($2)", first["message_id"], []string{paused["binding_id"].(string), removed["binding_id"].(string), outsiderDevice, later["binding_id"].(string)}).Scan(&n); e != nil || n != 0 {
		t.Fatal("broadcast included excluded devices")
	}
	// Once all owned devices are unavailable, reject without saving a false success.
	if _, e := f.a.db.Exec(ctx, "UPDATE devices SET enabled=false WHERE user_id=$1 OR id IN (SELECT device_id FROM device_keys WHERE owner_id=$1)", f.uid); e != nil {
		t.Fatal(e)
	}
	if f.request("POST", "/v1/messages", body, "web", map[string]string{"Idempotency-Key": "no-targets"}).Code != 422 {
		t.Fatal("empty broadcast accepted")
	}
}
