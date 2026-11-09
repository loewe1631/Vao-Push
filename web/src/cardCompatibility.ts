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
  const group = ["chart", "sparkline"].includes(node.type)
    ? "series"
    : "fields";
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
    "Use schema_version=2 for existing size layouts. Use schema_version=3 only for new capabilities and REQUIRED fallback:{layout,layouts}, a fixed full v2 design for App 1.0.0/1.1.0. Never change fallback merely because snapshot values change. v3 nodes: icon(symbol SF name and/or image_url public HTTPS,icon_size10..48),sparkline(bind series.key,chart_style line/bar,height16..80,min_points2..60,gap_seconds<=604800). Other new properties: visible_when fields.key (presence, not boolean truth),hide_if_empty (missing/null/blank hide, 0/false remain),colors/background_colors {light,dark},border {width1..3,color or colors},number/badge prefix/suffix<=32 bytes. badge states maps raw strings to {text,color,colors,background,background_colors}, unknown_state is a neutral fallback. Colors: primary,secondary,accent,surface,#RRGGBB. State styles override signed colors which override color pairs then static colors. Empty containers and orphan dividers collapse. No box node; use row/column plus padding/radius/background/border. Existing nodes: row,column,grid,list,text,number,badge,divider,spacer,chart. Container children1..12,grid columns1..4,list source items/limit1..20/row. Preserve ids AND types, name, theme, unrelated sizes. Each layout depth6/64 nodes/24KiB; whole design64KiB. Default layout required. Root and item scopes isolated. Numeric decimals0..18 retain precision; never turn missing data into zero. Charts require real timestamp series; never invent business history, URLs, credentials, absent fields, HTML or code. Return complete JSON only. New ids [A-Za-z][A-Za-z0-9_-]{0,63}.";
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
