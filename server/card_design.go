package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
)

type CardDesign struct {
	Version  int                   `json:"schema_version"`
	Name     string                `json:"name"`
	Family   string                `json:"family"`
	Theme    string                `json:"theme,omitempty"`
	Layout   LayoutNode            `json:"layout"`
	Layouts  map[string]LayoutNode `json:"layouts,omitempty"`
	Fallback *CardFallback         `json:"fallback,omitempty"`
}
type CardFallback struct {
	Layout  LayoutNode            `json:"layout"`
	Layouts map[string]LayoutNode `json:"layouts,omitempty"`
}
type ColorPair struct {
	Light string `json:"light"`
	Dark  string `json:"dark"`
}
type NodeStateStyle struct {
	Text             *string    `json:"text,omitempty"`
	Color            string     `json:"color,omitempty"`
	Colors           *ColorPair `json:"colors,omitempty"`
	Background       string     `json:"background,omitempty"`
	BackgroundColors *ColorPair `json:"background_colors,omitempty"`
}
type NodeBorder struct {
	Color  string     `json:"color,omitempty"`
	Colors *ColorPair `json:"colors,omitempty"`
	Width  int        `json:"width"`
}
type LayoutNode struct {
	VisibleWhen      string                    `json:"visible_when,omitempty"`
	HideIfEmpty      bool                      `json:"hide_if_empty,omitempty"`
	Colors           *ColorPair                `json:"colors,omitempty"`
	BackgroundColors *ColorPair                `json:"background_colors,omitempty"`
	States           map[string]NodeStateStyle `json:"states,omitempty"`
	UnknownState     *NodeStateStyle           `json:"unknown_state,omitempty"`
	Border           *NodeBorder               `json:"border,omitempty"`
	Prefix           string                    `json:"prefix,omitempty"`
	Suffix           string                    `json:"suffix,omitempty"`
	Symbol           string                    `json:"symbol,omitempty"`
	ImageURL         string                    `json:"image_url,omitempty"`
	IconSize         int                       `json:"icon_size,omitempty"`
	ChartStyle       string                    `json:"chart_style,omitempty"`
	Height           int                       `json:"height,omitempty"`
	MinPoints        int                       `json:"min_points,omitempty"`
	GapSeconds       int                       `json:"gap_seconds,omitempty"`
	ID               string                    `json:"id"`
	Type             string                    `json:"type"`
	Text             string                    `json:"text,omitempty"`
	Label            string                    `json:"label,omitempty"`
	Bind             string                    `json:"bind,omitempty"`
	Format           string                    `json:"format,omitempty"`
	Decimals         *int                      `json:"decimals,omitempty"`
	ColorRule        string                    `json:"color_rule,omitempty"`
	Color            string                    `json:"color,omitempty"`
	Background       string                    `json:"background,omitempty"`
	FontSize         int                       `json:"font_size,omitempty"`
	Weight           string                    `json:"weight,omitempty"`
	Alignment        string                    `json:"alignment,omitempty"`
	Spacing          *int                      `json:"spacing,omitempty"`
	Padding          int                       `json:"padding,omitempty"`
	Radius           int                       `json:"radius,omitempty"`
	Flex             *int                      `json:"flex,omitempty"`
	Columns          int                       `json:"columns,omitempty"`
	Limit            int                       `json:"limit,omitempty"`
	Source           string                    `json:"source,omitempty"`
	Children         []LayoutNode              `json:"children,omitempty"`
	Row              *LayoutNode               `json:"row,omitempty"`
}

var nodeID = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]{0,63}$`)
var bindingPath = regexp.MustCompile(`^(fields|series)\.[A-Za-z][A-Za-z0-9_]{0,63}$`)
var hexColor = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)

func validColor(s string) bool {
	return s == "" || contains([]string{"primary", "secondary", "accent"}, s) || hexColor.MatchString(s)
}
func validateLegacyDesign(raw []byte) (CardDesign, error) {
	var d CardDesign
	fail := func(path, msg string) (CardDesign, error) { return d, bad("invalid_design", path+": "+msg) }
	if len(raw) > 65536 {
		return fail("$", "卡片代码最多24KiB。")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if e := dec.Decode(&d); e != nil {
		return fail("$", e.Error())
	}
	if (d.Version != 1 && d.Version != 2) || len(d.Name) < 1 || len(d.Name) > 120 || !contains([]string{"small", "medium", "large", "extraLarge"}, d.Family) || !contains([]string{"", "system", "light", "dark"}, d.Theme) {
		return fail("$", "请检查版本、名称、尺寸与主题。")
	}
	if d.Version == 1 && (len(raw) > 24576 || len(d.Layouts) > 0) {
		return fail("$", "v1最多24KiB且不接收尺寸布局。")
	}
	if len(d.Layouts) > 4 {
		return fail("$.layouts", "至多四种尺寸。")
	}
	if d.Version == 2 {
		legacy := d
		legacy.Version = 1
		legacy.Layouts = nil
		if _, e := validateLegacyDesign(canonical(legacy)); e != nil {
			return fail("$.layout", "默认布局不兼容旧客户端："+e.Error())
		}
		for family, layout := range d.Layouts {
			if !contains([]string{"small", "medium", "large", "extraLarge"}, family) {
				return fail("$.layouts", "未知尺寸。")
			}
			variant := legacy
			variant.Layout = layout
			if _, e := validateLegacyDesign(canonical(variant)); e != nil {
				return fail("$.layouts."+family, e.Error())
			}
		}
	}
	seen := map[string]bool{}
	count := 0
	var visit func(LayoutNode, int, string) error
	visit = func(n LayoutNode, depth int, path string) error {
		count++
		err := func(m string) error { return bad("invalid_design", path+": "+m) }
		if depth > 6 || count > 64 {
			return err("最多6层、64个组件。")
		}
		if !nodeID.MatchString(n.ID) || seen[n.ID] {
			return err("组件id须唯一且有效。")
		}
		seen[n.ID] = true
		if !contains([]string{"row", "column", "grid", "list", "text", "number", "badge", "divider", "spacer", "chart"}, n.Type) {
			return err("不支持的组件类型。")
		}
		if len(n.Text) > 500 || len(n.Label) > 120 || !validColor(n.Color) || !validColor(n.Background) || n.FontSize != 0 && (n.FontSize < 10 || n.FontSize > 32) || n.Spacing != nil && (*n.Spacing < 0 || *n.Spacing > 24) || n.Padding < 0 || n.Padding > 24 || n.Radius < 0 || n.Radius > 24 || n.Flex != nil && (*n.Flex < 0 || *n.Flex > 4) || n.Decimals != nil && (*n.Decimals < 0 || *n.Decimals > 18) || !contains([]string{"", "regular", "medium", "semibold", "bold"}, n.Weight) || !contains([]string{"", "leading", "center", "trailing"}, n.Alignment) || !contains([]string{"", "signed"}, n.ColorRule) || !contains([]string{"", "percent", "decimal"}, n.Format) {
			return err("样式参数无效。")
		}
		if n.Bind != "" && !bindingPath.MatchString(n.Bind) {
			return err("绑定须为fields.key或series.key。")
		}
		if n.Type == "chart" && (len(n.Bind) < 7 || n.Bind[:7] != "series.") {
			return err("图表须绑定series.key。")
		}
		if n.Type != "chart" && len(n.Bind) > 0 && n.Bind[:7] == "series." {
			return err("该组件须绑定字段。")
		}
		container := contains([]string{"row", "column", "grid"}, n.Type)
		if container {
			if len(n.Children) < 1 || len(n.Children) > 12 || n.Row != nil {
				return err("容器须有1至12个子组件。")
			}
		} else if len(n.Children) > 0 {
			return err("该类型不接收children。")
		}
		if n.Type == "grid" {
			if n.Columns < 1 || n.Columns > 4 {
				return err("网格列数须为1至4。")
			}
		} else if n.Columns != 0 {
			return err("columns仅用于grid。")
		}
		if n.Type == "list" {
			if n.Source != "items" || n.Row == nil || n.Limit < 1 || n.Limit > 20 {
				return err("列表须包含source:items、row和1至20的limit。")
			}
		} else if n.Row != nil || n.Source != "" || n.Limit != 0 {
			return err("source/row/limit仅用于list。")
		}
		for i, c := range n.Children {
			if e := visit(c, depth+1, fmt.Sprintf("%s.children[%d]", path, i)); e != nil {
				return e
			}
		}
		if n.Row != nil {
			return visit(*n.Row, depth+1, path+".row")
		}
		return nil
	}
	if e := visit(d.Layout, 1, "$.layout"); e != nil {
		return d, e
	}
	return d, nil
}
