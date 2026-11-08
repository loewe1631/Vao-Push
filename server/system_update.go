package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

func (a *App) systemUpdate(w http.ResponseWriter, r *http.Request) error {
	if _, e := a.authenticate(r, "web"); e != nil {
		return e
	}
	if a.cfg.UpdateSocket == "" {
		if r.Method != "GET" {
			return APIError{503, "update_not_configured", "升级执行器尚未配置。"}
		}
		ok(w, map[string]any{"configured": false, "current_version": ServerVersion, "message": "Web更新尚未启用。请执行一次保留数据的标准升级（--upgrade），无需重新安装；完成后可直接在此检查更新。"})
		return nil
	}
	path := "/state"
	var body []byte
	if strings.HasSuffix(r.URL.Path, "/check") {
		path = "/check"
	}
	if strings.HasSuffix(r.URL.Path, "/install") {
		path = "/install"
		var b struct {
			ReleaseID string `json:"release_id"`
			Confirm   bool   `json:"confirm"`
		}
		if e := decode(r, &b); e != nil {
			return e
		}
		if !b.Confirm || len(b.ReleaseID) != 64 {
			return bad("update_confirmation", "请先检查版本并明确确认升级。")
		}
		body = canonical(b)
	}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", a.cfg.UpdateSocket)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 25 * time.Second}
	req, e := http.NewRequestWithContext(r.Context(), r.Method, "http://localhost"+path, bytes.NewReader(body))
	if e != nil {
		return e
	}
	req.Header.Set("Content-Type", "application/json")
	resp, e := client.Do(req)
	if e != nil {
		return APIError{503, "update_agent_unavailable", "升级执行器暂不可用；原服务继续运行。"}
	}
	defer resp.Body.Close()
	raw, e := io.ReadAll(io.LimitReader(resp.Body, 128*1024+1))
	if e != nil || len(raw) > 128*1024 {
		return bad("update_response", "升级状态响应无效。")
	}
	var data map[string]any
	if json.Unmarshal(raw, &data) != nil {
		return bad("update_response", "升级状态响应无效。")
	}
	if resp.StatusCode >= 400 {
		return APIError{resp.StatusCode, "update_failed", stringValue(data["error"])}
	}
	data["configured"] = true
	data["running_version"] = ServerVersion
	ok(w, data)
	return nil
}
func stringValue(v any) string {
	if s, ok := v.(string); ok && len(s) < 500 {
		return s
	}
	return "升级操作未完成，请查看任务状态。"
}
