package main

import (
	"context"
	"strings"
	"sync"
	"testing"
)

func (f fixture) deletionToken(t *testing.T, kind, id string) string {
	t.Helper()
	return result(t, f.request("GET", "/v1/"+kind+"/"+id+"/deletion", nil, "web", nil), 200)["confirmation_token"].(string)
}
func TestDeleteCardPreservesSourceAndOtherCard(t *testing.T) {
	f := setup(t)
	source := f.cardSource(t)
	first := f.publishedCard(t, source)
	second := f.publishedCard(t, source)
	cid := first["id"].(string)
	d := f.automatic(t, "subscriber")
	code := result(t, f.request("POST", "/v1/cards/"+cid+"/codes", map[string]any{}, "web", nil), 200)
	result(t, f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, d["device_token"].(string), nil), 200)
	if f.request("DELETE", "/v1/cards/"+cid, nil, "web", nil).Code != 428 {
		t.Fatal("missing deletion confirmation accepted")
	}
	preview := result(t, f.request("GET", "/v1/cards/"+cid+"/deletion", nil, "web", nil), 200)
	if preview["device_count"].(float64) != 1 {
		t.Fatal("subscriber impact missing")
	}
	result(t, f.request("POST", "/v1/cards/"+cid+"/publish", map[string]any{}, "web", map[string]string{"If-Match": `"draft-1"`}), 200)
	var cardJob string
	if e := f.a.db.QueryRow(context.Background(), "SELECT id FROM outbox WHERE resource_id=$1 AND device_id=$2 AND status='queued'", cid, d["binding_id"]).Scan(&cardJob); e != nil {
		t.Fatal(e)
	}
	preview = result(t, f.request("GET", "/v1/cards/"+cid+"/deletion", nil, "web", nil), 200)
	result(t, f.request("DELETE", "/v1/cards/"+cid, nil, "web", map[string]string{"If-Match": preview["confirmation_token"].(string)}), 200)
	var cardJobStatus string
	if e := f.a.db.QueryRow(context.Background(), "SELECT status FROM outbox WHERE id=$1", cardJob).Scan(&cardJobStatus); e != nil || cardJobStatus != "cancelled" {
		t.Fatal("deleted card job not cancelled", cardJobStatus, e)
	}
	for _, path := range []string{"/v1/cards/" + cid + "/deletion", "/v1/card-subscriptions/" + cid} {
		auth := "web"
		if strings.Contains(path, "card-subscriptions") {
			auth = d["read_token"].(string)
		}
		if f.request("GET", path, nil, auth, nil).Code != 404 {
			t.Fatal("deleted card still visible")
		}
	}
	if f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, d["device_token"].(string), nil).Code != 404 {
		t.Fatal("deleted card code usable")
	}
	result(t, f.request("GET", "/v1/card-sources/"+source["id"].(string), nil, "web", nil), 200)
	result(t, f.request("GET", "/v1/cards/"+second["id"].(string)+"/deletion", nil, "web", nil), 200)
	result(t, f.request("PUT", strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL), goodState(), "", nil), 202)
}
func TestDeleteSourceRequiresNoCardsAndRevokesIngress(t *testing.T) {
	f := setup(t)
	source := f.cardSource(t)
	a := f.publishedCard(t, source)
	b := f.publishedCard(t, source)
	sid := source["id"].(string)
	d := f.automatic(t, "consumer")
	code := result(t, f.request("POST", "/v1/cards/"+a["id"].(string)+"/codes", map[string]any{}, "web", nil), 200)
	result(t, f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, d["device_token"].(string), nil), 200)
	other := f.cardSource(t)
	otherCard := f.publishedCard(t, other)
	token := f.deletionToken(t, "card-sources", sid)
	if f.request("DELETE", "/v1/card-sources/"+sid, nil, "web", map[string]string{"If-Match": token}).Code != 409 {
		t.Fatal("implicit cascade deleted cards")
	}
	result(t, f.request("GET", "/v1/cards/"+b["id"].(string)+"/deletion", nil, "web", nil), 200)
	if f.request("DELETE", "/v1/card-sources/"+sid, map[string]any{"delete_cards": true}, "web", map[string]string{"If-Match": token}).Code != 422 {
		t.Fatal("cascade option accepted")
	}
	for _, c := range []map[string]any{a, b} {
		cid := c["id"].(string)
		ct := f.deletionToken(t, "cards", cid)
		result(t, f.request("DELETE", "/v1/cards/"+cid, nil, "web", map[string]string{"If-Match": ct}), 200)
	}
	token = f.deletionToken(t, "card-sources", sid)
	result(t, f.request("DELETE", "/v1/card-sources/"+sid, nil, "web", map[string]string{"If-Match": token}), 200)
	if f.request("GET", "/v1/card-sources/"+sid, nil, "web", nil).Code != 404 {
		t.Fatal("deleted source visible")
	}
	if f.request("PUT", strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL), goodState(), "", nil).Code != 401 {
		t.Fatal("deleted ingress key accepted")
	}
	if f.request("POST", "/v1/card-sources/"+sid+"/poll", map[string]any{}, "web", nil).Code != 404 {
		t.Fatal("deleted source polled")
	}
	if f.request("GET", "/v1/card-subscriptions/"+a["id"].(string), nil, d["read_token"].(string), nil).Code != 404 {
		t.Fatal("deleted card read authorized")
	}
	result(t, f.request("GET", "/v1/cards/"+otherCard["id"].(string)+"/deletion", nil, "web", nil), 200)
	result(t, f.request("PUT", strings.TrimPrefix(other["data_url"].(string), f.a.cfg.PublicURL), goodState(), "", nil), 202)
	var n int
	if e := f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM users WHERE username=$1", "source:"+sid).Scan(&n); e != nil || n != 0 {
		t.Fatal("orphan source principal retained", e)
	}
}
func TestDeletionConfirmationChangesAndAuthorization(t *testing.T) {
	f := setup(t)
	source := f.cardSource(t)
	sid := source["id"].(string)
	stale := f.deletionToken(t, "card-sources", sid)
	card := f.publishedCard(t, source)
	cid := card["id"].(string)
	if f.request("DELETE", "/v1/card-sources/"+sid, nil, "web", map[string]string{"If-Match": stale}).Code != 412 {
		t.Fatal("new card was deleted without preview")
	}
	stale = f.deletionToken(t, "cards", cid)
	code := result(t, f.request("POST", "/v1/cards/"+cid+"/codes", map[string]any{}, "web", nil), 200)
	if f.request("DELETE", "/v1/cards/"+cid, nil, "web", map[string]string{"If-Match": stale}).Code != 412 {
		t.Fatal("new import-code identity missed")
	}
	stale = f.deletionToken(t, "cards", cid)
	d := f.automatic(t, "new subscriber")
	result(t, f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, d["device_token"].(string), nil), 200)
	if f.request("DELETE", "/v1/cards/"+cid, nil, "web", map[string]string{"If-Match": stale}).Code != 412 {
		t.Fatal("new subscriber deleted without preview")
	}
	for _, auth := range []string{d["device_token"].(string), d["read_token"].(string)} {
		if f.request("GET", "/v1/card-sources/"+sid+"/deletion", nil, auth, nil).Code != 403 {
			t.Fatal("non-admin read deletion scope")
		}
		if f.request("DELETE", "/v1/cards/"+cid, nil, auth, nil).Code != 403 {
			t.Fatal("non-admin deletion allowed")
		}
	}
	otherUser, otherSession, otherCSRF := id("acct_"), token(), token()
	if _, e := f.a.db.Exec(context.Background(), "INSERT INTO users(id,username,password) VALUES($1,'other-admin',$2)", otherUser, []byte{}); e != nil {
		t.Fatal(e)
	}
	if _, e := f.a.db.Exec(context.Background(), "INSERT INTO sessions(hash,user_id,csrf,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')", hash(otherSession), otherUser, otherCSRF); e != nil {
		t.Fatal(e)
	}
	outsider := fixture{f.a, otherUser, otherSession, otherCSRF}
	if outsider.request("GET", "/v1/cards/"+cid+"/deletion", nil, "web", nil).Code != 404 {
		t.Fatal("foreign card preview leaked")
	}
	token := f.deletionToken(t, "card-sources", sid)
	if f.request("DELETE", "/v1/card-sources/"+sid, nil, "web", map[string]string{"If-Match": token, "X-CSRF-Token": "wrong"}).Code != 403 {
		t.Fatal("CSRF deletion allowed")
	}
	if f.request("DELETE", "/v1/card-sources/"+sid, nil, "web", map[string]string{"If-Match": token, "Origin": "https://other.invalid"}).Code != 403 {
		t.Fatal("cross-origin deletion allowed")
	}
	// Data updates should not force an unrelated confirmation refresh.
	result(t, f.request("PUT", strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL), goodState(), "", nil), 202)
	ct := f.deletionToken(t, "cards", cid)
	result(t, f.request("DELETE", "/v1/cards/"+cid, nil, "web", map[string]string{"If-Match": ct}), 200)
	token = f.deletionToken(t, "card-sources", sid)
	result(t, f.request("DELETE", "/v1/card-sources/"+sid, nil, "web", map[string]string{"If-Match": token}), 200)
}
func TestDeleteSourceWithoutCardsAndConcurrentWrite(t *testing.T) {
	f := setup(t)
	source := f.cardSource(t)
	sid := source["id"].(string)
	token := f.deletionToken(t, "card-sources", sid)
	path := strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL)
	var streamID string
	if e := f.a.db.QueryRow(context.Background(), "SELECT stream_id FROM card_sources WHERE id=$1", sid).Scan(&streamID); e != nil {
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	wg.Add(2)
	statuses := make(chan int, 1)
	go func() { defer wg.Done(); statuses <- f.request("PUT", path, goodState(), "", nil).Code }()
	go func() {
		defer wg.Done()
		r := f.request("DELETE", "/v1/card-sources/"+sid, nil, "web", map[string]string{"If-Match": token})
		if r.Code != 200 {
			t.Errorf("delete failed %d %s", r.Code, r.Body.String())
		}
	}()
	wg.Wait()
	status := <-statuses
	if status != 200 && status != 202 && status != 401 && status != 404 {
		t.Fatalf("unexpected concurrent write status %d", status)
	}
	if f.request("PUT", path, goodState(), "", nil).Code != 401 {
		t.Fatal("concurrent write resurrected ingress")
	}
	var n int
	if e := f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM streams WHERE id=$1", streamID).Scan(&n); e != nil || n != 0 {
		t.Fatal("source stream retained or recreated", e)
	}
}

func TestDeletionPreservesIndependentWidgetJobs(t *testing.T) {
	for _, kind := range []string{"source", "card"} {
		t.Run(kind, func(t *testing.T) {
			f := setup(t)
			ctx := context.Background()
			source := f.cardSource(t)
			resource := source["data_id"].(string)
			path := "/v1/card-sources/" + source["id"].(string)
			if kind == "card" {
				card := f.publishedCard(t, source)
				resource = card["id"].(string)
				path = "/v1/cards/" + resource
			}
			d := f.automatic(t, "Independent device stream")
			device, auth := d["binding_id"].(string), d["device_token"].(string)
			result(t, f.request("PUT", "/v1/device/registration", map[string]any{"environment": "sandbox", "widget_token": strings.Repeat("cd", 32)}, auth, nil), 200)
			legacyPath := "/v1/state/" + d["send_key"].(string) + "/" + resource
			result(t, f.request("PUT", legacyPath, goodState(), "", nil), 202)
			result(t, f.request("PUT", "/v1/device/subscriptions", map[string]any{"data_ids": []string{resource}}, auth, nil), 200)
			next := goodState()
			next["title"] = "Independent stream update"
			result(t, f.request("PUT", legacyPath, next, "", nil), 202)
			var job string
			if e := f.a.db.QueryRow(ctx, "SELECT id FROM outbox WHERE device_id=$1 AND resource_id=$2 AND status='queued'", device, resource).Scan(&job); e != nil {
				t.Fatal(e)
			}
			preview := result(t, f.request("GET", path+"/deletion", nil, "web", nil), 200)
			result(t, f.request("DELETE", path, nil, "web", map[string]string{"If-Match": preview["confirmation_token"].(string)}), 200)
			var status string
			if e := f.a.db.QueryRow(ctx, "SELECT status FROM outbox WHERE id=$1", job).Scan(&status); e != nil || status != "queued" {
				t.Fatalf("deleting %s changed an independent stream job: status=%s error=%v", kind, status, e)
			}
			probe := &cardDispatchProbe{}
			f.a.push = probe
			if !f.a.workOne(ctx) || len(probe.jobs) != 1 {
				t.Fatal("independent authorized stream no longer dispatches")
			}
			result(t, f.request("GET", "/v1/widgets/"+resource+"/state", nil, d["read_token"].(string), nil), 200)
		})
	}
}
