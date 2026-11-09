package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

func projectCard(d CardDesign, schema int) CardDesign {
	if d.Version == 3 && schema < 3 && d.Fallback != nil {
		d.Layout = d.Fallback.Layout
		d.Layouts = d.Fallback.Layouts
		d.Version = 2
		d.Fallback = nil
	}
	if schema < 2 {
		d.Version = 1
		d.Layouts = nil
	}
	return d
}
func stripV3(n LayoutNode) LayoutNode {
	n.VisibleWhen = ""
	n.HideIfEmpty = false
	n.Colors = nil
	n.BackgroundColors = nil
	n.States = nil
	n.UnknownState = nil
	n.Border = nil
	n.Prefix = ""
	n.Suffix = ""
	n.Symbol = ""
	n.ImageURL = ""
	n.IconSize = 0
	n.ChartStyle = ""
	n.Height = 0
	n.MinPoints = 0
	n.GapSeconds = 0
	if n.Color == "surface" {
		n.Color = "secondary"
	}
	if n.Background == "surface" {
		n.Background = "secondary"
	}
	if n.Type == "icon" {
		n.Type = "text"
	}
	if n.Type == "sparkline" {
		n.Type = "chart"
	}
	if n.Children != nil {
		children := make([]LayoutNode, len(n.Children))
		for i, c := range n.Children {
			children[i] = stripV3(c)
		}
		n.Children = children
	}
	if n.Row != nil {
		r := stripV3(*n.Row)
		n.Row = &r
	}
	return n
}
func hasV3(n LayoutNode) bool { return !bytes.Equal(canonical(n), canonical(stripV3(n))) }
func validNodeImage(raw string) bool {
	if len(raw) > 1024 || strings.Contains(raw, "#") {
		return false
	}
	u, e := url.Parse(raw)
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" || (u.Port() != "" && u.Port() != "443") {
		return false
	}
	host := strings.ToLower(strings.Trim(u.Hostname(), "."))
	if host == "localhost" || strings.HasSuffix(host, ".local") || !strings.Contains(host, ".") {
		return false
	}
	// Keep publication checks identical to the native URL policy so a valid
	// publication cannot fail the client's design validation before icon fallback.
	for _, prefix := range []string{"127.", "10.", "192.168.", "169.254.", "0."} {
		if strings.HasPrefix(host, prefix) {
			return false
		}
	}
	numericParts := 0
	for _, part := range strings.Split(host, ".") {
		if _, err := strconv.Atoi(part); err == nil {
			numericParts++
		}
	}
	if numericParts == 4 {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return false
	}
	return true
}

var symbolName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$`)

func validV3Color(c string) bool { return c == "surface" || validColor(c) }
func validPair(c *ColorPair) bool {
	return c == nil || c.Light != "" && c.Dark != "" && validV3Color(c.Light) && validV3Color(c.Dark)
}
func validStyle(s NodeStateStyle) bool {
	return (s.Text == nil || len(*s.Text) <= 120) && validV3Color(s.Color) && validV3Color(s.Background) && validPair(s.Colors) && validPair(s.BackgroundColors)
}
func validateDesign(raw []byte) (CardDesign, error) {
	var d CardDesign
	fail := func(msg string) (CardDesign, error) { return d, bad("invalid_design", msg) }
	if len(raw) > 65536 {
		return fail("卡片代码最多64KiB。")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if e := dec.Decode(&d); e != nil {
		return fail(e.Error())
	}
	if dec.Decode(new(any)) != io.EOF {
		return fail("只允许一个 JSON 对象。")
	}
	if d.Version != 3 {
		if d.Fallback != nil || hasV3(d.Layout) {
			return fail("新节点属性需要 schema 3。")
		}
		for _, n := range d.Layouts {
			if hasV3(n) {
				return fail("新节点属性需要 schema 3。")
			}
		}
		return validateLegacyDesign(raw)
	}
	if d.Fallback == nil {
		return fail("schema 3 必须保存固定的旧版 fallback 布局。")
	}
	legacy := projectCard(d, 2)
	if _, e := validateDesign(canonical(legacy)); e != nil {
		return fail("fallback: " + e.Error())
	}
	base := d
	base.Version = 2
	base.Fallback = nil
	base.Layout = stripV3(d.Layout)
	base.Layouts = map[string]LayoutNode{}
	for k, n := range d.Layouts {
		base.Layouts[k] = stripV3(n)
	}
	if _, e := validateLegacyDesign(canonical(base)); e != nil {
		return d, e
	}
	var visit func(LayoutNode) error
	visit = func(n LayoutNode) error {
		invalid := func(m string) error { return bad("invalid_design", n.ID+": "+m) }
		if n.VisibleWhen != "" && (!bindingPath.MatchString(n.VisibleWhen) || !strings.HasPrefix(n.VisibleWhen, "fields.")) {
			return invalid("visible_when 须绑定 fields.key。")
		}
		if !validV3Color(n.Color) || !validV3Color(n.Background) || !validPair(n.Colors) || !validPair(n.BackgroundColors) {
			return invalid("颜色或明暗色对无效。")
		}
		if len(n.States) > 16 || (len(n.States) > 0 || n.UnknownState != nil) && n.Type != "badge" {
			return invalid("状态映射仅用于 badge，最多16项。")
		}
		for k, s := range n.States {
			if len(k) == 0 || len(k) > 120 || !validStyle(s) {
				return invalid("状态映射无效。")
			}
		}
		if n.UnknownState != nil && !validStyle(*n.UnknownState) {
			return invalid("未知状态样式无效。")
		}
		if n.Border != nil && (n.Border.Width < 1 || n.Border.Width > 3 || !validV3Color(n.Border.Color) || !validPair(n.Border.Colors)) {
			return invalid("边框宽度须为1至3。")
		}
		if len(n.Prefix) > 32 || len(n.Suffix) > 32 || (n.Prefix != "" || n.Suffix != "") && n.Type != "number" && n.Type != "badge" {
			return invalid("数字前后缀最多32字节。")
		}
		if n.Type == "icon" {
			if n.Bind != "" || n.Symbol == "" && n.ImageURL == "" || n.Symbol != "" && !symbolName.MatchString(strings.TrimPrefix(n.Symbol, "sf:")) || n.ImageURL != "" && !validNodeImage(n.ImageURL) {
				return invalid("图标须为 SF Symbol 或公开 HTTPS 图片。")
			}
		} else if n.Symbol != "" || n.ImageURL != "" || n.IconSize != 0 {
			return invalid("图标属性仅用于 icon。")
		}
		if n.IconSize != 0 && (n.IconSize < 10 || n.IconSize > 48) {
			return invalid("图标尺寸须为10至48。")
		}
		if n.Type == "sparkline" {
			if !strings.HasPrefix(n.Bind, "series.") || !contains([]string{"", "line", "bar"}, n.ChartStyle) || n.Height != 0 && (n.Height < 16 || n.Height > 80) || n.MinPoints != 0 && (n.MinPoints < 2 || n.MinPoints > 60) || n.GapSeconds < 0 || n.GapSeconds > 604800 {
				return invalid("趋势图参数无效。")
			}
		} else if n.ChartStyle != "" || n.Height != 0 || n.MinPoints != 0 || n.GapSeconds != 0 {
			return invalid("趋势图属性仅用于 sparkline。")
		}
		for _, c := range n.Children {
			if e := visit(c); e != nil {
				return e
			}
		}
		if n.Row != nil {
			return visit(*n.Row)
		}
		return nil
	}
	trees := []LayoutNode{d.Layout}
	for _, n := range d.Layouts {
		trees = append(trees, n)
	}
	for _, n := range trees {
		if len(canonical(n)) > 24576 {
			return fail("单个布局最多24KiB。")
		}
		if e := visit(n); e != nil {
			return d, e
		}
	}
	return d, nil
}
