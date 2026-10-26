package main

import (
	"strings"
	"testing"
)

func TestDeviceNamesDoNotReplaceIdentity(t *testing.T) {
	f := setup(t)
	a, b := f.automatic(t, "同名设备"), f.automatic(t, "同名设备")
	if a["binding_id"] == b["binding_id"] {
		t.Fatal("display name became the identity")
	}
	saved := f.saveRoute(t, []string{a["binding_id"].(string)})
	result(t, f.request("PUT", "/v1/device/name", map[string]any{"device_name": " 工作手机 "}, a["device_token"].(string), nil), 200)
	page := result(t, f.request("GET", "/v1/device/sync", nil, a["device_token"].(string), nil), 200)
	if page["device_name"] != "工作手机" || page["binding_id"] != a["binding_id"] {
		t.Fatal("rename changed the binding")
	}
	page = result(t, f.request("GET", "/v1/device/sync", nil, b["device_token"].(string), nil), 200)
	if page["device_name"] != "同名设备" {
		t.Fatal("rename affected another installation")
	}
	route := result(t, f.request("GET", "/v1/message-route", nil, "web", nil), 200)
	if route["revision"] != saved["revision"] || route["message_url"] != saved["message_url"] || route["device_ids"].([]any)[0] != a["binding_id"] {
		t.Fatal("rename changed saved recipients")
	}
	for _, name := range []string{"", "   ", "line\nline", strings.Repeat("界", 41)} {
		if f.request("PUT", "/v1/device/name", map[string]any{"device_name": name}, a["device_token"].(string), nil).Code != 422 {
			t.Fatal("invalid name accepted")
		}
		if f.request("POST", "/v1/register", map[string]any{"device_name": name, "platform": "ios", "registration_token": token()}, "", nil).Code != 422 {
			t.Fatal("invalid registration name accepted")
		}
	}
	for _, auth := range []string{a["send_key"].(string), a["read_token"].(string)} {
		if f.request("PUT", "/v1/device/name", map[string]any{"device_name": "No permission"}, auth, nil).Code != 403 {
			t.Fatal("restricted credential renamed device")
		}
	}
	if f.request("PUT", "/v1/device/name", map[string]any{"device_name": "Spoof", "device_id": b["binding_id"]}, a["device_token"].(string), nil).Code != 422 {
		t.Fatal("device could nominate another binding")
	}
	access := result(t, f.request("GET", "/v1/device/access", nil, a["device_token"].(string), nil), 200)
	if access["send_key"] != a["send_key"] {
		t.Fatal("rename changed sender credentials")
	}
}
