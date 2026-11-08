import type { Design, Node } from "./cardDesign";

export function fieldScope(root: Node, id: string): "root" | "item" {
  function locate(node: Node, item: boolean): boolean | undefined {
    if (node.id === id) return item;
    for (const child of node.children || []) {
      const found = locate(child, item);
      if (found !== undefined) return found;
    }
    if (node.row) return locate(node.row, true);
  }
  return locate(root, false) ? "item" : "root";
}
export function fieldsForNode(
  root: Node,
  node: Node,
  state: any,
): Record<string, any> {
  const scope = fieldScope(root, node.id) === "item" ? state?.items : [state];
  const group = node.type === "chart" ? "series" : "fields";
  const result: Record<string, any> = {};
  for (const record of scope || [])
    for (const [key, value] of Object.entries(record?.[group] || {})) {
      if (!(key in result)) result[key] = value;
    }
  return result;
}
export function usesNumericFormat(node: Node, field: any): boolean {
  return (
    ["decimal", "percent"].includes(node.format || "") ||
    ["decimal", "integer", "percent"].includes(field?.type)
  );
}
export function wrapGroup(root: Node, id: string, wrapperID: string): Node {
  const value: Node = JSON.parse(JSON.stringify(root));
  const wrap = (node: Node): Node =>
    node.id === id
      ? {
          id: wrapperID,
          type: "column",
          spacing: 8,
          padding: 12,
          radius: 12,
          children: [node],
        }
      : {
          ...node,
          ...(node.children ? { children: node.children.map(wrap) } : {}),
          ...(node.row ? { row: wrap(node.row) } : {}),
        };
  return wrap(value);
}
export function pillNode(id: string, lang: "zh" | "en"): Node {
  return {
    id,
    type: "text",
    text: lang === "en" ? "Status" : "状态",
    font_size: 12,
    weight: "semibold",
    color: "#FFFFFF",
    background: "#315D8A",
    padding: 6,
    radius: 12,
    flex: 0,
  };
}
export function designPrompt(
  design: Design,
  state: any,
  goal: string,
  lang: "zh" | "en",
): string {
  const describe = (records: any[], group: string) => {
    const result: Record<string, any> = {};
    for (const record of records)
      for (const [key, value] of Object.entries(record?.[group] || {}) as [
        string,
        any,
      ][]) {
        const entry = {
          type: value.type,
          label: value.label,
          unit: value.unit,
        };
        if (!result[key]) result[key] = [];
        if (
          !result[key].some(
            (x: any) => JSON.stringify(x) === JSON.stringify(entry),
          )
        )
          result[key].push(entry);
      }
    return result;
  };
  const metadata = {
    root: {
      fields: describe([state], "fields"),
      series: describe([state], "series"),
    },
    items: {
      fields: describe(state.items || [], "fields"),
      series: describe(state.items || [], "series"),
    },
  };
  const rules =
    "Support schema_version 1 or 2 only. Use schema_version=2 for size-specific layouts and preserve existing overrides. Top-level keys: schema_version,name,family,theme,layout,layouts. layout is REQUIRED and must remain a complete v1-compatible default for App 1.0.0. Optional layouts keys: small,medium,large,extraLarge; App 1.1.0 selects an exact size then falls back to layout. One card, one source, one publication. Each tree is limited to 24KiB,64 nodes,depth 6; the full v2 document is limited to 64KiB. Node types: row,column,grid,list,text,number,badge,divider,spacer,chart. Containers row/column/grid use children (1..12); grid columns 1..4. A list uses source:items,limit 1..20,row, never children. Inside a list, bind ONLY item fields/series; root fields are not visible there. chart binds series.key, other values bind fields.key. Strings/numeric fields are different: decimals only affects numeric fields or explicit format decimal/percent. Unknown/null displays Unavailable, empty text does NOT remove layout space; 0 is valid. Existing styles: text,label,bind,format(decimal/percent),decimals(0..18),color_rule(signed),color/background(primary/secondary/accent or #RRGGBB),font_size(10..32),weight(regular/medium/semibold/bold),alignment(leading/center/trailing),spacing/padding/radius(0..24),flex(0..4). Compose rounded groups using column/row+padding+radius+background; static text pills use text+padding+radius+background. Preserve existing node ids AND types in each effective size layout; never rename existing content to add a wrapper. Do not invent icon,box,sparkline,surface,border,visible_when,hide_if_empty,color objects,HTML,CSS,JavaScript,URLs,credentials,data or absent fields. The system draws line/OHLC chart colors and sizes; do not promise 22px sparklines or theme-specific custom color pairs. Return the complete design without changing unrelated sizes, name or theme. New ids must be unique within each tree and match [A-Za-z][A-Za-z0-9_-]{0,63}.";
  return (
    (lang === "en"
      ? "Create native Vao Push card JSON only. "
      : "请只返回 Vao Push 原生卡片完整 JSON，不输出 Markdown。") +
    rules +
    " Field metadata (no data values): " +
    JSON.stringify(metadata) +
    " Current design: " +
    JSON.stringify(design) +
    " Display request: " +
    goal
  );
}

/** Native Canvas geometry: timestamp spacing and the same minimum value span. */
export function chartGeometry(series: any) {
  const samples = (series?.points || []).flatMap((p: any) => {
    const raw =
      series?.type === "ohlc"
        ? [p.o, p.h, p.l, p.c]
        : [p.value, p.value, p.value, p.value];
    if (
      raw.some(
        (v: any) => typeof v !== "string" || !/^-?[0-9]+(\.[0-9]+)?$/.test(v),
      )
    )
      return [];
    const t = Date.parse(p.t),
      [o, h, l, c] = raw.map(Number);
    return [t, o, h, l, c].every(Number.isFinite) ? [{ t, o, h, l, c }] : [];
  });
  if (!samples.length) return { points: "", candles: [] };
  const high = Math.max(...samples.map((p: any) => p.h)),
    low = Math.min(...samples.map((p: any) => p.l));
  const span = Math.max(high - low, Math.abs(high) * 0.001, 0.001);
  const duration = Math.max(samples.at(-1).t - samples[0].t, 1),
    slot = 300 / samples.length,
    inset = Math.max(slot / 2, 3);
  const x = (p: any) =>
    samples.length === 1
      ? 150
      : inset +
        ((p.t - samples[0].t) / duration) * Math.max(300 - inset * 2, 1);
  const y = (n: number) => 3 + ((high - n) / span) * 64;
  return {
    points: samples.map((p: any) => `${x(p)},${y(p.c)}`).join(" "),
    candles: samples.map((p: any) => ({
      x: x(p),
      high: y(p.h),
      low: y(p.l),
      top: Math.min(y(p.o), y(p.c)),
      height: Math.max(Math.abs(y(p.o) - y(p.c)), 1),
      width: Math.max(Math.min(slot * 0.55, 18), 2),
      color: p.c >= p.o ? "var(--card-chart-up)" : "var(--card-chart-down)",
    })),
  };
}
