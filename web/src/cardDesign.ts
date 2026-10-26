import { randomID } from "./random";
export type Node = {
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
  schema_version: 1;
  name: string;
  family: string;
  theme?: string;
  layout: Node;
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
  } else if (type === "chart") n.bind = "series.history";
  else if (["number", "badge"].includes(type)) n.bind = "fields.price";
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
