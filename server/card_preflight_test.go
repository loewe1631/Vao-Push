package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestPublicationCheckIsReadOnlyAndProtectsCheckedVersion(t *testing.T) {
	f := setup(t)
	source := f.cardSource(t)
	card := f.publishedCard(t, source)
	cid := card["id"].(string)
	design := sampleDesign()
	children := design["layout"].(map[string]any)["row"].(map[string]any)["children"].([]any)
	children[0].(map[string]any)["type"] = "badge"
	result(t, f.request("PUT", "/v1/cards/"+cid, map[string]any{"design": design}, "web", map[string]string{"If-Match": `"draft-1"`}), 200)
	path := "/v1/cards/" + cid + "/publication-check"
	headers := map[string]string{"If-Match": `"draft-2"`}
	checked := result(t, f.request("GET", path, nil, "web", headers), 200)
	if checked["ready"] != true || checked["draft_revision"] != "2" {
		t.Fatal("usable draft did not pass")
	}
	found := false
	for _, warning := range checked["warnings"].([]any) {
		if warning.(map[string]any)["code"] == "node_identity" {
			found = true
		}
	}
	if !found {
		t.Fatal("type change did not report local-adjustment risk")
	}
	again := result(t, f.request("GET", path, nil, "web", headers), 200)
	if again["confirmation_token"] != checked["confirmation_token"] {
		t.Fatal("read-only report token changed")
	}
	var revision int
	if e := f.a.db.QueryRow(context.Background(), "SELECT revision FROM card_templates WHERE id=$1", cid).Scan(&revision); e != nil || revision != 1 {
		t.Fatal("preflight published a card", e)
	}
	other := fixture{a: f.a, uid: id("acct_"), session: token(), csrf: token()}
	if _, e := f.a.db.Exec(context.Background(), "INSERT INTO users(id,username,password) VALUES($1,$2,$3)", other.uid, "other-admin", []byte{}); e != nil {
		t.Fatal(e)
	}
	if _, e := f.a.db.Exec(context.Background(), "INSERT INTO sessions(hash,user_id,csrf,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')", hash(other.session), other.uid, other.csrf); e != nil {
		t.Fatal(e)
	}
	if other.request("GET", path, nil, "web", headers).Code != 404 {
		t.Fatal("another administrator accessed the report")
	}
	device := f.automatic(t, "Forbidden")
	if f.request("GET", path, nil, device["device_token"].(string), headers).Code != 403 {
		t.Fatal("device accessed administrator report")
	}
	if f.request("GET", path, nil, "", headers).Code != 401 {
		t.Fatal("anonymous accessed report")
	}
	if f.request("GET", path, nil, "web", map[string]string{"If-Match": `"draft-1"`}).Code != 412 {
		t.Fatal("stale draft checked")
	}
	if f.request("GET", "/v1/cards/card_missing/publication-check", nil, "web", headers).Code != 404 {
		t.Fatal("missing card exposed")
	}
	result(t, f.request("PUT", strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL), map[string]any{"fields": map[string]any{"changed": map[string]any{"type": "text", "value": "new"}}}, "", nil), 202)
	headers["X-Vao-Publication-Check"] = checked["confirmation_token"].(string)
	if f.request("POST", "/v1/cards/"+cid+"/publish", map[string]any{}, "web", headers).Code != 412 {
		t.Fatal("data changed after check but publication continued")
	}
	// Existing callers retain the original v1 publish contract without the optional header.
	delete(headers, "X-Vao-Publication-Check")
	result(t, f.request("POST", "/v1/cards/"+cid+"/publish", map[string]any{}, "web", headers), 200)
}
func TestPublicationWarningsPreserveZeroAndDiagnoseTextAndEverySize(t *testing.T) {
	design := CardDesign{Version: 2, Name: "Demo", Family: "medium", Layout: LayoutNode{ID: "root", Type: "column", Children: []LayoutNode{{ID: "text", Type: "text", Bind: "fields.text", Decimals: intPointer(2)}, {ID: "zero", Type: "number", Bind: "fields.zero"}}}, Layouts: map[string]LayoutNode{"small": {ID: "root", Type: "text", Bind: "fields.empty"}}}
	raw := canonical(map[string]any{"fields": map[string]any{"text": map[string]any{"type": "text", "value": "123.456"}, "zero": map[string]any{"type": "decimal", "value": "0"}, "empty": map[string]any{"type": "text", "value": nil}}})
	report := inspectPublication(design, nil, raw)
	if !report.Ready || len(report.Layouts) != 2 {
		t.Fatal("valid zero rejected or size ignored")
	}
	seen := map[string]bool{}
	for _, warning := range report.Warnings {
		seen[warning.Code+":"+warning.Node] = true
		if warning.Node == "zero" {
			t.Fatal("zero incorrectly reported empty")
		}
	}
	if !seen["text_decimals:text"] || !seen["empty_field:root"] {
		t.Fatal("missing field diagnostics", seen)
	}
}
func intPointer(value int) *int { return &value }

func TestPublicationWarningLimitKeepsAdjustmentConflictsVisible(t *testing.T) {
	root := LayoutNode{ID: "root", Type: "column"}
	for g := 0; g < 5; g++ {
		group := LayoutNode{ID: fmt.Sprintf("group%d", g), Type: "column"}
		for i := 0; i < 10; i++ {
			group.Children = append(group.Children, LayoutNode{ID: fmt.Sprintf("node%d_%d", g, i), Type: "text", Text: "Status", Color: "#315D8A"})
		}
		root.Children = append(root.Children, group)
	}
	before := CardDesign{Version: 2, Name: "Demo", Family: "medium", Layout: root, Layouts: map[string]LayoutNode{}}
	for _, family := range []string{"small", "medium", "large", "extraLarge"} {
		before.Layouts[family] = root
	}
	var after CardDesign
	if e := json.Unmarshal(canonical(before), &after); e != nil {
		t.Fatal(e)
	}
	after.Layout.Children[4].Children[9].Type = "badge"
	for family := range after.Layouts {
		after.Layouts[family] = after.Layout
	}
	if _, e := validateDesign(canonical(after)); e != nil {
		t.Fatal(e)
	}
	report := inspectPublication(after, &before, canonical(map[string]any{"fields": map[string]any{}}))
	if report.Omitted == 0 || len(report.Warnings) != 160 || report.Warnings[0].Code != "node_identity" {
		t.Fatal("warning limit lost the critical changes")
	}
	count := 0
	for _, warning := range report.Warnings {
		if warning.Code == "node_identity" {
			count++
		}
	}
	if count != 5 {
		t.Fatal("not every affected size retained its adjustment warning", count)
	}
}
