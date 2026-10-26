import { type Design, type Node } from "./cardDesign";
export const layoutChoices = [
  {
    id: "fields",
    title: "信息列表",
    titleEn: "Field List",
    description: "名称、状态、进度等字段纵向展示",
    descriptionEn:
      "Stack key fields such as title, status, and progress vertically",
  },
  {
    id: "metric",
    title: "重点数值",
    titleEn: "Hero Metric",
    description: "突出一个数值，再显示补充信息",
    descriptionEn:
      "Highlight one primary metric followed by supporting details",
  },
  {
    id: "items",
    title: "多条记录",
    titleEn: "Multi-Row List",
    description: "行情、设备等多条数据按行排列",
    descriptionEn: "Arrange multiple quotes, services, or items row by row",
  },
  {
    id: "blank",
    title: "自由设计",
    titleEn: "Custom Canvas",
    description: "从一个文字组件开始，或导入AI生成的代码",
    descriptionEn: "Start from a clean text block or import AI-generated JSON",
  },
];
export function neutralState(lang: "zh" | "en" = "zh"): any {
  return {
    fields: {
      name: {
        type: "text",
        label: lang === "en" ? "Name" : "名称",
        value: lang === "en" ? "My Service" : "我的项目",
      },
      value: {
        type: "decimal",
        label: lang === "en" ? "Current Value" : "当前数值",
        value: "68",
      },
      status: {
        type: "text",
        label: lang === "en" ? "Status" : "状态",
        value: lang === "en" ? "Running" : "运行中",
      },
    },
  };
}
export function dataExample(state?: any, lang: "zh" | "en" = "zh"): any {
  if (!state) return neutralState(lang);
  return Object.fromEntries(
    ["fields", "items", "series", "title", "valid_for_seconds"]
      .filter((k) => state[k] !== undefined)
      .map((k) => [k, JSON.parse(JSON.stringify(state[k]))]),
  );
}
export function shellQuote(value: string): string {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}
export function curlExample(
  url: string,
  state?: any,
  lang: "zh" | "en" = "zh",
): string {
  return `curl -X PUT ${shellQuote(url)} \\\n  -H 'Content-Type: application/json' \\\n  --data-raw ${shellQuote(JSON.stringify(dataExample(state, lang), null, 2))}`;
}
export function sourceCards(cards: any[], sourceID: string): any[] {
  return cards.filter((c) => c.source_id === sourceID);
}
export function cardStatus(card: any, lang: "zh" | "en" = "zh"): string {
  if (!card.published || card.revision === "0")
    return lang === "en" ? "Draft · Unpublished" : "草稿 · 尚未发布";
  return JSON.stringify(card.draft) === JSON.stringify(card.published)
    ? lang === "en"
      ? "Published"
      : "已发布"
    : lang === "en"
      ? "Unpublished edits"
      : "有待发布修改";
}
export function createLayout(
  kind: string,
  state: any,
  name: string,
  lang: "zh" | "en" = "zh",
): Design {
  const repeated = kind === "items";
  const fields: Record<string, any> =
    (repeated ? state?.items?.[0]?.fields : state?.fields) ||
    neutralState(lang).fields;
  const entries = Object.entries(fields).slice(0, repeated ? 3 : 6);
  if (kind === "metric")
    entries.sort(
      (a, b) =>
        Number(["decimal", "integer", "percent"].includes(b[1].type)) -
        Number(["decimal", "integer", "percent"].includes(a[1].type)),
    );
  const children: Node[] = entries.map(([key, field], i) => ({
    id: "field_" + i,
    type: ["decimal", "integer", "percent"].includes(field.type)
      ? "number"
      : "text",
    bind: "fields." + key,
    label: field.label || key,
    font_size: kind === "metric" && i === 0 ? 28 : 14,
    ...(field.type === "decimal" ? { decimals: 2 } : {}),
  }));
  return {
    schema_version: 1,
    name,
    family: "medium",
    theme: "system",
    layout:
      kind === "blank"
        ? {
            id: "root",
            type: "column",
            spacing: 8,
            children: [
              {
                id: "heading",
                type: "text",
                text: lang === "en" ? "Add content here" : "在这里添加内容",
              },
            ],
          }
        : repeated
          ? {
              id: "records",
              type: "list",
              source: "items",
              limit: 3,
              spacing: 10,
              row: { id: "record", type: "row", spacing: 10, children },
            }
          : { id: "root", type: "column", spacing: 10, children },
  };
}

const assistantTypes = [
  "text",
  "decimal",
  "integer",
  "percent",
  "boolean",
  "datetime",
];
const assistantKey = /^[A-Za-z][A-Za-z0-9_]{0,63}$/;
const assistantPath =
  /^\$?([A-Za-z0-9_-]+|\.[A-Za-z0-9_-]+|\[[0-9]+\])*(\.[A-Za-z0-9_-]+|\[[0-9]+\])*$/;

export type AssistantField = {
  key: string;
  path: string;
  type: string;
  label: string;
  unit: string;
};
export type AssistantPlan = {
  name: string;
  interval_seconds: number;
  list_path: string;
  item_id_path: string;
  fields: AssistantField[];
  design?: Design;
};

function assistantFail(lang: "zh" | "en", zh: string, en: string): never {
  throw new Error(lang === "en" ? en : zh);
}
function redactSecret(value: string, secret: string) {
  const key = secret.trim();
  if (key.length < 8) return value;
  return value.split(key).join("[API_KEY]");
}
export function sourceAssistantPrompt(
  url: string,
  request: string,
  lang: "zh" | "en" = "zh",
  secret = "",
) {
  const safeURL = redactSecret(url.trim(), secret);
  const safeRequest = redactSecret(request.trim(), secret);
  const shape = {
    name: lang === "en" ? "Asset Summary" : "资产汇总",
    interval_seconds: 300,
    list_path: "data",
    item_id_path: "",
    fields: [
      {
        key: "total_usd",
        path: "total_usd",
        type: "decimal",
        label: lang === "en" ? "Total" : "总资产",
        unit: "USD",
      },
    ],
    design: {
      schema_version: 1,
      name: lang === "en" ? "Asset Summary" : "资产汇总",
      family: "medium",
      theme: "system",
      layout: {
        id: "root",
        type: "column",
        spacing: 8,
        children: [
          {
            id: "total",
            type: "number",
            bind: "fields.total_usd",
            label: lang === "en" ? "Total" : "总资产",
            font_size: 28,
            weight: "bold",
          },
        ],
      },
    },
  };
  const rules =
    "list_path is the path from the JSON root to one object or an array. Use dots and numeric indexes, such as data or data.items. An empty list_path means the root. field.path is relative to that record and must not repeat list_path. item_id_path is required only when the record is an array; it must be a stable string field on each item, otherwise use an empty string. fields has 1 to 32 items. key matches [A-Za-z][A-Za-z0-9_]{0,63}. type is text, decimal, integer, percent, boolean, or datetime. interval_seconds is 60 to 86400; use 300 when unsure. design.schema_version is 1. family is small, medium, large, or extraLarge. theme is system, light, or dark. Layout has at most 64 nodes and 6 levels. Node types: row, column, grid, list, text, number, badge, divider, spacer, chart. Only row, column, and grid may contain children. A list must not contain children. A list sets source to items, limit from 1 to 20, and puts the repeated row object in row. Bind only fields.key from the fields you declared. Do not bind a field that does not exist. Do not invent API keys, URLs, headers, or secrets.";
  if (lang === "en") {
    return `Create one Vao Push data-source and card configuration. Return one JSON object only, with no Markdown. The program stores the API key separately and sends it as Authorization: Bearer. Do not output the key, an Authorization header, a URL, or any secret. HTTPS address: ${safeURL}. User request for format, style, and content: ${safeRequest}. ${rules} Return this shape: ${JSON.stringify(shape)}.`;
  }
  return `请为 Vao Push 生成一份数据源和卡片配置。只返回一个 JSON 对象，不要 Markdown。程序会单独保存 API Key，并作为 Authorization: Bearer 发送。不要输出密钥、Authorization、网址或任何秘密。HTTPS 地址：${safeURL}。用户对格式、样式和需求的说明：${safeRequest}。${rules} 按这个形状返回：${JSON.stringify(shape)}。`;
}
export function parseSourceAssistant(
  text: string,
  lang: "zh" | "en" = "zh",
): AssistantPlan {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const raw = (fenced?.[1] ?? text).trim();
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  let value: any;
  try {
    if (start < 0 || end <= start) throw new Error("missing");
    value = JSON.parse(raw.slice(start, end + 1));
  } catch {
    assistantFail(
      lang,
      "模型返回的内容不是有效 JSON。",
      "The model result is not valid JSON.",
    );
  }
  const name = String(value.name || "").trim().slice(0, 40);
  if (!name)
    assistantFail(
      lang,
      "返回结果缺少数据源名称。",
      "The result has no data-source name.",
    );
  const interval = Number(value.interval_seconds ?? 300);
  if (!Number.isInteger(interval) || interval < 60 || interval > 86400)
    assistantFail(
      lang,
      "采集周期须为 60 至 86400 秒。",
      "The collection interval must be from 60 to 86400 seconds.",
    );
  const listPath = String(value.list_path || "");
  const itemID = String(value.item_id_path || "");
  if (
    (listPath && !assistantPath.test(listPath)) ||
    (itemID && !assistantPath.test(itemID))
  )
    assistantFail(
      lang,
      "记录路径或项目标识路径无效。",
      "The record path or item ID path is invalid.",
    );
  if (!Array.isArray(value.fields) || value.fields.length < 1 || value.fields.length > 32)
    assistantFail(
      lang,
      "需要 1 至 32 个字段映射。",
      "Provide 1 to 32 field mappings.",
    );
  const seen = new Set<string>();
  const fields = value.fields.map((field: any) => {
    const key = String(field?.key || "");
    const path = String(field?.path || "");
    const type = String(field?.type || "");
    if (
      !assistantKey.test(key) ||
      seen.has(key) ||
      !path ||
      path.length > 160 ||
      !assistantPath.test(path) ||
      !assistantTypes.includes(type)
    )
      assistantFail(
        lang,
        "字段标识、路径或类型无效。",
        "A field key, path, or type is invalid.",
      );
    seen.add(key);
    return {
      key,
      path,
      type,
      label: String(field.label || "").slice(0, 120),
      unit: String(field.unit || "").slice(0, 32),
    };
  });
  let design: Design | undefined;
  if (value.design != null) {
    if (typeof value.design !== "object" || Array.isArray(value.design))
      assistantFail(
        lang,
        "卡片样式不是有效对象。",
        "The card design is not a valid object.",
      );
    design = value.design as Design;
  }
  return {
    name,
    interval_seconds: interval,
    list_path: listPath,
    item_id_path: itemID,
    fields,
    ...(design ? { design } : {}),
  };
}

export function missingBindings(design: Design, state: any): string[] {
  const missing: string[] = [];
  function visit(node: Node, scope: any) {
    if (node.bind && !node.text) {
      const [group, key] = node.bind.split(".");
      if (!scope?.[group]?.[key])
        missing.push((node.label || key || node.id) + " (" + node.bind + ")");
    }
    for (const child of node.children || []) visit(child, scope);
    if (node.row) visit(node.row, state?.items?.[0]);
  }
  visit(design.layout, state);
  return [...new Set(missing)];
}
