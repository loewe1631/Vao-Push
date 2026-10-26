package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"github.com/jackc/pgx/v5"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

type APNsConfig struct {
	KeyID      string `json:"key_id"`
	TeamID     string `json:"team_id"`
	Topic      string `json:"topic"`
	PrivateKey string `json:"private_key"`
}

var appleID = regexp.MustCompile(`^[A-Z0-9]{10}$`)
var bundleID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]{2,180}$`)

func parseKey(text string) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(text))
	if block == nil {
		return nil, bad("invalid_private_key", "需要有效的Apple .p8私钥。")
	}
	key, e := x509.ParsePKCS8PrivateKey(block.Bytes)
	if e != nil {
		return nil, bad("invalid_private_key", "无法解析Apple私钥。")
	}
	ec, ok := key.(*ecdsa.PrivateKey)
	if !ok || ec.Curve != elliptic.P256() {
		return nil, bad("invalid_private_key", "私钥需使用P-256曲线。")
	}
	return ec, nil
}
func (a *App) seal(raw []byte) ([]byte, error) {
	key, e := hex.DecodeString(a.cfg.MasterKey)
	if e != nil {
		return nil, e
	}
	block, e := aes.NewCipher(key)
	if e != nil {
		return nil, e
	}
	gcm, e := cipher.NewGCM(block)
	if e != nil {
		return nil, e
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, e = rand.Read(nonce); e != nil {
		return nil, e
	}
	return gcm.Seal(nonce, nonce, raw, []byte(a.cfg.ID)), nil
}
func (a *App) unseal(raw []byte) ([]byte, error) {
	key, e := hex.DecodeString(a.cfg.MasterKey)
	if e != nil {
		return nil, e
	}
	block, e := aes.NewCipher(key)
	if e != nil {
		return nil, e
	}
	gcm, e := cipher.NewGCM(block)
	if e != nil {
		return nil, e
	}
	if len(raw) < gcm.NonceSize() {
		return nil, fmt.Errorf("invalid ciphertext")
	}
	return gcm.Open(nil, raw[:gcm.NonceSize()], raw[gcm.NonceSize():], []byte(a.cfg.ID))
}
func (a *App) appleConfig(ctx context.Context) (APNsConfig, error) {
	var c APNsConfig
	var b []byte
	e := a.db.QueryRow(ctx, "SELECT value FROM settings WHERE key='apns'").Scan(&b)
	if e != nil {
		return c, e
	}
	b, e = a.unseal(b)
	if e != nil {
		return c, e
	}
	e = json.Unmarshal(b, &c)
	return c, e
}
func (a *App) appleAdmin(r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var name string
	if e = a.db.QueryRow(r.Context(), "SELECT username FROM users WHERE id=$1", p.User).Scan(&name); e != nil {
		return e
	}
	if name != a.cfg.Username {
		return APIError{403, "admin_required", "仅服务管理员可配置苹果推送身份。"}
	}
	return nil
}
func (a *App) apnsInfo(w http.ResponseWriter, r *http.Request) error {
	if e := a.appleAdmin(r); e != nil {
		return e
	}
	c, e := a.appleConfig(r.Context())
	if e == pgx.ErrNoRows {
		ok(w, map[string]any{"configured": false})
		return nil
	}
	if e != nil {
		return e
	}
	ok(w, map[string]any{"configured": true, "key_id": c.KeyID, "team_id": c.TeamID, "topic": c.Topic})
	return nil
}
func (a *App) apnsSave(w http.ResponseWriter, r *http.Request) error {
	if e := a.appleAdmin(r); e != nil {
		return e
	}
	var c APNsConfig
	if e := decode(r, &c); e != nil {
		return e
	}
	if !appleID.MatchString(c.KeyID) || !appleID.MatchString(c.TeamID) || !bundleID.MatchString(c.Topic) {
		return bad("invalid_identity", "请填写有效的Key ID、Team ID与App Bundle ID。")
	}
	if _, e := parseKey(c.PrivateKey); e != nil {
		return e
	}
	sealed, e := a.seal(canonical(c))
	if e != nil {
		return e
	}
	_, e = a.db.Exec(r.Context(), "INSERT INTO settings(key,value) VALUES('apns',$1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", sealed)
	if e != nil {
		return e
	}
	_, e = a.db.Exec(r.Context(), "UPDATE outbox SET status='queued',available_at=now(),error=NULL WHERE status='blocked' AND expires_at>now()")
	if e != nil {
		return e
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}

type PushJob struct {
	ID, User, Device, Kind, Resource, Token, Environment string
	Payload                                              []byte
	Expires                                              time.Time
	Attempts                                             int
}
type PushResult struct{ Status, Reason, APNsID string }
type pushSender interface {
	Send(context.Context, PushJob) PushResult
}
type APNsSender struct {
	app     *App
	client  *http.Client
	mu      sync.Mutex
	jwt     string
	keyHash string
	issued  time.Time
}

func (s *APNsSender) authorization(c APNsConfig) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	kh := hash(string(canonical(c)))
	if s.jwt != "" && s.keyHash == kh && time.Since(s.issued) < 45*time.Minute {
		return s.jwt, nil
	}
	key, e := parseKey(c.PrivateKey)
	if e != nil {
		return "", e
	}
	enc := base64.RawURLEncoding.EncodeToString
	head := enc(canonical(map[string]string{"alg": "ES256", "kid": c.KeyID}))
	body := enc(canonical(map[string]any{"iss": c.TeamID, "iat": time.Now().Unix()}))
	input := head + "." + body
	digest := sha256.Sum256([]byte(input))
	r, v, e := ecdsa.Sign(rand.Reader, key, digest[:])
	if e != nil {
		return "", e
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	v.FillBytes(signature[32:])
	s.jwt = input + "." + enc(signature)
	s.keyHash = kh
	s.issued = time.Now()
	return s.jwt, nil
}
func (s *APNsSender) Send(ctx context.Context, j PushJob) PushResult {
	if j.Token == "" {
		return PushResult{Status: "blocked", Reason: "device_token_missing"}
	}
	c, e := s.app.appleConfig(ctx)
	if e == pgx.ErrNoRows {
		return PushResult{Status: "blocked", Reason: "apns_not_configured"}
	}
	if e != nil {
		return PushResult{Status: "blocked", Reason: "apns_config_unavailable"}
	}
	jwt, e := s.authorization(c)
	if e != nil {
		return PushResult{Status: "blocked", Reason: "apns_identity_invalid"}
	}
	host := "https://api.sandbox.push.apple.com"
	if j.Environment == "production" {
		host = "https://api.push.apple.com"
	} else if j.Environment != "sandbox" {
		return PushResult{Status: "failed", Reason: "invalid_environment"}
	}
	req, e := http.NewRequestWithContext(ctx, "POST", host+"/3/device/"+j.Token, bytes.NewReader(j.Payload))
	if e != nil {
		return PushResult{Status: "failed", Reason: "invalid_request"}
	}
	topic, pushType, priority := c.Topic, "alert", "10"
	if j.Kind == "widget" {
		topic += ".push-type.widgets"
		pushType = "widgets"
		priority = "5"
		req.Header.Set("apns-collapse-id", hash(s.app.cfg.ID+":"+j.Device+":widgets"))
	}
	raw := strings.TrimPrefix(j.ID, "job_")
	if len(raw) == 32 {
		req.Header.Set("apns-id", raw[:8]+"-"+raw[8:12]+"-"+raw[12:16]+"-"+raw[16:20]+"-"+raw[20:])
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", topic)
	req.Header.Set("apns-push-type", pushType)
	req.Header.Set("apns-priority", priority)
	req.Header.Set("apns-expiration", fmt.Sprint(j.Expires.Unix()))
	req.Header.Set("Content-Type", "application/json")
	res, e := s.client.Do(req)
	if e != nil {
		return PushResult{Status: "retry", Reason: "apns_network"}
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 2048))
	var detail struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(b, &detail)
	reason := detail.Reason
	if len(reason) > 80 {
		reason = "apns_rejected"
	}
	result := PushResult{Reason: reason, APNsID: res.Header.Get("apns-id")}
	switch {
	case res.StatusCode == 200:
		result.Status = "accepted"
		result.Reason = ""
	case res.StatusCode == 410:
		result.Status = "invalid"
	case res.StatusCode == 429 || res.StatusCode >= 500:
		result.Status = "retry"
	case res.StatusCode == 403:
		result.Status = "blocked"
	default:
		result.Status = "failed"
	}
	return result
}
func (a *App) worker(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			for i := 0; i < 20; i++ {
				if !a.workOne(ctx) {
					break
				}
			}
		}
	}
}
func (a *App) workOne(ctx context.Context) bool {
	_, e := a.db.Exec(ctx, "UPDATE outbox SET status='expired',lease_until=NULL,updated_at=now() WHERE expires_at<=now() AND status IN ('queued','retry','blocked','sending')")
	if e != nil {
		return false
	}
	var j PushJob
	e = a.db.QueryRow(ctx, `WITH next AS (SELECT id FROM outbox WHERE expires_at>now() AND ((status IN ('queued','retry','blocked') AND available_at<=now()) OR (status='sending' AND lease_until<now())) ORDER BY available_at FOR UPDATE SKIP LOCKED LIMIT 1) UPDATE outbox o SET status='sending',lease_until=now()+interval '45 seconds',attempts=attempts+1,updated_at=now() FROM next WHERE o.id=next.id RETURNING o.id,o.user_id,o.device_id,o.kind,o.resource_id,o.payload,o.expires_at,o.attempts`).Scan(&j.ID, &j.User, &j.Device, &j.Kind, &j.Resource, &j.Payload, &j.Expires, &j.Attempts)
	if e != nil {
		return false
	}
	var enabled, revoked bool
	var apns, widget *string
	e = a.db.QueryRow(ctx, "SELECT enabled,revoked,environment,apns_token,widget_token FROM devices WHERE id=$1 AND user_id=$2", j.Device, j.User).Scan(&enabled, &revoked, &j.Environment, &apns, &widget)
	result := PushResult{Status: "cancelled", Reason: "device_unavailable"}
	if e == nil && enabled && !revoked {
		t := apns
		if j.Kind == "widget" {
			t = widget
			var subscribed bool
			// Device streams and published Web cards use separate subscription stores.
			// Recheck both at send time so an unsubscribed card cannot retain delivery.
			e = a.db.QueryRow(ctx, `SELECT d.subscriptions ? $1 OR EXISTS(
                SELECT 1 FROM card_subscriptions cs
                JOIN card_templates t ON t.id=cs.card_id
                JOIN card_sources c ON c.id=t.source_id
                JOIN streams s ON s.id=c.stream_id
                WHERE cs.device_id=d.id AND t.published IS NOT NULL
                  AND (t.id=$1 OR s.data_id=$1)
            ) FROM devices d WHERE d.id=$2`, j.Resource, j.Device).Scan(&subscribed)
			if e != nil || !subscribed {
				_, _ = a.db.Exec(ctx, "UPDATE outbox SET status='cancelled',lease_until=NULL,updated_at=now() WHERE id=$1 AND status='sending'", j.ID)
				return true
			}
		}
		if t != nil {
			j.Token = *t
		}
		sendCtx, cancel := context.WithTimeout(ctx, 18*time.Second)
		result = a.push.Send(sendCtx, j)
		cancel()
	}
	delay := time.Duration(1<<min(j.Attempts, 8)) * time.Second
	if result.Status == "blocked" {
		delay = 60 * time.Second
	}
	if result.Status == "retry" && j.Attempts >= 10 {
		result.Status = "failed"
	}
	if result.Status == "invalid" {
		column := "apns_token"
		if j.Kind == "widget" {
			column = "widget_token"
		}
		_, _ = a.db.Exec(ctx, "UPDATE devices SET "+column+"=NULL WHERE id=$1 AND "+column+"=$2 AND environment=$3", j.Device, j.Token, j.Environment)
		result.Status = "failed"
	}
	_, _ = a.db.Exec(ctx, "UPDATE outbox SET status=$1,error=NULLIF($2,''),apns_id=NULLIF($3,''),available_at=$4,lease_until=NULL,updated_at=now() WHERE id=$5 AND status='sending'", result.Status, result.Reason, result.APNsID, time.Now().Add(delay), j.ID)
	return true
}
