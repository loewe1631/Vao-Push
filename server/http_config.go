package main

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func validOrigin(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Hostname() != "" &&
		u.User == nil && u.Path == "" && u.RawQuery == "" && u.Fragment == "" && !u.ForceQuery &&
		u.String() == raw
}
func (c Config) validate() error {
	master, err := hex.DecodeString(c.MasterKey)
	if c.ID == "" || err != nil || len(master) != 32 || !validOrigin(c.PublicURL) {
		return errors.New("invalid server identity, encryption key, or public_url")
	}
	if c.WebURL != "" && !validOrigin(c.WebURL) {
		return errors.New("web_url must be an HTTP or HTTPS origin without a trailing slash")
	}
	if c.Listen == "" {
		return errors.New("listen is required")
	}
	if c.WebListen != "" && c.WebListen == c.Listen {
		return errors.New("listen and web_listen must differ; omit web_listen for a shared port")
	}
	return nil
}
func (a *App) webOrigin() string {
	if a.cfg.WebURL != "" {
		return a.cfg.WebURL
	}
	return a.cfg.PublicURL
}
func (a *App) secureWebCookie() bool { return strings.HasPrefix(a.webOrigin(), "https://") }

// With separate listeners, the API port exposes only device and ingress endpoints.
// Web requests use same-origin /v1 routes on web_listen; no CORS relaxation is needed.
func (a *App) deviceHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		allowed := path == "/healthz" || path == "/v1/info" || path == "/v1/register" ||
			path == "/v1/cards/redeem" || path == "/v1/pairings/claim" || path == "/v1/messages" ||
			path == "/v1/device" || strings.HasPrefix(path, "/v1/device/") ||
			path == "/v1/card-subscriptions" || strings.HasPrefix(path, "/v1/card-subscriptions/")
		for _, prefix := range []string{"/v1/push/", "/v1/state/", "/v1/card-data/", "/v1/widgets/"} {
			allowed = allowed || strings.HasPrefix(path, prefix)
		}
		if !allowed {
			http.NotFound(w, r)
			return
		}
		request := r.Clone(r.Context())
		request.Header = r.Header.Clone()
		request.Header.Del("Cookie")
		a.ServeHTTP(w, request)
	})
}
func (a *App) serveConfiguredHTTP(ctx context.Context) error {
	type endpoint struct {
		address string
		handler http.Handler
	}
	endpoints := []endpoint{{a.cfg.Listen, a}}
	if a.cfg.WebListen != "" {
		endpoints = []endpoint{{a.cfg.Listen, a.deviceHandler()}, {a.cfg.WebListen, a}}
	}
	servers := make([]*http.Server, 0, len(endpoints))
	listeners := make([]net.Listener, 0, len(endpoints))
	for _, endpoint := range endpoints {
		listener, err := net.Listen("tcp", endpoint.address)
		if err != nil {
			for _, previous := range listeners {
				_ = previous.Close()
			}
			return fmt.Errorf("cannot listen: %w", err)
		}
		listeners = append(listeners, listener)
		servers = append(servers, &http.Server{Handler: endpoint.handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 25 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384})
	}
	failures := make(chan error, len(servers))
	for i, server := range servers {
		listener := listeners[i]
		go func() { failures <- server.Serve(listener) }()
	}
	var err error
	select {
	case <-ctx.Done():
	case err = <-failures:
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, server := range servers {
		_ = server.Shutdown(shutdown)
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
