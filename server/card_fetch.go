package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var mappingKey = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,63}$`)

var sourcePath = regexp.MustCompile(`^\$?([A-Za-z0-9_-]+|\.[A-Za-z0-9_-]+|\[[0-9]+\])*(\.[A-Za-z0-9_-]+|\[[0-9]+\])*$`)

func validateSourceConfig(c SourceConfig) error {
	u, e := url.Parse(c.URL)
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" || len(c.URL) > 2048 {
		return bad("invalid_source_url", "API须为HTTPS地址，不含账号或片段。")
	}
	if ip := net.ParseIP(u.Hostname()); ip != nil && !publicSourceIP(ip) {
		return bad("invalid_source_url", "API须使用公网地址。")
	}
	if len(c.Headers) > 8 || len(c.Fields) < 1 || len(c.Fields) > 32 || len(c.ListPath) > 160 || len(c.ItemIDPath) > 160 {
		return bad("invalid_mapping", "字段映射或请求头数量无效。")
	}
	for k, v := range c.Headers {
		if !contains([]string{"Authorization", "X-API-Key", "X-Api-Key", "Accept"}, k) || len(v) > 2048 || strings.ContainsAny(v, "\r\n") {
			return bad("invalid_headers", "仅支持Authorization、X-API-Key和Accept请求头。")
		}
	}
	for _, path := range []string{c.ListPath, c.ItemIDPath} {
		if path != "" && path != "$" && !sourcePath.MatchString(path) {
			return bad("invalid_mapping", "路径仅支持点号和数字下标。")
		}
	}
	seen := map[string]bool{}
	for _, f := range c.Fields {
		if !mappingKey.MatchString(f.Key) || seen[f.Key] || f.Path == "" || len(f.Path) > 160 || !sourcePath.MatchString(f.Path) || !contains([]string{"text", "decimal", "integer", "percent", "boolean", "datetime"}, f.Type) || len(f.Label) > 120 || len(f.Unit) > 32 {
			return bad("invalid_mapping", "字段标识、路径或类型无效。")
		}
		seen[f.Key] = true
	}
	return nil
}
func publicSourceIP(ip net.IP) bool {
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	for _, cidr := range []string{"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "198.18.0.0/15", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4"} {
		_, block, _ := net.ParseCIDR(cidr)
		if block.Contains(ip) {
			return false
		}
	}
	return true
}
func sourceHTTPClient() *http.Client {
	transport := &http.Transport{MaxResponseHeaderBytes: 16384, TLSHandshakeTimeout: 5 * time.Second, ResponseHeaderTimeout: 8 * time.Second, DisableKeepAlives: true, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, e := net.SplitHostPort(address)
		if e != nil {
			return nil, e
		}
		ips, e := net.DefaultResolver.LookupIPAddr(ctx, host)
		if e != nil || len(ips) == 0 {
			return nil, bad("unreachable_source", "API不可达。")
		}
		for _, entry := range ips {
			if !publicSourceIP(entry.IP) {
				return nil, bad("private_source", "API须为公网地址。")
			}
		}
		dial := net.Dialer{Timeout: 5 * time.Second}
		return dial.DialContext(ctx, network, net.JoinHostPort(ips[0].IP.String(), port))
	}}
	return &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
func pathAt(value any, path string) any {
	path = strings.TrimPrefix(strings.TrimPrefix(path, "$"), ".")
	path = strings.ReplaceAll(strings.ReplaceAll(path, "[", "."), "]", "")
	if path == "" {
		return value
	}
	for _, key := range strings.Split(path, ".") {
		switch current := value.(type) {
		case map[string]any:
			value = current[key]
		case []any:
			i, e := strconv.Atoi(key)
			if e != nil || i < 0 || i >= len(current) {
				return nil
			}
			value = current[i]
		default:
			return nil
		}
	}
	return value
}
func mapSource(c SourceConfig, data any) (map[string]any, error) {
	found := 0
	fields := func(record any) map[string]any {
		out := map[string]any{}
		for _, f := range c.Fields {
			v := pathAt(record, f.Path)
			if v != nil {
				found++
			}
			if f.Type == "boolean" {
				if s, ok := v.(string); ok {
					if s == "true" {
						v = true
					} else if s == "false" {
						v = false
					}
				}
			} else {
				switch value := v.(type) {
				case json.Number:
					v = value.String()
				case bool:
					v = strconv.FormatBool(value)
				}
			}
			entry := map[string]any{"type": f.Type, "value": v}
			if f.Label != "" {
				entry["label"] = f.Label
			}
			if f.Unit != "" {
				entry["unit"] = f.Unit
			}
			out[f.Key] = entry
		}
		return out
	}
	state := map[string]any{"schema_version": 1, "source_updated_at": stamp(time.Now()), "valid_for_seconds": 3600}
	records := pathAt(data, c.ListPath)
	if list, ok := records.([]any); ok {
		if c.ItemIDPath == "" || len(list) > 20 {
			return nil, bad("invalid_mapping", "列表最多20项，并须设置稳定项目标识路径。")
		}
		items := []any{}
		for _, record := range list {
			key, ok := pathAt(record, c.ItemIDPath).(string)
			if !ok || key == "" {
				return nil, bad("invalid_mapping", "项目标识须为稳定字符串。")
			}
			items = append(items, map[string]any{"item_id": key, "fields": fields(record)})
		}
		state["items"] = items
	} else {
		if records == nil {
			return nil, bad("invalid_mapping", "找不到指定的记录路径。")
		}
		state["fields"] = fields(records)
	}
	if found == 0 {
		if list, ok := records.([]any); !ok || len(list) > 0 {
			return nil, bad("empty_mapping", "API没有返回映射字段，保留原内容。")
		}
	}
	if _, e := validateState(canonical(state)); e != nil {
		return nil, e
	}
	return state, nil
}
func fetchSource(ctx context.Context, c SourceConfig) (map[string]any, error) {
	if e := validateSourceConfig(c); e != nil {
		return nil, e
	}
	req, e := http.NewRequestWithContext(ctx, "GET", c.URL, nil)
	if e != nil {
		return nil, e
	}
	req.Header.Set("Accept", "application/json")
	for k, v := range c.Headers {
		req.Header.Set(k, v)
	}
	client := sourceHTTPClient()
	defer client.CloseIdleConnections()
	response, e := client.Do(req)
	if e != nil {
		return nil, e
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || !strings.Contains(strings.ToLower(response.Header.Get("Content-Type")), "json") {
		return nil, bad("invalid_response", "API未返回JSON。")
	}
	raw, e := io.ReadAll(io.LimitReader(response.Body, 262145))
	if e != nil {
		return nil, e
	}
	if len(raw) > 262144 {
		return nil, bad("source_too_large", "API响应最多256KiB。")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var data any
	if e = decoder.Decode(&data); e != nil {
		return nil, e
	}
	return mapSource(c, data)
}
