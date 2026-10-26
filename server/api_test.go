package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

type fixture struct {
	a                  *App
	uid, session, csrf string
}

func setup(t *testing.T) fixture {
	t.Helper()
	path := os.Getenv("VAO_TEST_CONFIG")
	if path == "" {
		t.Skip("VAO_TEST_CONFIG required for isolated PostgreSQL tests")
	}
	raw, e := os.ReadFile(path)
	if e != nil {
		t.Fatal("test config unavailable")
	}
	var cfg Config
	if json.Unmarshal(raw, &cfg) != nil {
		t.Fatal("invalid test config")
	}
	ctx := context.Background()
	admin, e := pgxpool.New(ctx, cfg.DatabaseURL)
	if e != nil {
		t.Fatal("db connect")
	}
	schemaID := id("test_")
	if _, e = admin.Exec(ctx, "CREATE SCHEMA "+schemaID); e != nil {
		t.Fatal(e)
	}
	pc, e := pgxpool.ParseConfig(cfg.DatabaseURL)
	if e != nil {
		t.Fatal("db config")
	}
	pc.ConnConfig.RuntimeParams["search_path"] = schemaID
	db, e := pgxpool.NewWithConfig(ctx, pc)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close(); _, _ = admin.Exec(ctx, "DROP SCHEMA "+schemaID+" CASCADE"); admin.Close() })
	if _, e = db.Exec(ctx, schema); e != nil {
		t.Fatal(e)
	}
	cfg.PublicURL = "https://vao.invalid"
	cfg.Username = "admin"
	cfg.ID = "srv_test"
	cfg.MasterKey = strings.Repeat("31", 32)
	a := &App{db: db, cfg: cfg, limiter: newLimiter()}
	a.routes()
	a.push = fakePush{PushResult{Status: "accepted", APNsID: "test-only"}}
	uid, session, csrf := id("acct_"), token(), token()
	pw, _ := bcrypt.GenerateFromPassword([]byte("test-password-example"), bcrypt.MinCost)
	_, e = db.Exec(ctx, "INSERT INTO users(id,username,password) VALUES($1,'admin',$2)", uid, pw)
	if e != nil {
		t.Fatal(e)
	}
	_, e = db.Exec(ctx, "INSERT INTO sessions(hash,user_id,csrf,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')", hash(session), uid, csrf)
	if e != nil {
		t.Fatal(e)
	}
	return fixture{a, uid, session, csrf}
}
func (f fixture) request(method, path string, body any, auth string, headers map[string]string) *httptest.ResponseRecorder {
	var raw []byte
	if body != nil {
		raw = canonical(body)
	}
	req := httptest.NewRequest(method, "https://vao.invalid"+path, bytes.NewReader(raw))
	req.RemoteAddr = "127.0.0.1:1234"
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Origin", f.a.cfg.PublicURL)
	if auth == "web" {
		req.AddCookie(&http.Cookie{Name: "vao_session", Value: f.session})
		req.Header.Set("X-CSRF-Token", f.csrf)
	} else if auth != "" {
		req.Header.Set("Authorization", "Bearer "+auth)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	f.a.ServeHTTP(w, req)
	return w
}
func result(t *testing.T, w *httptest.ResponseRecorder, status int) map[string]any {
	t.Helper()
	if w.Code != status {
		var b map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &b)
		t.Fatalf("HTTP %d expected %d; code=%v", w.Code, status, b["error"])
	}
	var v struct {
		Data map[string]any `json:"data"`
	}
	if e := json.Unmarshal(w.Body.Bytes(), &v); e != nil {
		t.Fatal(e)
	}
	return v.Data
}
func (f fixture) paired(t *testing.T) map[string]any {
	t.Helper()
	p := result(t, f.request("POST", "/v1/pairings", map[string]any{}, "web", nil), 200)
	return result(t, f.request("POST", "/v1/pairings/claim", map[string]any{"code": p["code"], "device_name": "Test iPhone", "platform": "ios"}, "", nil), 200)
}
func (f fixture) stream(t *testing.T, data, ordering string) map[string]any {
	t.Helper()
	return result(t, f.request("POST", "/v1/streams", map[string]any{"data_id": data, "name": "Test", "ordering": ordering}, "web", nil), 200)
}
func goodState() map[string]any {
	return map[string]any{"schema_version": 1, "source_updated_at": "2026-10-24T10:00:00Z", "fields": map[string]any{"progress": map[string]any{"type": "percent", "value": "68"}, "zero": map[string]any{"type": "integer", "value": "0"}, "missing": map[string]any{"type": "text", "value": nil}}}
}
func messageBody(device string) map[string]any {
	return map[string]any{"schema_version": 1, "target": map[string]any{"device_id": device}, "title": "Test", "body": "Manual test message"}
}
func TestPairingAuthenticationAndRevocation(t *testing.T) {
	f := setup(t)
	p := result(t, f.request("POST", "/v1/pairings", map[string]any{}, "web", nil), 200)
	claim := map[string]any{"code": p["code"], "device_name": "iPhone", "platform": "ios"}
	d := result(t, f.request("POST", "/v1/pairings/claim", claim, "", nil), 200)
	if f.request("POST", "/v1/pairings/claim", claim, "", nil).Code != 422 {
		t.Fatal("pairing replay accepted")
	}
	dt, rt := d["device_token"].(string), d["read_token"].(string)
	if f.request("POST", "/v1/messages", messageBody(d["binding_id"].(string)), rt, nil).Code != 403 {
		t.Fatal("read token wrote message")
	}
	if f.request("GET", "/v1/device/sync", nil, rt, nil).Code != 403 {
		t.Fatal("read token synchronized history")
	}
	if f.request("PUT", "/v1/device/registration", map[string]any{"environment": "sandbox", "apns_token": strings.Repeat("ab", 32)}, rt, nil).Code != 403 {
		t.Fatal("read token registered alert")
	}
	result(t, f.request("PUT", "/v1/device/registration", map[string]any{"environment": "sandbox", "widget_token": strings.Repeat("ab", 32)}, rt, nil), 200)
	result(t, f.request("DELETE", "/v1/device", nil, dt, nil), 200)
	if f.request("GET", "/v1/device/sync", nil, dt, nil).Code != 401 {
		t.Fatal("revoked device accepted")
	}
	if f.request("PUT", "/v1/device/registration", map[string]any{"environment": "sandbox"}, rt, nil).Code != 401 {
		t.Fatal("revoked reader accepted")
	}
}
func TestMessageIdempotencyAndSync(t *testing.T) {
	f := setup(t)
	d := f.paired(t)
	body := messageBody(d["binding_id"].(string))
	headers := map[string]string{"Idempotency-Key": "message-one"}
	first := result(t, f.request("POST", "/v1/messages", body, "web", headers), 202)
	again := result(t, f.request("POST", "/v1/messages", body, "web", headers), 202)
	if first["message_id"] != again["message_id"] {
		t.Fatal("duplicate message")
	}
	body["body"] = "changed"
	if f.request("POST", "/v1/messages", body, "web", headers).Code != 409 {
		t.Fatal("conflict accepted")
	}
	dt := d["device_token"].(string)
	sync := result(t, f.request("GET", "/v1/device/sync", nil, dt, nil), 200)
	if len(sync["messages"].([]any)) != 1 {
		t.Fatal("sync message count")
	}
	next := result(t, f.request("GET", "/v1/device/sync?cursor="+sync["cursor"].(string), nil, dt, nil), 200)
	if len(next["messages"].([]any)) != 0 {
		t.Fatal("cursor replay")
	}
	other := f.paired(t)
	if len(result(t, f.request("GET", "/v1/device/sync", nil, other["device_token"].(string), nil), 200)["messages"].([]any)) != 0 {
		t.Fatal("other device history leak")
	}
}
func TestStateVersionSequenceETagAndSubscription(t *testing.T) {
	f := setup(t)
	d := f.paired(t)
	f.stream(t, "progress", "server_order")
	body := goodState()
	first := result(t, f.request("PUT", "/v1/widgets/progress/state", body, "web", nil), 202)
	if first["dispatch_status"] != "no_subscribers" {
		t.Fatal("false subscriber")
	}
	get := f.request("GET", "/v1/widgets/progress/state", nil, d["device_token"].(string), nil)
	result(t, get, 200)
	etag := get.Header().Get("ETag")
	if f.request("GET", "/v1/widgets/progress/state", nil, d["read_token"].(string), nil).Code != 404 {
		t.Fatal("unsubscribed reader")
	}
	result(t, f.request("PUT", "/v1/device/subscriptions", map[string]any{"data_ids": []string{"progress"}}, d["device_token"].(string), nil), 200)
	if f.request("GET", "/v1/widgets/progress/state", nil, d["read_token"].(string), map[string]string{"If-None-Match": etag}).Code != 304 {
		t.Fatal("conditional GET")
	}
	if result(t, f.request("PUT", "/v1/widgets/progress/state", body, "web", nil), 200)["revision"] != "1" {
		t.Fatal("identical state changed revision")
	}
	body["title"] = "next"
	result(t, f.request("PUT", "/v1/widgets/progress/state", body, "web", map[string]string{"If-Match": etag}), 202)
	body["title"] = "stale edit"
	if f.request("PUT", "/v1/widgets/progress/state", body, "web", map[string]string{"If-Match": etag}).Code != 412 {
		t.Fatal("lost update")
	}
	f.stream(t, "sequence", "source_sequence")
	body = goodState()
	body["sequence"] = "10"
	result(t, f.request("PUT", "/v1/widgets/sequence/state", body, "web", nil), 202)
	body["sequence"] = "9"
	if f.request("PUT", "/v1/widgets/sequence/state", body, "web", nil).Code != 409 {
		t.Fatal("sequence rollback")
	}
	body["sequence"] = "10"
	body["title"] = "conflict"
	if f.request("PUT", "/v1/widgets/sequence/state", body, "web", nil).Code != 409 {
		t.Fatal("sequence conflict")
	}
	var jobs int
	if e := f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM outbox WHERE kind='widget'").Scan(&jobs); e != nil || jobs != 1 {
		t.Fatal("widget jobs", jobs, e)
	}
}
func TestConcurrentIdempotency(t *testing.T) {
	f := setup(t)
	d := f.paired(t)
	body := messageBody(d["binding_id"].(string))
	var wg sync.WaitGroup
	codes := make(chan int, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes <- f.request("POST", "/v1/messages", body, "web", map[string]string{"Idempotency-Key": "same-concurrent-key"}).Code
		}()
	}
	wg.Wait()
	close(codes)
	for c := range codes {
		if c != 202 {
			t.Fatal("concurrent status", c)
		}
	}
	var messages, jobs int
	_ = f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM messages").Scan(&messages)
	_ = f.a.db.QueryRow(context.Background(), "SELECT count(*) FROM outbox").Scan(&jobs)
	if messages != 1 || jobs != 1 {
		t.Fatal("non atomic duplicate", messages, jobs)
	}
}
func TestSenderScopeAndAccountIsolation(t *testing.T) {
	f := setup(t)
	d := f.paired(t)
	f.stream(t, "allowed", "server_order")
	f.stream(t, "denied", "server_order")
	sender := result(t, f.request("POST", "/v1/credentials", map[string]any{"name": "limited", "scopes": []string{"states:write"}, "data_ids": []string{"allowed"}}, "web", nil), 200)
	token := sender["token"].(string)
	result(t, f.request("PUT", "/v1/widgets/allowed/state", goodState(), token, nil), 202)
	if f.request("PUT", "/v1/widgets/denied/state", goodState(), token, nil).Code != 404 {
		t.Fatal("scope escape")
	}
	if f.request("POST", "/v1/messages", messageBody(d["binding_id"].(string)), token, nil).Code != 403 {
		t.Fatal("message scope escape")
	}
	ctx := context.Background()
	other := id("acct_")
	_, e := f.a.db.Exec(ctx, "INSERT INTO users(id,username,password) VALUES($1,'other','x')", other)
	if e != nil {
		t.Fatal(e)
	}
	_, e = f.a.db.Exec(ctx, "INSERT INTO streams(id,user_id,data_id,name,ordering,state,revision,received_at) VALUES($1,$2,'secret','Secret','server_order',$3,1,now())", id("stream_"), other, canonical(goodState()))
	if e != nil {
		t.Fatal(e)
	}
	if f.request("GET", "/v1/widgets/secret/state", nil, d["device_token"].(string), nil).Code != 404 {
		t.Fatal("cross account read")
	}
	result(t, f.request("DELETE", "/v1/credentials/"+sender["id"].(string), nil, "web", nil), 200)
	if f.request("PUT", "/v1/widgets/allowed/state", goodState(), token, nil).Code != 401 {
		t.Fatal("revoked sender")
	}
	if f.request("POST", "/v1/pairings", map[string]any{}, "web", map[string]string{"X-CSRF-Token": "wrong"}).Code != 403 {
		t.Fatal("csrf bypass")
	}
	if f.request("POST", "/v1/pairings", map[string]any{}, "web", map[string]string{"Origin": "https://evil.invalid"}).Code != 403 {
		t.Fatal("origin bypass")
	}
}

type fakePush struct{ result PushResult }

func (f fakePush) Send(_ context.Context, _ PushJob) PushResult { return f.result }
func TestOutboxRecoveryExpiryAndInvalidToken(t *testing.T) {
	f := setup(t)
	d := f.paired(t)
	dt, device := d["device_token"].(string), d["binding_id"].(string)
	result(t, f.request("PUT", "/v1/device/registration", map[string]any{"environment": "sandbox", "apns_token": strings.Repeat("ab", 32)}, dt, nil), 200)
	result(t, f.request("POST", "/v1/messages", messageBody(device), "web", nil), 202)
	ctx := context.Background()
	_, _ = f.a.db.Exec(ctx, "UPDATE outbox SET status='sending',lease_until=now()-interval '1 minute'")
	if !f.a.workOne(ctx) {
		t.Fatal("lease not reclaimed")
	}
	var status string
	_ = f.a.db.QueryRow(ctx, "SELECT status FROM outbox").Scan(&status)
	if status != "accepted" {
		t.Fatal("mock acceptance missing")
	}
	result(t, f.request("POST", "/v1/messages", messageBody(device), "web", nil), 202)
	_, _ = f.a.db.Exec(ctx, "UPDATE outbox SET expires_at=now()-interval '1 minute' WHERE status='queued'")
	f.a.workOne(ctx)
	var n int
	_ = f.a.db.QueryRow(ctx, "SELECT count(*) FROM outbox WHERE status='expired'").Scan(&n)
	if n != 1 {
		t.Fatal("TTL not expired")
	}
	f.a.push = fakePush{PushResult{Status: "invalid", Reason: "Unregistered"}}
	result(t, f.request("POST", "/v1/messages", messageBody(device), "web", nil), 202)
	f.a.workOne(ctx)
	var registered bool
	_ = f.a.db.QueryRow(ctx, "SELECT apns_token IS NOT NULL FROM devices WHERE id=$1", device).Scan(&registered)
	if registered {
		t.Fatal("410 token retained")
	}
	f.a.push = &APNsSender{app: f.a, client: &http.Client{}}
	j := PushJob{Token: strings.Repeat("ab", 32)}
	if f.a.push.Send(ctx, j).Reason != "apns_not_configured" {
		t.Fatal("unconfigured push faked success")
	}
}
func TestStateValidation(t *testing.T) {
	for name, mutate := range map[string]func(map[string]any){"numeric": func(s map[string]any) {
		s["fields"] = map[string]any{"price": map[string]any{"type": "decimal", "value": 1.2}}
	}, "precision": func(s map[string]any) {
		s["fields"] = map[string]any{"price": map[string]any{"type": "decimal", "value": "1.1234567890123456789"}}
	}, "time": func(s map[string]any) { s["source_updated_at"] = "2026-10-24T10:00:00+08:00" }, "unknown": func(s map[string]any) { s["aps"] = map[string]any{} }, "duplicates": func(s map[string]any) {
		s["items"] = []any{map[string]any{"item_id": "a", "fields": map[string]any{}}, map[string]any{"item_id": "a", "fields": map[string]any{}}}
	}, "ohlc": func(s map[string]any) {
		s["series"] = map[string]any{"price": map[string]any{"type": "ohlc", "interval_seconds": 60, "points": []any{map[string]any{"t": "2026-10-24T10:00:00Z", "o": "2", "h": "1", "l": "0", "c": "2"}}}}
	}} {
		t.Run(name, func(t *testing.T) {
			s := goodState()
			mutate(s)
			if _, e := validateState(canonical(s)); e == nil {
				t.Fatal("invalid state accepted")
			}
		})
	}
	if _, e := validateState(canonical(goodState())); e != nil {
		t.Fatal(e)
	}
}

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestAPNsSigningHeadersAndEncryption(t *testing.T) {
	f := setup(t)
	key, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	raw, e := x509.MarshalPKCS8PrivateKey(key)
	if e != nil {
		t.Fatal(e)
	}
	c := APNsConfig{KeyID: "ABCDEFGHIJ", TeamID: "KLMNOPQRST", Topic: "com.example.VaoPush", PrivateKey: string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: raw}))}
	sealed, e := f.a.seal(canonical(c))
	if e != nil {
		t.Fatal(e)
	}
	if bytes.Contains(sealed, []byte("PRIVATE KEY")) {
		t.Fatal("plaintext key")
	}
	opened, e := f.a.unseal(sealed)
	if e != nil || !bytes.Equal(opened, canonical(c)) {
		t.Fatal("encrypt roundtrip")
	}
	tampered := append([]byte{}, sealed...)
	tampered[len(tampered)-1] ^= 1
	if _, e = f.a.unseal(tampered); e == nil {
		t.Fatal("tamper accepted")
	}
	_, e = f.a.db.Exec(context.Background(), "INSERT INTO settings(key,value) VALUES('apns',$1)", sealed)
	if e != nil {
		t.Fatal(e)
	}
	seen := false
	s := &APNsSender{app: f.a, client: &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		seen = true
		if r.URL.Host != "api.sandbox.push.apple.com" || r.Header.Get("apns-push-type") != "widgets" || r.Header.Get("apns-topic") != "com.example.VaoPush.push-type.widgets" {
			t.Error("wrong APNs route")
		}
		jwt := strings.TrimPrefix(r.Header.Get("authorization"), "bearer ")
		parts := strings.Split(jwt, ".")
		if len(parts) != 3 {
			t.Fatal("invalid jwt")
		}
		signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
		digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
		if len(signature) != 64 || !ecdsa.Verify(&key.PublicKey, digest[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])) {
			t.Error("invalid signature")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Apns-Id": []string{"mock-apns-id"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}}
	r := s.Send(context.Background(), PushJob{ID: id("job_"), Kind: "widget", Token: strings.Repeat("ab", 32), Environment: "sandbox", Expires: time.Now().Add(time.Hour), Payload: []byte(`{"aps":{"content-changed":true}}`)})
	if !seen || r.Status != "accepted" {
		t.Fatal("mock APNs request failed")
	}
}
