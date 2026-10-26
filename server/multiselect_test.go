package main

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
)

func TestWebSelectedDevicesRetryAndIsolation(t *testing.T) {
	f := setup(t)
	legacy, a, excluded := f.paired(t), f.automatic(t, "Selected A"), f.automatic(t, "Not selected")
	one, two := legacy["binding_id"].(string), a["binding_id"].(string)
	headers := map[string]string{"Idempotency-Key": "selected-set-once"}
	var wg sync.WaitGroup
	responses := make(chan map[string]any, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ids := []string{one, two, one}
			if i%2 == 0 {
				ids = []string{two, one}
			}
			body := map[string]any{"schema_version": 1, "target": map[string]any{"device_ids": ids}, "body": "Selected devices only"}
			w := f.request("POST", "/v1/messages", body, "web", headers)
			if w.Code != 202 {
				t.Errorf("selected send HTTP %d", w.Code)
				return
			}
			var raw struct {
				Data map[string]any `json:"data"`
			}
			if e := json.Unmarshal(w.Body.Bytes(), &raw); e != nil {
				t.Error(e)
				return
			}
			responses <- raw.Data
		}(i)
	}
	wg.Wait()
	close(responses)
	var message any
	for response := range responses {
		if response["target_count"].(float64) != 2 {
			t.Fatal("selection was not deduplicated")
		}
		if message == nil {
			message = response["message_id"]
		} else if message != response["message_id"] {
			t.Fatal("reordered retry created another message")
		}
	}
	if message == nil {
		t.Fatal("no selected send succeeded")
	}
	for _, device := range []map[string]any{legacy, a} {
		page := result(t, f.request("GET", "/v1/device/sync", nil, device["device_token"].(string), nil), 200)
		messages := page["messages"].([]any)
		if len(messages) != 1 || messages[0].(map[string]any)["message_id"] != message {
			t.Fatal("selected history missing or duplicated")
		}
		var user, account string
		if e := f.a.db.QueryRow(context.Background(), "SELECT user_id,payload->'vao_push'->>'account_id' FROM outbox WHERE resource_id=$1 AND device_id=$2", message, device["binding_id"]).Scan(&user, &account); e != nil {
			t.Fatal(e)
		}
		if user != device["account_id"] || account != user {
			t.Fatal("selected push has wrong receiving namespace")
		}
	}
	page := result(t, f.request("GET", "/v1/device/sync", nil, excluded["device_token"].(string), nil), 200)
	if len(page["messages"].([]any)) != 0 {
		t.Fatal("unselected device received message")
	}
	var n int
	if e := f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM outbox WHERE resource_id=$1", message).Scan(&n); e != nil || n != 2 {
		t.Fatal("duplicate or missing selected outbox")
	}
	single := map[string]any{"schema_version": 1, "target": map[string]any{"device_ids": []string{excluded["binding_id"].(string)}}, "body": "One selection"}
	if result(t, f.request("POST", "/v1/messages", single, "web", nil), 202)["target_count"].(float64) != 1 {
		t.Fatal("single checkbox selection failed")
	}
}

func TestWebSelectedDevicesValidationRollback(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	owned, paused, revoked := f.automatic(t, "Owned"), f.automatic(t, "Paused"), f.automatic(t, "Revoked")
	ownedID := owned["binding_id"].(string)
	result(t, f.request("PUT", "/v1/device/status", map[string]any{"enabled": false}, paused["device_token"].(string), nil), 200)
	result(t, f.request("DELETE", "/v1/device", nil, revoked["device_token"].(string), nil), 200)
	foreignUser, foreignDevice := id("acct_"), id("dev_")
	if _, e := f.a.db.Exec(ctx, "INSERT INTO users(id,username,password) VALUES($1,$1,$2)", foreignUser, []byte{}); e != nil {
		t.Fatal(e)
	}
	if _, e := f.a.db.Exec(ctx, "INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'Foreign','ios')", foreignDevice, foreignUser); e != nil {
		t.Fatal(e)
	}
	tooMany := make([]string, 251)
	for i := range tooMany {
		tooMany[i] = ownedID
	}
	cases := []struct {
		name   string
		target map[string]any
		status int
	}{
		{"empty", map[string]any{"device_ids": []string{}}, 422},
		{"null", map[string]any{"device_ids": nil}, 422},
		{"too_many", map[string]any{"device_ids": tooMany}, 422},
		{"empty_id", map[string]any{"device_ids": []string{ownedID, ""}}, 422},
		{"mixed_single", map[string]any{"device_ids": []string{ownedID}, "device_id": ownedID}, 422},
		{"mixed_all", map[string]any{"device_ids": []string{ownedID}, "all_devices": true}, 422},
		{"mixed_group", map[string]any{"device_ids": []string{ownedID}, "group_id": "unused"}, 422},
		{"unknown", map[string]any{"device_ids": []string{ownedID, "dev_missing"}}, 404},
		{"foreign", map[string]any{"device_ids": []string{ownedID, foreignDevice}}, 404},
		{"revoked", map[string]any{"device_ids": []string{ownedID, revoked["binding_id"].(string)}}, 404},
		{"paused", map[string]any{"device_ids": []string{ownedID, paused["binding_id"].(string)}}, 422},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			body := map[string]any{"schema_version": 1, "target": c.target, "body": "Must not be partially sent"}
			if w := f.request("POST", "/v1/messages", body, "web", nil); w.Code != c.status {
				t.Fatalf("HTTP %d expected %d", w.Code, c.status)
			}
			var n int
			if e := f.a.db.QueryRow(ctx, "SELECT count(*) FROM messages").Scan(&n); e != nil || n != 0 {
				t.Fatal("invalid selection saved a message")
			}
			if e := f.a.db.QueryRow(ctx, "SELECT count(*) FROM outbox").Scan(&n); e != nil || n != 0 {
				t.Fatal("invalid selection partially queued")
			}
		})
	}
	selected := map[string]any{"schema_version": 1, "target": map[string]any{"device_ids": []string{ownedID}}, "body": "No credential escalation"}
	if f.request("POST", "/v1/messages", selected, owned["send_key"].(string), nil).Code != 403 {
		t.Fatal("single-device send key gained list permission")
	}
	legacy := f.paired(t)
	sender := result(t, f.request("POST", "/v1/credentials", map[string]any{"name": "Limited", "scopes": []string{"messages:write"}, "targets": []string{legacy["binding_id"].(string)}}, "web", nil), 200)
	if f.request("POST", "/v1/messages", selected, sender["token"].(string), nil).Code != 403 {
		t.Fatal("legacy limited sender gained list permission")
	}
}
