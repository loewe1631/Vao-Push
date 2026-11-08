package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

type publicationWarning struct {
	Code    string `json:"code"`
	Family  string `json:"family"`
	Node    string `json:"node_id,omitempty"`
	Message string `json:"message"`
	English string `json:"message_en"`
}
type publicationLayout struct {
	Family string `json:"family"`
	Nodes  int    `json:"nodes"`
	Bytes  int    `json:"bytes"`
}
type publicationReport struct {
	Draft    string               `json:"draft_revision"`
	Token    string               `json:"confirmation_token"`
	Ready    bool                 `json:"ready"`
	Warnings []publicationWarning `json:"warnings"`
	Layouts  []publicationLayout  `json:"layouts"`
	Omitted  int                  `json:"omitted_warnings"`
}

func publicationToken(raw, published, state []byte, draft, revision int64) string {
	return hash(string(canonical([]any{json.RawMessage(raw), json.RawMessage(published), json.RawMessage(state), draft, revision})))
}
func flattenLayout(root LayoutNode) map[string]LayoutNode {
	result := map[string]LayoutNode{}
	var visit func(LayoutNode)
	visit = func(n LayoutNode) {
		result[n.ID] = n
		for _, c := range n.Children {
			visit(c)
		}
		if n.Row != nil {
			visit(*n.Row)
		}
	}
	visit(root)
	return result
}
func effectiveLayout(d CardDesign, family string) LayoutNode {
	if n, ok := d.Layouts[family]; ok {
		return n
	}
	return d.Layout
}
func inspectPublication(design CardDesign, previous *CardDesign, state []byte) publicationReport {
	report := publicationReport{Ready: true, Warnings: []publicationWarning{}, Layouts: []publicationLayout{}}
	seen := map[string]bool{}
	warn := func(code, family, node, zh, en string) {
		key := code + ":" + family + ":" + node
		if seen[key] {
			return
		}
		seen[key] = true
		report.Warnings = append(report.Warnings, publicationWarning{code, family, node, zh, en})
	}
	var data map[string]any
	_ = json.Unmarshal(state, &data)
	if len(state) == 0 || string(state) == "null" {
		report.Ready = false
		warn("no_data", "default", "", "请先接入有效数据。", "Connect valid source data first.")
	} else if e := validateDesignBindings(design, state); e != nil {
		report.Ready = false
		message := e.Error()
		if detail, ok := e.(APIError); ok {
			message = detail.Message
		}
		warn("binding_error", "default", "", message, "A field is missing or has an incompatible type. Check bindings in every layout.")
	}
	families := []string{"default", "small", "medium", "large", "extraLarge"}
	for _, family := range families {
		tree := design.Layout
		if family != "default" {
			var ok bool
			tree, ok = design.Layouts[family]
			if !ok {
				continue
			}
		}
		single := design
		single.Version = 1
		single.Layouts = nil
		single.Layout = tree
		report.Layouts = append(report.Layouts, publicationLayout{family, len(flattenLayout(tree)), len(canonical(single))})
		var visit func(LayoutNode, map[string]any)
		visit = func(n LayoutNode, scope map[string]any) {
			fields, _ := scope["fields"].(map[string]any)
			key := strings.TrimPrefix(n.Bind, "fields.")
			field, _ := fields[key].(map[string]any)
			kind, _ := field["type"].(string)
			if n.Bind != "" && n.Text == "" && n.Type != "chart" {
				if field == nil || field["value"] == nil {
					warn("empty_field", family, n.ID, "字段缺失或为 null，手机将显示“不可用”；不会自动隐藏节点。", "Missing/null fields display Unavailable; they do not hide the node.")
				}
				if n.Decimals != nil && kind == "text" && n.Format == "" {
					warn("text_decimals", family, n.ID, "绑定的是文本字段，小数位设置在 App 中不会生效。", "Decimal places do not change a text field in the app.")
				}
			}
			if n.ColorRule == "signed" || n.Format == "decimal" || n.Format == "percent" {
				value, validString := field["value"].(string)
				_, numberError := decimal(value, false)
				if field != nil && field["value"] != nil && (!validString || numberError != nil) {
					if n.Format == "decimal" || n.Format == "percent" {
						warn("invalid_numeric", family, n.ID, "该字段不是有效数字，强制数值格式会显示“不可用”；请检查字段类型或绑定。", "This field is not a valid decimal; forced numeric formatting displays Unavailable. Check its type or binding.")
					} else {
						warn("invalid_numeric", family, n.ID, "条件颜色需要有效数字；当前将使用次要颜色，文字内容照常显示。", "Signed colors need a decimal; this field uses the secondary color while retaining its text.")
					}
				}
			}
			if n.Type == "badge" && n.Background != "" {
				warn("badge_background", family, n.ID, "背景设置作用于 badge 外层，内部胶囊仍使用内置底色；静态色块可使用文字胶囊。", "A badge background styles its outer node; the inner pill keeps the built-in fill. Use a text pill for a static fill.")
			}
			if strings.HasPrefix(n.Color, "#") || strings.HasPrefix(n.Background, "#") {
				warn("fixed_color", family, n.ID, "自定义颜色不会自动切换明暗色值，请分别检查两种外观。", "Custom hex colors keep the same value in light and dark; check both appearances.")
			}
			if n.Type == "chart" {
				series, _ := scope["series"].(map[string]any)
				v, _ := series[strings.TrimPrefix(n.Bind, "series.")].(map[string]any)
				points, _ := v["points"].([]any)
				if len(points) < 2 {
					warn("chart_samples", family, n.ID, "历史序列不足两个点，无法形成可读趋势；不会自动收起图表。", "Fewer than two samples cannot show a readable trend; the chart does not collapse automatically.")
				}
			}
			for _, child := range n.Children {
				visit(child, scope)
			}
			if n.Row != nil {
				items, _ := data["items"].([]any)
				for _, item := range items {
					record, _ := item.(map[string]any)
					visit(*n.Row, record)
				}
			}
		}
		visit(tree, data)
	}
	if previous != nil {
		for _, family := range families {
			oldTree, nextTree := previous.Layout, design.Layout
			if family != "default" {
				oldTree = effectiveLayout(*previous, family)
				nextTree = effectiveLayout(design, family)
			}
			old, next := flattenLayout(oldTree), flattenLayout(nextTree)
			ids := make([]string, 0, len(old))
			for id := range old {
				ids = append(ids, id)
			}
			sort.Strings(ids)
			for _, id := range ids {
				before, after := old[id], next[id]
				if after.ID == "" || before.Type != after.Type {
					warn("node_identity", family, id, "已发布节点被删除或更换类型；有本机微调的设备可能保留旧设计并提示冲突。", "A published node was removed or changed type; devices with local adjustments may keep the old design and report a conflict.")
				} else if before.Bind != after.Bind {
					warn("binding_changed", family, id, "字段绑定已改变，设备原有微调会应用到新字段，请核对含义。", "The binding changed; existing local adjustments will apply to the new field.")
				}
			}
		}
	}
	priority := func(code string) int {
		switch code {
		case "node_identity", "binding_error", "no_data":
			return 0
		case "binding_changed", "invalid_numeric", "text_decimals":
			return 1
		default:
			return 2
		}
	}
	sort.SliceStable(report.Warnings, func(i, j int) bool { return priority(report.Warnings[i].Code) < priority(report.Warnings[j].Code) })
	if len(report.Warnings) > 160 {
		report.Omitted = len(report.Warnings) - 160
		report.Warnings = report.Warnings[:160]
	}
	return report
}
func (a *App) cardPublicationCheck(w http.ResponseWriter, r *http.Request) error {
	p, e := a.authenticate(r, "web")
	if e != nil {
		return e
	}
	var raw, published, state []byte
	var draft, revision int64
	e = a.db.QueryRow(r.Context(), `SELECT t.draft,t.published,s.state,t.draft_revision,t.revision FROM card_templates t JOIN card_sources c ON c.id=t.source_id JOIN streams s ON s.id=c.stream_id WHERE t.id=$1 AND t.user_id=$2`, r.PathValue("id"), p.User).Scan(&raw, &published, &state, &draft, &revision)
	if e == pgx.ErrNoRows {
		return notfound()
	}
	if e != nil {
		return e
	}
	if r.Header.Get("If-Match") != fmt.Sprintf(`"draft-%d"`, draft) {
		return APIError{412, "draft_conflict", "草稿已变化，请重新保存并检查。"}
	}
	design, e := validateDesign(raw)
	if e != nil {
		return e
	}
	var previous *CardDesign
	if len(published) > 0 && string(published) != "null" {
		var value CardDesign
		if e = json.Unmarshal(published, &value); e != nil {
			return e
		}
		previous = &value
	}
	report := inspectPublication(design, previous, state)
	report.Draft = strconv.FormatInt(draft, 10)
	report.Token = publicationToken(raw, published, state, draft, revision)
	ok(w, report)
	return nil
}
