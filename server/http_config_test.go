package main

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublicOrigins(t *testing.T) {
	for _, origin := range []string{"http://192.0.2.1:8188", "https://example.com:18188", "http://[2001:db8::1]:8188"} {
		if !validOrigin(origin) {
			t.Errorf("valid origin rejected: %s", origin)
		}
	}
	for _, origin := range []string{"ftp://example.com", "https://user:pass@example.com", "http://example.com/path", "http://example.com?token=x", "http://example.com#x", "https://example.com/", "http://example.com?"} {
		if validOrigin(origin) {
			t.Errorf("invalid origin accepted: %s", origin)
		}
	}
}

func TestHTTPWebSessionAndOrigin(t *testing.T) {
	f := setup(t)
	f.a.cfg.PublicURL = "http://192.0.2.1:8188"
	f.a.cfg.WebURL = "http://192.0.2.1:18188"
	r := f.request("POST", "/v1/auth/login", map[string]string{"username": "admin", "password": "test-password-example"}, "", map[string]string{"Origin": f.a.cfg.WebURL})
	login := result(t, r, 200)
	cookies := r.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Secure || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatal("HTTP session cookie settings")
	}
	request := httptest.NewRequest("GET", "http://192.0.2.1:18188/v1/auth/me", nil)
	request.AddCookie(cookies[0])
	rec := httptest.NewRecorder()
	f.a.ServeHTTP(rec, request)
	result(t, rec, 200)
	for _, origin := range []string{"http://192.0.2.1:8188", "http://evil.invalid:18188", ""} {
		if f.request("PUT", "/v1/message-route", map[string]any{"device_ids": []string{}}, "web", map[string]string{"Origin": origin, "If-Match": "\"route-0\""}).Code != 403 {
			t.Fatal("origin check was relaxed")
		}
	}
	request = httptest.NewRequest("POST", "http://192.0.2.1:18188/v1/auth/logout", bytes.NewReader([]byte("{}")))
	request.AddCookie(cookies[0])
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", f.a.cfg.WebURL)
	request.Header.Set("X-CSRF-Token", login["csrf_token"].(string))
	rec = httptest.NewRecorder()
	f.a.ServeHTTP(rec, request)
	result(t, rec, 200)
	if rec.Result().Cookies()[0].Secure {
		t.Fatal("HTTP logout cookie could not be cleared")
	}
	f.a.cfg.WebURL = "https://push.example.com:18188"
	r = f.request("POST", "/v1/auth/login", map[string]string{"username": "admin", "password": "test-password-example"}, "", map[string]string{"Origin": f.a.cfg.WebURL, "X-Forwarded-Proto": "http"})
	result(t, r, 200)
	if !r.Result().Cookies()[0].Secure {
		t.Fatal("HTTPS session was downgraded by an untrusted request header")
	}
}

func TestAPIListenerExcludesConsoleAndCookieAuthentication(t *testing.T) {
	f := setup(t)
	for _, path := range []string{"/", "/v1/auth/login", "/v1/dashboard", "/v1/apns", "/v1/cards", "/v1/card-sources", "/v1/devices/x/access"} {
		request := httptest.NewRequest("GET", path, nil)
		rec := httptest.NewRecorder()
		f.a.deviceHandler().ServeHTTP(rec, request)
		if rec.Code != 404 {
			t.Errorf("console endpoint exposed on API port: %s", path)
		}
	}
	request := httptest.NewRequest("GET", "/v1/info", nil)
	rec := httptest.NewRecorder()
	f.a.deviceHandler().ServeHTTP(rec, request)
	result(t, rec, 200)
	request = httptest.NewRequest("POST", "/v1/messages", strings.NewReader("{}"))
	request.AddCookie(&http.Cookie{Name: "vao_session", Value: f.session})
	request.Header.Set("Origin", f.a.cfg.PublicURL)
	request.Header.Set("X-CSRF-Token", f.csrf)
	request.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	f.a.deviceHandler().ServeHTTP(rec, request)
	if rec.Code != 401 {
		t.Fatal("API port accepted a browser session")
	}
}

func TestTwoPortStartupClosesPartialListener(t *testing.T) {
	first, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	firstAddr := first.Addr().String()
	_ = first.Close()
	busy, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer busy.Close()
	a := &App{cfg: Config{Listen: firstAddr, WebListen: busy.Addr().String()}}
	if a.serveConfiguredHTTP(context.Background()) == nil {
		t.Fatal("occupied web port did not stop startup")
	}
	again, e := net.Listen("tcp", firstAddr)
	if e != nil {
		t.Fatal("partial listener was left open")
	}
	_ = again.Close()
}
