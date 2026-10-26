package main

import (
	"context"
	"strings"
	"testing"
)

func (f fixture) saveRoute(t *testing.T, ids []string) map[string]any {
	t.Helper()
	current := f.request("GET", "/v1/message-route", nil, "web", nil)
	result(t, current, 200)
	return result(t, f.request("PUT", "/v1/message-route", map[string]any{"device_ids": ids}, "web", map[string]string{"If-Match": current.Header().Get("ETag")}), 200)
}

func TestSavedMessageRouteDispatchAndRetry(t *testing.T) {
	f := setup(t)
	legacy, a, b := f.paired(t), f.automatic(t, "Default A"), f.automatic(t, "Default B")
	initial := result(t, f.request("GET", "/v1/message-route", nil, "web", nil), 200)
	if initial["configured"] != false || initial["message_url"] != nil {
		t.Fatal("route created before save")
	}
	saved := f.saveRoute(t, []string{legacy["binding_id"].(string), a["binding_id"].(string)})
	path := strings.TrimPrefix(saved["message_url"].(string), f.a.cfg.PublicURL)
	key := strings.TrimPrefix(path, "/v1/push/")
	body := map[string]any{"body": "Automatic default recipients"}
	headers := map[string]string{"Idempotency-Key": "automatic-first"}
	first := result(t, f.request("POST", path, body, "", headers), 202)
	if first["target_count"].(float64) != 2 {
		t.Fatal("saved recipients not expanded")
	}
	for _, d := range []map[string]any{legacy, a} {
		page := result(t, f.request("GET", "/v1/device/sync", nil, d["device_token"].(string), nil), 200)
		if len(page["messages"].([]any)) != 1 {
			t.Fatal("default recipient did not synchronize")
		}
	}
	// Exact A/B/C case: C stays enabled and bound, receives only a temporary Web send.
	cPage := result(t, f.request("GET", "/v1/device/sync", nil, b["device_token"].(string), nil), 200)
	if len(cPage["messages"].([]any)) != 0 {
		t.Fatal("C received the normal automatic request")
	}
	urgent := map[string]any{"schema_version": 1, "target": map[string]any{"device_ids": []string{b["binding_id"].(string)}}, "body": "Temporary urgent Web message for C"}
	result(t, f.request("POST", "/v1/messages", urgent, "web", nil), 202)
	unchanged := result(t, f.request("GET", "/v1/message-route", nil, "web", nil), 200)
	if unchanged["revision"] != saved["revision"] || unchanged["message_url"] != saved["message_url"] {
		t.Fatal("temporary manual selection changed the default route")
	}
	if result(t, f.request("POST", path, body, "", map[string]string{"Idempotency-Key": "automatic-still-AB"}), 202)["target_count"].(float64) != 2 {
		t.Fatal("normal default selection changed after urgent send")
	}
	cPage = result(t, f.request("GET", "/v1/device/sync", nil, b["device_token"].(string), nil), 200)
	if len(cPage["messages"].([]any)) != 1 || cPage["messages"].([]any)[0].(map[string]any)["body"] != urgent["body"] {
		t.Fatal("C did not receive only the manual urgent message")
	}
	saved2 := f.saveRoute(t, []string{b["binding_id"].(string)})
	if saved2["message_url"] != saved["message_url"] {
		t.Fatal("editing recipients changed the address")
	}
	retry := result(t, f.request("POST", path, body, "", headers), 202)
	if retry["message_id"] != first["message_id"] || retry["target_count"].(float64) != 2 {
		t.Fatal("accepted retry used the changed default list")
	}
	// New application instance, same PostgreSQL, with no in-memory routing state.
	restarted := &App{db: f.a.db, cfg: f.a.cfg, limiter: newLimiter()}
	restarted.routes()
	fresh := fixture{restarted, f.uid, f.session, f.csrf}
	persisted := result(t, fresh.request("GET", "/v1/message-route", nil, "web", nil), 200)
	if persisted["message_url"] != saved["message_url"] || len(persisted["device_ids"].([]any)) != 1 {
		t.Fatal("route did not persist")
	}
	result(t, fresh.request("POST", path, body, "", map[string]string{"Idempotency-Key": "automatic-second"}), 202)
	page := result(t, f.request("GET", "/v1/device/sync", nil, b["device_token"].(string), nil), 200)
	if len(page["messages"].([]any)) != 2 {
		t.Fatal("new request did not use saved replacement")
	}
	later := f.automatic(t, "New device not selected")
	page = result(t, f.request("GET", "/v1/device/sync", nil, later["device_token"].(string), nil), 200)
	if len(page["messages"].([]any)) != 0 {
		t.Fatal("new device silently subscribed")
	}
	for _, endpoint := range []string{"/v1/message-route", "/v1/dashboard", "/v1/device/sync"} {
		if f.request("GET", endpoint, nil, key, nil).Code != 403 {
			t.Fatal("default send key read control data")
		}
	}
	if f.request("PUT", "/v1/message-route", map[string]any{"device_ids": []string{}}, key, nil).Code != 403 {
		t.Fatal("default send key modified recipients")
	}
	if f.request("PUT", "/v1/state/"+key+"/status", goodState(), "", nil).Code != 403 {
		t.Fatal("message key gained widget write")
	}
	if f.request("POST", path, messageBody(later["binding_id"].(string)), "", nil).Code != 422 {
		t.Fatal("message key overrode saved recipients")
	}
	// Disabled saved devices are skipped; an empty effective set is an explicit error.
	result(t, f.request("PUT", "/v1/device/status", map[string]any{"enabled": false}, b["device_token"].(string), nil), 200)
	if f.request("POST", path, body, "", nil).Code != 422 {
		t.Fatal("disabled-only route reported success")
	}
	f.saveRoute(t, []string{})
	if f.request("POST", path, body, "", nil).Code != 422 {
		t.Fatal("empty route reported success")
	}
	// Clearing the list does not cause an already accepted request to send again.
	if result(t, f.request("POST", path, body, "", headers), 202)["message_id"] != first["message_id"] {
		t.Fatal("retry after pause changed the accepted request")
	}
}

func TestSavedMessageRouteControlsAndFiltering(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	a, b, c := f.automatic(t, "Active"), f.automatic(t, "Will pause"), f.automatic(t, "Will revoke")
	saved := f.saveRoute(t, []string{a["binding_id"].(string), b["binding_id"].(string), c["binding_id"].(string)})
	path := strings.TrimPrefix(saved["message_url"].(string), f.a.cfg.PublicURL)
	result(t, f.request("PUT", "/v1/device/status", map[string]any{"enabled": false}, b["device_token"].(string), nil), 200)
	result(t, f.request("DELETE", "/v1/device", nil, c["device_token"].(string), nil), 200)
	if result(t, f.request("POST", path, map[string]any{"body": "Only active saved devices"}, "", nil), 202)["target_count"].(float64) != 1 {
		t.Fatal("unavailable default devices were included")
	}
	original := f.request("GET", "/v1/message-route", nil, "web", nil)
	result(t, original, 200)
	if f.request("PUT", "/v1/message-route", map[string]any{"device_ids": []string{a["binding_id"].(string)}}, "web", map[string]string{"If-Match": "\"route-0\""}).Code != 412 {
		t.Fatal("stale editor overwrote route")
	}
	cases := []struct {
		name   string
		ids    any
		status int
	}{
		{"missing", nil, 422},
		{"foreign", []string{a["binding_id"].(string), "dev_unknown"}, 404},
		{"paused", []string{b["binding_id"].(string)}, 422},
		{"revoked", []string{c["binding_id"].(string)}, 404},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if f.request("PUT", "/v1/message-route", map[string]any{"device_ids": tc.ids}, "web", map[string]string{"If-Match": original.Header().Get("ETag")}).Code != tc.status {
				t.Fatal("invalid route update accepted")
			}
			latest := result(t, f.request("GET", "/v1/message-route", nil, "web", nil), 200)
			if latest["revision"] != saved["revision"] || latest["message_url"] != saved["message_url"] {
				t.Fatal("invalid save changed route")
			}
		})
	}
	// An unrelated administrator has an independent empty default and cannot adopt devices.
	otherUser, session := id("acct_"), token()
	if _, e := f.a.db.Exec(ctx, "INSERT INTO users(id,username,password) VALUES($1,$1,$2)", otherUser, []byte{}); e != nil {
		t.Fatal(e)
	}
	if _, e := f.a.db.Exec(ctx, "INSERT INTO sessions(hash,user_id,csrf,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')", hash(session), otherUser, f.csrf); e != nil {
		t.Fatal(e)
	}
	outsider := fixture{f.a, otherUser, session, f.csrf}
	if result(t, outsider.request("GET", "/v1/message-route", nil, "web", nil), 200)["configured"] != false {
		t.Fatal("another administrator read route")
	}
	if outsider.request("PUT", "/v1/message-route", map[string]any{"device_ids": []string{a["binding_id"].(string)}}, "web", map[string]string{"If-Match": routeETag(0)}).Code != 404 {
		t.Fatal("another administrator adopted recipients")
	}
}
