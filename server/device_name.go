package main

import (
	"net/http"
	"strings"
	"unicode"
)

func cleanDeviceName(raw string) (string, error) {
	name := strings.TrimSpace(raw)
	if name == "" || len(name) > 120 || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return "", bad("invalid_device_name", "请填写便于辨认的设备名称，不含换行或控制字符，最多120字节。")
	}
	return name, nil
}

func (a *App) renameDevice(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "device")
	if e != nil {
		return e
	}
	var b struct {
		Name string `json:"device_name"`
	}
	if e = decode(r, &b); e != nil {
		return e
	}
	name, e := cleanDeviceName(b.Name)
	if e != nil {
		return e
	}
	result, e := a.db.Exec(r.Context(), "UPDATE devices SET name=$3,updated_at=now() WHERE id=$1 AND user_id=$2 AND NOT revoked", p.Device, p.User, name)
	if e != nil {
		return e
	}
	if result.RowsAffected() != 1 {
		return unauthorized()
	}
	ok(w, map[string]bool{"ok": true})
	return nil
}
