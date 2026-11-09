import { randomID } from "./random";
export type ColorPair = { light: string; dark: string };
export type StateStyle = {
  text?: string;
  color?: string;
  colors?: ColorPair;
  background?: string;
  background_colors?: ColorPair;
};
export type Node = {
  visible_when?: string;
  hide_if_empty?: boolean;
  colors?: ColorPair;
  background_colors?: ColorPair;
  states?: Record<string, StateStyle>;
  unknown_state?: StateStyle;
  border?: { color?: string; colors?: ColorPair; width: number };
  prefix?: string;
  suffix?: string;
  symbol?: string;
  image_url?: string;
  icon_size?: number;
  chart_style?: string;
  height?: number;
  min_points?: number;
  gap_seconds?: number;
  id: string;
  type: string;
  text?: string;
  label?: string;
  bind?: string;
  format?: string;
  decimals?: number;
  color_rule?: string;
  color?: string;
  background?: string;
  font_size?: number;
  weight?: string;
  alignment?: string;
  spacing?: number;
  padding?: number;
  radius?: number;
  flex?: number;
  columns?: number;
  limit?: number;
  source?: string;
  children?: Node[];
  row?: Node;
};
export type Design = {
  schema_version: 1 | 2 | 3;
  fallback?: { layout: Node; layouts?: Partial<Record<string, Node>> };
  name: string;
  family: string;
  theme?: string;
  layout: Node;
  layouts?: Partial<Record<string, Node>>;
};
export const kinds = [
  "row",
  "column",
  "grid",
  "list",
  "text",
  "number",
  "badge",
  "divider",
  "spacer",
  "chart",
  "icon",
  "sparkline",
];
export const names: Record<string, string> = {
  row: "横向排列",
  column: "纵向排列",
  grid: "网格",
  list: "重复列表",
  text: "文字",
  number: "数值",
  badge: "数值色块",
  divider: "分隔线",
  spacer: "留白",
  chart: "历史图表",
  icon: "图标",
  sparkline: "迷你趋势",
};
export const namesEn: Record<string, string> = {
  row: "Row",
  column: "Column",
  grid: "Grid",
  list: "Repeating List",
  text: "Text",
  number: "Number",
  badge: "Badge",
  divider: "Divider",
  spacer: "Spacer",
  chart: "Chart",
  icon: "Icon",
  sparkline: "Sparkline",
};
export function kindName(type: string, lang: "zh" | "en" = "zh"): string {
  return (lang === "en" ? namesEn[type] : names[type]) || type;
}
export function newNode(type: string, lang: "zh" | "en" = "zh"): Node {
  const defaultText = lang === "en" ? "New text" : "新内容";
  const n: Node = {
    id: "n_" + randomID().replaceAll("-", "").slice(0, 12),
    type,
  };
  if (["row", "column", "grid"].includes(type)) {
    n.children = [{ id: n.id + "_text", type: "text", text: defaultText }];
    n.spacing = 8;
    if (type === "grid") n.columns = 2;
  } else if (type === "list") {
    n.source = "items";
    n.limit = 3;
    n.spacing = 8;
    n.row = {
      id: n.id + "_row",
      type: "row",
      children: [
        { id: n.id + "_symbol", type: "text", bind: "fields.symbol" },
        { id: n.id + "_price", type: "number", bind: "fields.price" },
      ],
    };
  } else if (["chart", "sparkline"].includes(type)) n.bind = "series.history";
  else if (type === "icon") {
    n.symbol = "sf:server.rack";
    n.icon_size = 20;
  } else if (["number", "badge"].includes(type)) n.bind = "fields.price";
  else if (type === "text") n.text = defaultText;
  return n;
}
export function preset(kind = "quotes", lang: "zh" | "en" = "zh"): Design {
  if (kind === "task")
    return {
      schema_version: 1,
      name: lang === "en" ? "Task Progress" : "任务进度",
      family: "medium",
      theme: "system",
      layout: {
        id: "task",
        type: "column",
        spacing: 8,
        children: [
          {
            id: "title",
            type: "text",
            text: lang === "en" ? "Task Progress" : "工作进度",
            font_size: 18,
            weight: "bold",
          },
          {
            id: "progress",
            type: "number",
            bind: "fields.progress",
            format: "percent",
            font_size: 28,
            weight: "bold",
            color: "accent",
          },
          {
            id: "status",
            type: "text",
            bind: "fields.status",
            color: "secondary",
          },
        ],
      },
    };
  if (kind === "blank")
    return {
      schema_version: 1,
      name: lang === "en" ? "New Card" : "新卡片",
      family: "medium",
      theme: "system",
      layout: newNode("column", lang),
    };
  return {
    schema_version: 1,
    name: lang === "en" ? "Market Watch" : "我的行情",
    family: "medium",
    theme: "system",
    layout: {
      id: "quotes",
      type: "list",
      source: "items",
      limit: 3,
      spacing: 8,
      row: {
        id: "quote_row",
        type: "row",
        spacing: 10,
        children: [
          {
            id: "identity",
            type: "column",
            spacing: 2,
            children: [
              {
                id: "symbol",
                type: "text",
                bind: "fields.symbol",
                font_size: 14,
                weight: "semibold",
              },
              {
                id: "volume",
                type: "text",
                bind: "fields.volume",
                font_size: 10,
                color: "secondary",
              },
            ],
          },
          {
            id: "price",
            type: "number",
            bind: "fields.price",
            decimals: 2,
            font_size: 16,
            alignment: "trailing",
            weight: "medium",
          },
          {
            id: "change",
            type: "badge",
            bind: "fields.change",
            format: "percent",
            decimals: 2,
            color_rule: "signed",
            font_size: 13,
            flex: 0,
          },
        ],
      },
    },
  };
}
export function sampleState(kind = "quotes", lang: "zh" | "en" = "zh"): any {
  if (kind === "task")
    return {
      fields: {
        progress: {
          type: "percent",
          label: lang === "en" ? "Completion" : "完成率",
          value: "68",
        },
        status: {
          type: "text",
          label: lang === "en" ? "Status" : "状态",
          value: lang === "en" ? "In Progress" : "进行中",
        },
      },
    };
  return {
    items: [
      {
        item_id: "BTC",
        fields: {
          symbol: { type: "text", value: "BTC/USDT" },
          volume: {
            type: "text",
            value: lang === "en" ? "Vol 878.37 M" : "成交额 878.37 M",
          },
          price: { type: "decimal", value: "80970.01" },
          change: { type: "percent", value: "-0.99" },
        },
      },
      {
        item_id: "ETH",
        fields: {
          symbol: { type: "text", value: "ETH/USDT" },
          volume: {
            type: "text",
            value: lang === "en" ? "Vol 486.85 M" : "成交额 486.85 M",
          },
          price: { type: "decimal", value: "2385.38" },
          change: { type: "percent", value: "-0.99" },
        },
      },
      {
        item_id: "TAO",
        fields: {
          symbol: { type: "text", value: "TAO/USDT" },
          volume: {
            type: "text",
            value: lang === "en" ? "Vol 15.37 M" : "成交额 15.37 M",
          },
          price: { type: "decimal", value: "254.6" },
          change: { type: "percent", value: "-2.56" },
        },
      },
    ],
  };
}
export function allNodes(root: Node): Node[] {
  return [
    root,
    ...(root.children || []).flatMap(allNodes),
    ...(root.row ? allNodes(root.row) : []),
  ];
}
export function parentOf(root: Node, id: string): Node | undefined {
  if (root.children?.some((n) => n.id === id)) return root;
  for (const n of [...(root.children || []), ...(root.row ? [root.row] : [])]) {
    const p = parentOf(n, id);
    if (p) return p;
  }
}
export function formatValue(
  field: any,
  decimals?: number,
  format?: string,
  lang: "zh" | "en" = "zh",
): string {
  const unavailable = lang === "en" ? "Unavailable" : "不可用";
  if (field?.value === undefined || field?.value === null) return unavailable;
  if (typeof field.value === "boolean")
    return field.value
      ? lang === "en"
        ? "Yes"
        : "是"
      : lang === "en"
        ? "No"
        : "否";
  let value = String(field.value);
  const type =
    format === "percent"
      ? "percent"
      : format === "decimal"
        ? "decimal"
        : field.type;
  if (["decimal", "integer", "percent"].includes(type)) {
    if (
      !/^-?[0-9]+(\.[0-9]+)?$/.test(value) ||
      value.replace(/[^0-9]/g, "").length > 38 ||
      (value.split(".")[1]?.length || 0) > 18 ||
      (type === "integer" && value.includes("."))
    )
      return unavailable;
    if (decimals === undefined && value.includes("."))
      value = value.replace(/0+$/, "").replace(/\.$/, "");
  }
  if (type === "text") return value;
  if (type === "datetime") {
    const date = new Date(value);
    return Number.isNaN(date.getTime())
      ? unavailable
      : new Intl.DateTimeFormat(lang === "en" ? "en-US" : "zh-Hans", {
          dateStyle: "medium",
          timeStyle: "short",
        }).format(date);
  }
  if (decimals !== undefined && /^-?[0-9]+(\.[0-9]+)?$/.test(value)) {
    const negative = value.startsWith("-");
    let [whole, fraction = ""] = value.replace(/^-/, "").split(".");
    let digits = whole + fraction.padEnd(decimals, "0").slice(0, decimals);
    const next = Number(fraction[decimals] || 0);
    const tail = fraction.slice(decimals + 1);
    if (
      fraction.length > decimals &&
      (next > 5 ||
        (next === 5 &&
          (/[1-9]/.test(tail) || Number(digits.at(-1) || 0) % 2 === 1)))
    )
      digits = (BigInt(digits) + 1n).toString();
    digits = digits.padStart(decimals + 1, "0");
    value =
      (negative ? "-" : "") +
      (decimals
        ? digits.slice(0, -decimals) + "." + digits.slice(-decimals)
        : digits);
  }
  if (
    ["decimal", "integer", "percent"].includes(type) &&
    /^-?[0-9]+(\.[0-9]+)?$/.test(value)
  ) {
    const parts = value.split(".");
    parts[0] = parts[0]!.replace(/(\d)(?=(\d{3})+$)/g, "$1,");
    value = parts.join(".");
  }
  return (
    value + (type === "percent" ? "%" : field.unit ? " " + field.unit : "")
  );
}

/** Keep explicit empty text and signed numeric semantics consistent with the native renderer. */
export function nodeValue(
  node: Node,
  field: any,
  lang: "zh" | "en" = "zh",
): string {
  const mapped = stateStyle(node, field);
  if (mapped?.text !== undefined) return mapped.text;
  if (node.text !== undefined && node.text !== null) return node.text;
  const value = formatValue(field, node.decimals, node.format, lang);
  return nonempty(field?.value)
    ? (node.prefix || "") + value + (node.suffix || "")
    : value;
}
export function signedColor(field: any): string {
  const raw = field?.value;
  if (
    typeof raw !== "string" ||
    !/^-?[0-9]+(\.[0-9]+)?$/.test(raw) ||
    raw.replace(/[^0-9]/g, "").length > 38 ||
    (raw.split(".")[1]?.length || 0) > 18
  )
    return "var(--card-muted)";
  return raw.startsWith("-") && /[1-9]/.test(raw) ? "#F6465D" : "#16A667";
}

export function enableV3(design: Design) {
  if (design.schema_version === 3) return;
  design.fallback = JSON.parse(
    JSON.stringify({ layout: design.layout, layouts: design.layouts }),
  );
  design.schema_version = 3;
}
export function nonempty(value: any): boolean {
  return (
    value !== null &&
    value !== undefined &&
    (typeof value !== "string" || value.trim().length > 0)
  );
}
export function stateStyle(node: Node, field: any): StateStyle | undefined {
  if (!node.states && !node.unknown_state) return;
  return (
    node.states?.[String(field?.value ?? "")] ??
    node.unknown_state ?? { color: "secondary", background: "surface" }
  );
}
export function visible(node: Node, state: any, item?: any): boolean {
  const scope = item ?? state ?? {};
  if (
    node.visible_when &&
    !nonempty(scope.fields?.[node.visible_when.slice(7)]?.value)
  )
    return false;
  if (
    node.hide_if_empty &&
    (node.text !== undefined
      ? !nonempty(node.text)
      : node.bind?.startsWith("fields.") &&
        !nonempty(scope.fields?.[node.bind.slice(7)]?.value))
  )
    return false;
  if (node.type === "sparkline")
    return (
      (scope.series?.[node.bind?.slice(7) || ""]?.points?.length || 0) >=
      Math.max(2, node.min_points || 2)
    );
  if (node.children)
    return node.children.some(
      (n) => !["divider", "spacer"].includes(n.type) && visible(n, state, item),
    );
  if (node.type === "list" && node.hide_if_empty)
    return (state?.items || []).some(
      (i: any) => node.row && visible(node.row, state, i),
    );
  return true;
}
export function visibleChildren(node: Node, state: any, item?: any): Node[] {
  const output: Node[] = [];
  for (const n of (node.children || []).filter((n) =>
    visible(n, state, item),
  )) {
    if (
      ["divider", "spacer"].includes(n.type) &&
      (!output.length || ["divider", "spacer"].includes(output.at(-1)!.type))
    )
      continue;
    output.push(n);
  }
  while (output.length && ["divider", "spacer"].includes(output.at(-1)!.type))
    output.pop();
  return output;
}
export function trendGeometry(series: any, node: Node) {
  const samples = (series?.points || []).flatMap((p: any) => {
    const raw = p.value ?? p.c,
      t = Date.parse(p.t);
    if (
      typeof raw !== "string" ||
      !/^-?[0-9]+(\.[0-9]+)?$/.test(raw) ||
      !Number.isFinite(t)
    )
      return [];
    const negative = raw.startsWith("-");
    const [whole, fraction = ""] = raw.replace(/^-/, "").split(".");
    const v = BigInt(whole + fraction.padEnd(18, "0")) * (negative ? -1n : 1n);
    return [{ t, v }];
  });
  if (!samples.length) return { segments: [] as string[], bars: [] as any[] };
  const numbers: bigint[] = samples.map((p: any) => p.v);
  let low = numbers.reduce((a, b) => (a < b ? a : b)),
    high = numbers.reduce((a, b) => (a > b ? a : b));
  if (node.chart_style === "bar") {
    if (low > 0n) low = 0n;
    if (high < 0n) high = 0n;
  }
  const span = high === low ? 1n : high - low;
  const duration = Math.max(1, samples.at(-1).t - samples[0].t),
    gap = (node.gap_seconds || series.interval_seconds * 3) * 1000;
  const segments: string[][] = [[]];
  let previous = samples[0].t;
  const bars = samples.map((p: any) => {
    const x = 2 + ((p.t - samples[0].t) / duration) * 296,
      y = high === low ? 35 : 2 + (Number(high - p.v) / Number(span)) * 66,
      base = high === low ? 35 : 2 + (Number(high) / Number(span)) * 66;
    if (p.t - previous > gap) segments.push([]);
    segments.at(-1)!.push(`${x},${y}`);
    previous = p.t;
    return {
      x,
      pointY: y,
      y: Math.min(y, base),
      height: Math.max(1, Math.abs(base - y)),
      width: Math.min(12, (296 / samples.length) * 0.65),
      positive: p.v >= 0n,
    };
  });
  return { segments: segments.map((s) => s.join(" ")), bars };
}

export function trendSignedColor(series: any): string {
  const points = series?.points || [];
  if (points.length < 2) return "var(--card-muted)";
  function decimal(v: any): bigint | undefined {
    if (typeof v !== "string" || !/^-?[0-9]+(\.[0-9]+)?$/.test(v)) return;
    const negative = v.startsWith("-");
    const [w, f = ""] = v.replace(/^-/, "").split(".");
    return BigInt(w + f.padEnd(18, "0")) * (negative ? -1n : 1n);
  }
  const a = decimal(points[0].value ?? points[0].c),
    b = decimal(points.at(-1).value ?? points.at(-1).c);
  return a === undefined || b === undefined
    ? "var(--card-muted)"
    : b < a
      ? "#F6465D"
      : "#16A667";
}
