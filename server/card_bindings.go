package main

import (
	"encoding/json"
	"fmt"
)

func validateDesignBindings(design CardDesign, raw []byte) error {
	var state map[string]any
	if e := json.Unmarshal(raw, &state); e != nil {
		return e
	}
	var visit func(LayoutNode, map[string]any, string) error
	visit = func(node LayoutNode, scope map[string]any, path string) error {
		if node.Bind != "" && node.Text == "" {
			var group, key string
			for i, c := range node.Bind {
				if c == '.' {
					group = node.Bind[:i]
					key = node.Bind[i+1:]
					break
				}
			}
			values, _ := scope[group].(map[string]any)
			value, exists := values[key]
			if !exists && !node.HideIfEmpty && node.VisibleWhen == "" && node.Type != "sparkline" {
				return bad("unmatched_binding", path+": "+node.Bind+" 不存在于当前数据作用域。")
			}
			if exists && node.Type == "number" {
				field, _ := value.(map[string]any)
				kind, _ := field["type"].(string)
				if !contains([]string{"decimal", "integer", "percent"}, kind) {
					return bad("binding_type", path+": 数值组件须绑定数值字段。")
				}
			}
		}
		for i, child := range node.Children {
			if e := visit(child, scope, fmt.Sprintf("%s.children[%d]", path, i)); e != nil {
				return e
			}
		}
		if node.Row != nil {
			items, _ := state["items"].([]any)
			if len(items) > 0 {
				union := map[string]any{}
				for _, item := range items {
					record, _ := item.(map[string]any)
					for _, group := range []string{"fields", "series"} {
						values, _ := record[group].(map[string]any)
						all, _ := union[group].(map[string]any)
						if all == nil {
							all = map[string]any{}
							union[group] = all
						}
						for k, v := range values {
							all[k] = v
						}
					}
				}
				return visit(*node.Row, union, path+".row")
			}
		}
		return nil
	}
	if e := visit(design.Layout, state, "$.layout"); e != nil {
		return e
	}
	for family, layout := range design.Layouts {
		if e := visit(layout, state, "$.layouts."+family); e != nil {
			return e
		}
	}
	if design.Fallback != nil {
		return validateDesignBindings(projectCard(design, 2), raw)
	}
	return nil
}
