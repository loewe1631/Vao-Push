<script setup lang="ts">
import { randomID } from "./random";
import { copyText } from "./clipboard";
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from "vue";
import CardPreview from "./CardPreview.vue";
import CardTree from "./CardTree.vue";
import CardAccess from "./CardAccess.vue";
import CardDataInput from "./CardDataInput.vue";
import {
  createLayout,
  neutralState,
  dataExample,
  layoutChoices,
  sourceCards,
  cardStatus,
  missingBindings,
  sourceAssistantPrompt,
  parseSourceAssistant,
} from "./studioWorkflow";
import {
  sampleState,
  newNode,
  allNodes,
  parentOf,
  kinds,
  kindName,
  type Design,
  type Node,
} from "./cardDesign";
import { locale, resolvedTheme, tr, localizeErrorMessage } from "./i18n";
const props = defineProps<{ csrf: string }>();
function revisionLabel(value: string | number) {
  return locale.value === "en" ? `Rev ${value}` : `第${value}版`;
}
function widgetTheme(theme?: string) {
  return theme === "dark" || theme === "light" ? theme : resolvedTheme.value;
}
type Row = Record<string, any>;
const editingSource = ref("");
const aiURL = ref("");
const aiKey = ref("");
const aiRequest = ref("");
const aiPromptText = ref("");
const aiResult = ref("");
const deletion = ref<Row | null>(null);
const deletionDialog = ref<HTMLDialogElement | null>(null);
watch(deletion, async (pending) => {
  if (!pending) return;
  await nextTick();
  if (deletionDialog.value && !deletionDialog.value.open)
    deletionDialog.value.showModal();
});
async function requestDeletion(kind: "source" | "card", id: string) {
  navigate(() => {
    action(async () => {
      deletion.value = await api(
        (kind === "source" ? "card-sources/" : "cards/") + id + "/deletion",
      );
    });
  });
}
async function confirmDeletion() {
  await action(async () => {
    const pending = deletion.value;
    if (!pending) return;
    const path =
      (pending.kind === "source" ? "card-sources/" : "cards/") + pending.id;
    await api(path, "DELETE", undefined, {
      "If-Match": pending.confirmation_token,
    });
    const removed = pending.cards.map((c: Row) => c.id);
    if (removed.includes(activeID.value)) {
      activeID.value = "";
      saved.value = "";
      codeDirty.value = false;
      if (view.value === "editor") view.value = "library";
    }
    if (removed.includes(managedID.value)) {
      managedID.value = "";
      view.value = "library";
    }
    if (pending.kind === "source") {
      if (editingSource.value === pending.id) resetSource();
      if (dataSourceID.value === pending.id) dataSourceID.value = "";
      if (sourceID.value === pending.id) sourceID.value = "";
      if (existingSource.value === pending.id) existingSource.value = "";
    }
    deletion.value = null;
    await refresh();
    notice.value =
      pending.kind === "source"
        ? tr(
            "数据源已删除，采集和上报地址已停用。",
            "Data source deleted. Collection and its push URL are disabled.",
          )
        : tr(
            "卡片已删除，数据源及其他卡片保持。",
            "Card deleted. The data source and other cards remain.",
          );
  });
}

const view = ref("library"),
  search = ref(""),
  pendingNavigation = ref<(() => void) | null>(null);
const newName = ref(""),
  sourceChoice = ref("new"),
  existingSource = ref(""),
  newSourceMode = ref("push"),
  newURL = ref(""),
  newInterval = ref(300),
  newHeaders = ref("{}");
const newMappings = ref([
  {
    key: "value",
    path: "value",
    type: "decimal",
    label: tr("当前数值", "Current Value"),
    unit: "",
  },
]);
const initialLayout = ref("fields"),
  advancedLayout = ref(false),
  dataSourceID = ref(""),
  editorData = ref(""),
  integrationOpen = ref(false),
  aiGoal = ref("");
const managedID = ref("");
const managed = computed(() =>
  cards.value.find((c) => c.id === managedID.value),
);
const managedSource = computed(() =>
  sources.value.find((s) => s.id === managed.value?.source_id),
);
const dataSource = computed(() =>
  sources.value.find((s) => s.id === dataSourceID.value),
);
const filteredCards = computed(() =>
  cards.value.filter((c) =>
    (
      c.draft.name +
      " " +
      (sources.value.find((s) => s.id === c.source_id)?.name || "")
    )
      .toLowerCase()
      .includes(search.value.toLowerCase()),
  ),
);
const leaves = computed(() =>
  allNodes(design.value.layout).filter((n) =>
    ["text", "number", "badge", "chart"].includes(n.type),
  ),
);
const availableFields = computed(() => {
  const chart = node.value?.type === "chart";
  const values = chart
    ? source.value?.state?.series ||
      source.value?.state?.items?.[0]?.series ||
      {}
    : source.value?.state?.fields ||
      source.value?.state?.items?.[0]?.fields ||
      neutralState(locale.value).fields;
  return Object.entries(values).map(([key, value]: [string, any]) => ({
    path: (chart ? "series." : "fields.") + key,
    label: (value.label || key) + " · " + key,
  }));
});
const unmatched = computed(() =>
  source.value?.state ? missingBindings(design.value, source.value.state) : [],
);
const activeCard = computed(() =>
  cards.value.find((c) => c.id === activeID.value),
);
function navigate(fn: () => void) {
  if (view.value === "editor" && dirty.value) pendingNavigation.value = fn;
  else fn();
}
function showLibrary() {
  navigate(() => {
    tab.value = "cards";
    view.value = "library";
  });
}
function manageCard(c: Row) {
  navigate(() => {
    managedID.value = c.id;
    tab.value = "cards";
    view.value = "manage";
  });
}
function selectDataSource(id: string) {
  dataSourceID.value = id;
  dataEditor.value = JSON.stringify(
    dataExample(sources.value.find((s) => s.id === id)?.state),
    null,
    2,
  );
}
function openDataSource(id: string) {
  navigate(() => {
    selectDataSource(id);
    tab.value = "sources";
  });
}
function nodeLabel(n: Node) {
  return (
    n.label ||
    n.text ||
    availableFields.value.find((f) => f.path === n.bind)?.label ||
    kindName(n.type, locale.value)
  );
}
function replaceLayout(kind: string) {
  if (activeID.value && dirty.value) {
    error.value = tr(
      "请先保存当前修改，再更换布局。",
      "Save the current changes before replacing the layout.",
    );
    return;
  }
  const name = design.value.name;
  design.value = createLayout(
    kind,
    source.value?.state || neutralState(locale.value),
    name,
    locale.value,
  );
  selectedID.value =
    allNodes(design.value.layout).find((n) =>
      ["text", "number", "badge"].includes(n.type),
    )?.id || design.value.layout.id;
}
async function startDesign() {
  await action(async () => {
    if (!newName.value.trim())
      throw Error(
        tr("先给这张卡片起一个名字。", "Give this card a name first."),
      );
    let id = existingSource.value;
    if (sourceChoice.value === "new") {
      if (
        newSourceMode.value === "http" &&
        !newURL.value.startsWith("https://")
      )
        throw Error(
          tr(
            "请输入可访问的HTTPS JSON/API地址。",
            "Enter an HTTPS JSON/API address that the server can read.",
          ),
        );
      const config =
        newSourceMode.value === "http"
          ? {
              url: newURL.value,
              headers: JSON.parse(newHeaders.value || "{}"),
              fields: newMappings.value,
            }
          : {};
      let sourceLabel = newName.value.trim();
      while (new TextEncoder().encode(sourceLabel).length > 108)
        sourceLabel = sourceLabel.slice(0, -1);
      const created = await api("card-sources", "POST", {
        name: sourceLabel + tr(" · 数据", " · Data"),
        mode: newSourceMode.value,
        config,
        interval_seconds: newInterval.value,
      });
      id = created.id;
      existingSource.value = id;
      sourceChoice.value = "existing";
      if (newSourceMode.value === "http") {
        try {
          await api("card-sources/" + id + "/poll", "POST", {});
        } catch {
          notice.value = tr(
            "地址已保存，首次读取未成功。可在数据源页检查字段路径或鉴权后重试。",
            "Address saved, but the first read failed. Check the field path or authentication and try again.",
          );
        }
      }
    }
    if (!id)
      throw Error(
        tr(
          "请选择数据源或创建一个新的数据源。",
          "Select a data source or create a new one.",
        ),
      );
    await refresh();
    sourceID.value = id;
    activeID.value = "";
    draftRevision.value = "0";
    publishedRevision.value = "0";
    design.value = createLayout(
      initialLayout.value,
      source.value?.state ||
        (newSourceMode.value === "http"
          ? {
              fields: Object.fromEntries(
                newMappings.value.map((f) => [
                  f.key,
                  { type: f.type, label: f.label, value: "0" },
                ]),
              ),
            }
          : neutralState(locale.value)),
      newName.value.trim(),
      locale.value,
    );
    selectedID.value =
      allNodes(design.value.layout).find((n) =>
        ["text", "number", "badge"].includes(n.type),
      )?.id || design.value.layout.id;
    code.value = currentCode();
    codeDirty.value = false;
    mode.value = "visual";
    saved.value = "";
    advancedLayout.value = false;
    await save();
    editorData.value = JSON.stringify(
      dataExample(source.value?.state),
      null,
      2,
    );
    integrationOpen.value = !source.value?.state;
    view.value = "editor";
  });
}
async function sendEditorData() {
  await action(async () => {
    await api(
      "card-sources/" + sourceID.value + "/data",
      "PUT",
      JSON.parse(editorData.value),
    );
    await refresh();
    notice.value = tr(
      "内容已保存。下方预览已使用这份数据，可以调整样式并发布。",
      "Content saved. The preview below now uses this data.",
    );
  });
}
async function copyEditorAddress() {
  await action(async () => {
    const access = await api("card-sources/" + sourceID.value + "/access");
    await copy(access.data_url);
  });
}
const goalZh =
  "顶部显示名称，中间突出主要数值，底部显示状态。整体简洁、清楚，适合桌面中尺寸小组件。";
const goalEn =
  "Show the name at the top, emphasize the main value in the center, and place status underneath. Keep it clear and compact for a medium Home Screen widget.";
const demoState = computed(() => ({
  fields: {
    progress: {
      type: "percent",
      label: tr("完成率", "Completion"),
      value: "68",
    },
    status: {
      type: "text",
      label: tr("状态", "Status"),
      value: tr("进行中", "In Progress"),
    },
  },
}));
const demoDesign = computed(() =>
  createLayout(
    "metric",
    demoState.value,
    tr("任务进度", "Task Progress"),
    locale.value,
  ),
);
aiGoal.value = locale.value === "en" ? goalEn : goalZh;
watch(locale, (next, prev) => {
  const previous = prev === "en" ? goalEn : goalZh;
  if (aiGoal.value === previous) aiGoal.value = next === "en" ? goalEn : goalZh;
});
function beforeUnload(e: BeforeUnloadEvent) {
  if (view.value === "editor" && dirty.value) {
    e.preventDefault();
    e.returnValue = "";
  }
}

const tab = ref("cards"),
  busy = ref(false),
  error = ref(""),
  notice = ref(""),
  sources = ref<Row[]>([]),
  cards = ref<Row[]>([]);
const sourceID = ref(""),
  activeID = ref(""),
  draftRevision = ref("0"),
  publishedRevision = ref("0");
const design = ref<Design>(
    createLayout(
      "fields",
      neutralState(locale.value),
      tr("新卡片", "New Card"),
      locale.value,
    ),
  ),
  selectedID = ref("field_0"),
  mode = ref("visual"),
  code = ref(JSON.stringify(design.value, null, 2)),
  codeDirty = ref(false),
  saved = ref("");
const source = computed(() =>
  sources.value.find((s) => s.id === sourceID.value),
);
const node = computed(() =>
  allNodes(design.value.layout).find((n) => n.id === selectedID.value),
);
const previewFamily = ref("medium");
const previewState = computed(
  () => source.value?.state || neutralState(locale.value),
);
const isSample = computed(() => !source.value?.state);
const dirty = computed(
  () => JSON.stringify(design.value) !== saved.value || codeDirty.value,
);
const sourceName = ref(""),
  sourceMode = ref("push"),
  sourceURL = ref(""),
  headers = ref("{}"),
  recordPath = ref(""),
  itemIDPath = ref(""),
  interval = ref(300);
function priceMapping() {
  return {
    key: "price",
    path: "data.amount",
    type: "decimal",
    label: tr("最新价", "Last Price"),
    unit: "USD",
  };
}
const mappings = ref([priceMapping()]);
const dataEditor = ref(
  JSON.stringify(sampleState("quotes", locale.value), null, 2),
);
async function api(
  path: string,
  method = "GET",
  body?: unknown,
  headers: Record<string, string> = {},
) {
  const r = await fetch("/v1/" + path, {
    method,
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      ...(method === "GET" ? {} : { "X-CSRF-Token": props.csrf }),
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const value = await r.json().catch(() => null);
  if (!r.ok)
    throw new Error(
      localizeErrorMessage(
        value?.error?.message ||
          tr("请求未完成", "Request could not be completed."),
      ),
    );
  return value.data;
}
async function action(work: () => Promise<void>) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    await work();
  } catch (e) {
    error.value =
      e instanceof Error
        ? localizeErrorMessage(e.message)
        : tr("操作未完成", "Operation could not be completed");
  } finally {
    busy.value = false;
  }
}
async function refresh() {
  const [s, c] = await Promise.all([api("card-sources"), api("cards")]);
  sources.value = s.sources;
  cards.value = c.cards;
  if (!dataSourceID.value) selectDataSource(sources.value[0]?.id || "");
  if (!existingSource.value) existingSource.value = sources.value[0]?.id || "";
}
function currentCode() {
  return JSON.stringify(design.value, null, 2);
}
async function importCode() {
  let parsed;
  try {
    parsed = JSON.parse(code.value);
  } catch (e) {
    throw new Error(
      tr("JSON语法有误：", "Invalid JSON: ") + (e as Error).message,
    );
  }
  design.value = await api("cards/validate", "POST", { design: parsed });
  selectedID.value =
    allNodes(design.value.layout).find((n) =>
      ["text", "number", "badge", "chart"].includes(n.type),
    )?.id || design.value.layout.id;
  codeDirty.value = false;
  code.value = currentCode();
}
async function changeMode(next: string) {
  await action(async () => {
    if (next === "visual" && codeDirty.value) await importCode();
    if (["code", "ai"].includes(next) && mode.value === "visual")
      code.value = currentCode();
    mode.value = next;
  });
}
function newCard() {
  navigate(() => {
    view.value = "setup";
    tab.value = "cards";
    newName.value = "";
    sourceChoice.value = "new";
    newSourceMode.value = "push";
    newURL.value = "";
    newHeaders.value = "{}";
    aiURL.value = "";
    aiKey.value = "";
    aiRequest.value = "";
    aiPromptText.value = "";
    aiResult.value = "";
    initialLayout.value = "fields";
  });
}
function loadCard(card: Row) {
  if (view.value === "editor" && dirty.value) {
    pendingNavigation.value = () => {
      saved.value = JSON.stringify(design.value);
      codeDirty.value = false;
      loadCard(card);
    };
    return;
  }
  view.value = "editor";
  tab.value = "cards";
  advancedLayout.value = false;
  activeID.value = card.id;
  sourceID.value = card.source_id;
  draftRevision.value = card.draft_revision;
  publishedRevision.value = card.revision;
  design.value = JSON.parse(JSON.stringify(card.draft));
  selectedID.value =
    allNodes(design.value.layout).find((n) =>
      ["text", "number", "badge", "chart"].includes(n.type),
    )?.id || design.value.layout.id;
  editorData.value = JSON.stringify(dataExample(source.value?.state), null, 2);
  integrationOpen.value = !source.value?.state;
  code.value = currentCode();
  codeDirty.value = false;
  saved.value = JSON.stringify(design.value);
  mode.value = "visual";
}
async function save() {
  if (codeDirty.value) await importCode();
  if (!sourceID.value)
    throw new Error(
      tr("请先添加并选择数据源。", "Add and select a data source first."),
    );
  const result = await api(
    activeID.value ? "cards/" + activeID.value : "cards",
    activeID.value ? "PUT" : "POST",
    { source_id: sourceID.value, design: design.value },
    activeID.value ? { "If-Match": `"draft-${draftRevision.value}"` } : {},
  );
  activeID.value = result.id;
  draftRevision.value = result.draft_revision;
  saved.value = JSON.stringify(design.value);
  await refresh();
}
async function saveDraft() {
  await action(async () => {
    await save();
    notice.value = tr(
      "草稿已保存，手机继续使用已发布版本。",
      "Draft saved. Phones continue using the published version.",
    );
  });
}
async function publish() {
  await action(async () => {
    if (!source.value?.state)
      throw Error(
        tr(
          "先接入一份有效数据。可以在“接入数据”中手动保存JSON，或让脚本上报、读取API。",
          "Connect valid data first. Save JSON here, push it from a script, or read an API.",
        ),
      );
    if (unmatched.value.length)
      throw Error(
        tr(
          "以下字段未匹配数据，请先调整绑定：",
          "These fields do not match the current data: ",
        ) + unmatched.value.join(locale.value === "en" ? ", " : "、"),
      );
    if (dirty.value || !activeID.value) await save();
    const r = await api(
      "cards/" + activeID.value + "/publish",
      "POST",
      {},
      { "If-Match": `"draft-${draftRevision.value}"` },
    );
    publishedRevision.value = r.revision;
    await refresh();
    notice.value = tr(
      `已发布第${r.revision}版；订阅设备同步后使用新版设计，保留本机微调。`,
      `Published revision ${r.revision}. Subscribed devices use it after syncing and keep their local adjustments.`,
    );
  });
}
async function copy(text: string) {
  try {
    await copyText(text);
    notice.value = tr("已复制", "Copied");
  } catch {
    error.value = tr(
      "复制失败，请选中文字手动复制。",
      "Copy failed. Select the text and copy it manually.",
    );
  }
}
function aiPrompt() {
  const state = previewState.value;
  const fieldSet = state.fields || state.items?.[0]?.fields || {};
  const fields = Object.fromEntries(
    Object.entries(fieldSet).map(([key, value]: [string, any]) => [
      key,
      { type: value.type, label: value.label, unit: value.unit },
    ]),
  );
  const rules =
    "schema_version=1. Top-level keys are only schema_version, name, family, theme, layout. family is small/medium/large/extraLarge. theme is system/light/dark. At most 64 nodes and 6 levels. ids are unique and match [A-Za-z][A-Za-z0-9_-]{0,63}. Node types: " +
    kinds.join(", ") +
    ". Containers row/column/grid use children; grid needs columns 1..4. Repeating lists use source:items, limit 1..20, and a row node. Bind fields with fields.key and charts with series.key. Allowed style keys: label, text, bind, format(percent/decimal), decimals(0..18), color_rule(signed), color, background(#RRGGBB or primary/secondary/accent), font_size(10..32), weight(regular/medium/semibold/bold), alignment(leading/center/trailing), spacing/padding/radius(0..24), flex(0..4). When revising a design, keep unchanged component ids so phones can retain local adjustments. Do not invent fields, URLs, secrets, or expressions.";
  if (locale.value === "en") {
    return `Create a native Vao Push Home Screen card as JSON only. Do not output HTML, JavaScript, or Markdown. ${rules} Current fields: ${JSON.stringify(fields)}. Series: ${JSON.stringify(Object.keys(state.series || {}))}. Current layout: ${JSON.stringify(design.value)}. Display request: ${aiGoal.value}. Use only existing fields and return one complete valid JSON object. Reference shape: ${JSON.stringify(demoDesign.value)}.`;
  }
  return `请为Vao Push生成一份原生小组件卡片JSON，只返回JSON，不输出HTML、JavaScript或Markdown。${rules} 当前字段结构：${JSON.stringify(fields)}；系列：${JSON.stringify(Object.keys(state.series || {}))}。布局示例：${JSON.stringify(design.value)}。我的展示要求：${aiGoal.value}。先检查字段是否存在；只用已有字段生成完整有效JSON，不要求我手改技术参数。参考输出结构：${JSON.stringify(demoDesign.value)}。`;
}
function add(kind: string) {
  const created = newNode(kind, locale.value);
  const selected = node.value;
  if (selected && ["row", "column", "grid"].includes(selected.type))
    selected.children!.push(created);
  else {
    const parent = parentOf(design.value.layout, selectedID.value);
    if (parent) parent.children!.push(created);
    else {
      const old = design.value.layout;
      design.value.layout = {
        id: "root_" + randomID().slice(0, 8),
        type: "column",
        children: [old, created],
      };
    }
  }
  selectedID.value = created.id;
}
function removeNode() {
  const parent = parentOf(design.value.layout, selectedID.value);
  if (!parent) return;
  if (parent.children!.length <= 1) {
    error.value = tr(
      "容器至少保留一个组件。",
      "A container must keep at least one component.",
    );
    return;
  }
  parent.children = parent.children!.filter((n) => n.id !== selectedID.value);
  selectedID.value = parent.id;
}
function move(id: string, step: number) {
  const p = parentOf(design.value.layout, id);
  if (!p?.children) return;
  const from = p.children.findIndex((n) => n.id === id),
    to = from + step;
  if (to < 0 || to >= p.children.length) return;
  [p.children[from], p.children[to]] = [p.children[to]!, p.children[from]!];
}
function drop(from: string, to: string) {
  const p = parentOf(design.value.layout, from);
  if (!p?.children || p !== parentOf(design.value.layout, to)) return;
  const a = p.children.findIndex((n) => n.id === from),
    b = p.children.findIndex((n) => n.id === to);
  const [item] = p.children.splice(a, 1);
  p.children.splice(b, 0, item!);
}
function number(event: Event, key: keyof Node) {
  if (!node.value) return;
  const value = (event.target as HTMLInputElement).value;
  const n = node.value as any;
  if (value === "") delete n[key];
  else n[key] = Number(value);
}
async function editSource(s: Row) {
  await action(async () => {
    const r = await api("card-sources/" + s.id);
    editingSource.value = s.id;
    selectDataSource(s.id);
    sourceName.value = r.name;
    sourceMode.value = r.mode;
    interval.value = r.interval_seconds;
    sourceURL.value = r.config.url || "";
    recordPath.value = r.config.list_path || "";
    itemIDPath.value = r.config.item_id_path || "";
    headers.value = "";
    mappings.value = r.config.fields || [priceMapping()];
  });
}
function resetSource() {
  editingSource.value = "";
  sourceName.value = "";
  sourceURL.value = "";
  headers.value = "{}";
  recordPath.value = "";
  itemIDPath.value = "";
  mappings.value = [priceMapping()];
}
function generateSourcePrompt() {
  if (!aiURL.value.startsWith("https://"))
    throw Error(
      tr(
        "请输入可访问的 HTTPS 地址。",
        "Enter an HTTPS address the server can read.",
      ),
    );
  if (!aiRequest.value.trim())
    throw Error(
      tr(
        "先用普通话说清格式、样式和需求。",
        "First describe the format, style, and what you want.",
      ),
    );
  aiPromptText.value = sourceAssistantPrompt(
    aiURL.value,
    aiRequest.value,
    locale.value,
    aiKey.value,
  );
}
async function copySourcePrompt() {
  await action(async () => {
    generateSourcePrompt();
    await copy(aiPromptText.value);
    if (!error.value)
      notice.value = tr(
        "说明已生成并复制。它不含 API Key，可以交给你自己的模型。",
        "Instructions generated and copied. They contain no API key and can be sent to your own model.",
      );
  });
}
async function saveAiSource() {
  await action(async () => {
    if (!aiURL.value.startsWith("https://"))
      throw Error(
        tr(
          "请输入可访问的 HTTPS 地址。",
          "Enter an HTTPS address the server can read.",
        ),
      );
    const plan = parseSourceAssistant(aiResult.value, locale.value);
    const cardName = newName.value.trim() || plan.name;
    let design = plan.design;
    if (design) {
      design = await api("cards/validate", "POST", {
        design: { ...design, name: cardName },
      });
    }
    const headers = aiKey.value.trim()
      ? { Authorization: "Bearer " + aiKey.value.trim() }
      : undefined;
    const created = await api("card-sources", "POST", {
      name: cardName,
      mode: "http",
      interval_seconds: plan.interval_seconds,
      config: {
        url: aiURL.value.trim(),
        headers,
        list_path: plan.list_path,
        item_id_path: plan.item_id_path,
        fields: plan.fields,
      },
    });
    if (!design) {
      const fields = Object.fromEntries(
        plan.fields.map((field) => [
          field.key,
          { type: field.type, label: field.label, value: "0" },
        ]),
      );
      design = createLayout(
        plan.item_id_path ? "items" : "metric",
        plan.item_id_path ? { items: [{ fields }] } : { fields },
        cardName,
        locale.value,
      );
    }
    const card = await api("cards", "POST", {
      source_id: created.id,
      design,
    });
    aiKey.value = "";
    aiResult.value = "";
    selectDataSource(created.id);
    let read = true;
    try {
      await api("card-sources/" + created.id + "/poll", "POST", {});
    } catch {
      read = false;
    }
    await refresh();
    const row = cards.value.find((item) => item.id === card.id);
    if (row) loadCard(row);
    notice.value = read
      ? tr(
          "卡片草稿已创建，并完成第一次读取。",
          "The draft card was created, and the first read succeeded.",
        )
      : tr(
          "卡片草稿已创建。第一次读取没有成功，可稍后在数据源里检查地址或密钥。",
          "The draft card was created. The first read failed; check the address or key in Data Sources.",
        );
  });
}
async function createSource() {
  await action(async () => {
    const config =
      sourceMode.value === "http"
        ? {
            url: sourceURL.value,
            headers: headers.value.trim()
              ? JSON.parse(headers.value)
              : undefined,
            list_path: recordPath.value,
            item_id_path: itemIDPath.value,
            fields: mappings.value,
          }
        : {};
    const body = {
      name: sourceName.value,
      interval_seconds: interval.value,
      config,
    };
    if (editingSource.value) {
      await api("card-sources/" + editingSource.value, "PUT", body);
      notice.value = tr(
        "数据源配置已更新，上报地址和卡片引用保持。",
        "Data source updated. Its push URL and card references remain.",
      );
    } else {
      const r = await api("card-sources", "POST", {
        ...body,
        mode: sourceMode.value,
      });
      selectDataSource(r.id);
      notice.value = tr(
        "数据源已创建，可发送数据或采集API。",
        "Data source created. You can push data or collect the API.",
      );
    }
    await refresh();
    resetSource();
  });
}
async function sendData() {
  await action(async () => {
    await api(
      "card-sources/" + dataSourceID.value + "/data",
      "PUT",
      JSON.parse(dataEditor.value),
    );
    await refresh();
    notice.value = tr(
      "最新数据已保存，订阅卡片同步时保留各自排版。",
      "Latest data saved. Subscribed cards keep their own layouts.",
    );
  });
}
async function poll() {
  await action(async () => {
    await api("card-sources/" + dataSourceID.value + "/poll", "POST", {});
    await refresh();
    notice.value = tr("已采集并保存API数据。", "API data collected and saved.");
  });
}
async function sourceAddress() {
  await action(async () => {
    const r = await api("card-sources/" + dataSourceID.value + "/access");
    await copy(r.data_url);
  });
}
async function toggleSource(s: Row) {
  await action(async () => {
    await api("card-sources/" + s.id + "/enabled", "PUT", {
      enabled: !s.enabled,
    });
    await refresh();
  });
}
let timer: ReturnType<typeof setInterval> | undefined;
onMounted(async () => {
  window.addEventListener("beforeunload", beforeUnload);
  await action(refresh);
  timer = setInterval(() => {
    if (!busy.value) refresh().catch(() => {});
  }, 20000);
});
onUnmounted(() => {
  window.removeEventListener("beforeunload", beforeUnload);
  if (timer) clearInterval(timer);
});
</script>

<template>
  <div class="studio">
    <dialog
      v-if="deletion"
      ref="deletionDialog"
      class="delete-overlay"
      aria-labelledby="delete-resource-title"
      @cancel="busy && $event.preventDefault()"
      @close="
        deletion = null;
        error = '';
      "
    >
      <section class="panel delete-dialog">
        <h2 id="delete-resource-title">
          {{
            deletion.kind === "source"
              ? tr("删除数据源", "Delete Data Source")
              : tr("删除卡片", "Delete Card")
          }}{{ locale === "en" ? ": " : "：" }}{{ deletion.name }}
        </h2>
        <template v-if="deletion.kind === 'source'">
          <p v-if="deletion.cards.length" class="banner">
            {{
              tr(
                `这个数据源正被${deletion.cards.length}张卡片使用，不能删除。只有没有卡片引用的数据源才能删除。`,
                `This data source is used by ${deletion.cards.length} cards and cannot be deleted. Only an unused source can be deleted.`,
              )
            }}
          </p>
          <p v-else>
            {{
              tr(
                "没有卡片使用这个数据源。确认后将永久删除这份数据及采集配置，上报地址失效，自动采集停止。此操作无法在控制台恢复。",
                "No card uses this data source. Confirming permanently deletes its data and collection settings, disables the push URL, and stops collection. The console cannot restore it.",
              )
            }}
          </p>
        </template>
        <p v-else>
          {{
            tr(
              "将永久删除这张卡片的草稿、已发布设计及订阅码，取消其设备读取授权。数据源和其他卡片不会删除。",
              "This permanently deletes the card draft, published design, and subscription codes, and removes device read access. The data source and other cards stay.",
            )
          }}
        </p>
        <template v-if="deletion.cards.length"
          ><h3>
            {{
              deletion.kind === "source"
                ? tr("仍在使用它的卡片", "Cards still using it")
                : tr("删除范围", "Deletion scope")
            }}（{{
              tr(`${deletion.cards.length}张`, `${deletion.cards.length}`)
            }}）
          </h3>
          <ul class="delete-relations">
            <li v-for="c in deletion.cards" :key="c.id">
              <strong>{{ c.name }}</strong
              ><span>
                ·
                {{
                  tr(
                    `${c.devices.length}台订阅设备`,
                    `${c.devices.length} subscribed devices`,
                  )
                }}</span
              ><small v-if="c.devices.length">{{
                c.devices.map((d: Row) => d.name).join("、")
              }}</small>
            </li>
          </ul></template
        >
        <p
          v-if="deletion.kind === 'card' && deletion.device_count"
          class="muted"
        >
          {{
            tr(
              `共影响${deletion.device_count}台订阅设备。手机已保存卡片会在下次同步或读取时显示不可用；离线缓存不会立即消失。`,
              `${deletion.device_count} subscribed devices are affected. Saved phone cards become unavailable on the next sync or read; offline cache does not disappear immediately.`,
            )
          }}
        </p>
        <button
          v-if="deletion.kind === 'source' && deletion.cards.length"
          class="secondary"
          @click="
            search = deletion.name;
            deletion = null;
            tab = 'cards';
            view = 'library';
          "
        >
          {{ tr("查看关联卡片", "Show Linked Cards") }}
        </button>
        <p v-if="error" role="alert" class="banner error">{{ error }}</p>
        <div class="studio-tabs">
          <button
            class="secondary"
            :disabled="busy"
            @click="
              deletion = null;
              error = '';
            "
          >
            {{ tr("取消", "Cancel") }}</button
          ><button
            class="secondary"
            :disabled="busy"
            @click="requestDeletion(deletion.kind, deletion.id)"
          >
            {{ tr("重新查看引用", "Refresh References") }}</button
          ><button
            class="primary destructive-button"
            :disabled="
              busy || (deletion.kind === 'source' && deletion.cards.length > 0)
            "
            @click="confirmDeletion"
          >
            {{
              busy
                ? tr("正在删除…", "Deleting…")
                : deletion.kind === "source"
                  ? tr("确认删除数据源", "Delete Data Source")
                  : tr("确认删除卡片", "Delete Card")
            }}
          </button>
        </div>
      </section>
    </dialog>
    <div class="studio-tabs" :aria-label="tr('卡片工作台导航', 'Card Studio')">
      <button
        :class="tab === 'cards' ? 'primary' : 'secondary'"
        @click="showLibrary"
        :disabled="busy"
      >
        {{ tr("我的卡片", "My Cards") }}
      </button>
      <button
        :class="tab === 'sources' ? 'primary' : 'secondary'"
        @click="
          navigate(() => {
            tab = 'sources';
            view = 'library';
          })
        "
        :disabled="busy"
      >
        {{ tr("数据源管理", "Data Sources") }}
      </button>
      <button class="secondary" @click="action(refresh)" :disabled="busy">
        {{ tr("刷新列表", "Refresh") }}
      </button>
    </div>
    <div
      v-if="pendingNavigation"
      class="navigation-confirm banner"
      role="alertdialog"
      :aria-label="tr('未保存的设计', 'Unsaved design')"
    >
      <p>
        {{
          tr(
            "当前设计有未保存的修改。保存草稿后再离开，或放弃这次修改。",
            "This design has unsaved changes. Save the draft before leaving, or discard the changes.",
          )
        }}
      </p>
      <div class="studio-tabs">
        <button class="secondary" @click="pendingNavigation = null">
          {{ tr("继续编辑", "Keep Editing") }}</button
        ><button
          class="secondary"
          @click="
            const next = pendingNavigation;
            pendingNavigation = null;
            saved = JSON.stringify(design);
            codeDirty = false;
            next?.();
          "
        >
          {{ tr("放弃修改并离开", "Discard and Leave") }}</button
        ><button
          class="primary"
          :disabled="busy"
          @click="
            action(async () => {
              await save();
              const next = pendingNavigation;
              pendingNavigation = null;
              next?.();
            })
          "
        >
          {{ tr("保存草稿并离开", "Save Draft and Leave") }}
        </button>
      </div>
    </div>
    <p v-if="error" role="alert" class="banner error">{{ error }}</p>
    <p v-if="notice" role="status" class="banner success">{{ notice }}</p>
    <template v-if="tab === 'sources'">
      <section class="panel">
        <h2>{{ tr("我的卡片数据源", "Card Data Sources") }}</h2>
        <p class="muted">
          {{
            tr(
              "一个数据源保存一份最新内容，可以供多张卡片使用。读取JSON/API适合已有查询接口；主动上报适合脚本产生结果时提交。先选下方数据源，再编辑或写入内容。",
              "A data source stores one latest payload and can feed several cards. Read a JSON/API when the data already exists, or push from a script when your program produces it. Select a source below to edit or write content.",
            )
          }}
        </p>
        <article
          v-for="s in sources"
          :key="s.id"
          class="source-card"
          :class="{ selected: s.id === dataSourceID }"
        >
          <div class="source-main">
            <button
              class="text-button source-name"
              @click="selectDataSource(s.id)"
            >
              {{ s.id === dataSourceID ? "✓ " : "" }}{{ s.name }}
            </button>
            <p class="muted">
              {{
                s.mode === "http"
                  ? tr("API采集", "API Poll")
                  : tr("外部上报", "External Push")
              }}
              · {{ revisionLabel(s.revision) }} ·
              {{
                tr(
                  `关联 ${sourceCards(cards, s.id).length} 张卡片`,
                  `${sourceCards(cards, s.id).length} linked cards`,
                )
              }}
            </p>
            <p v-if="s.last_error" class="source-error">{{ s.last_error }}</p>
          </div>
          <div class="source-actions">
            <button
              class="secondary"
              @click="
                newCard();
                sourceChoice = 'existing';
                existingSource = s.id;
              "
            >
              {{ tr("用它新建卡片", "New Card from This") }}
            </button>
            <button class="secondary" @click="editSource(s)">
              {{ tr("编辑", "Edit") }}
            </button>
            <button
              v-if="s.mode === 'http'"
              class="secondary"
              @click="toggleSource(s)"
            >
              {{
                s.enabled
                  ? tr("暂停采集", "Pause Collection")
                  : tr("启用采集", "Resume Collection")
              }}
            </button>
            <button
              class="danger-link"
              :disabled="busy"
              :aria-label="
                tr('删除数据源', 'Delete data source') + ' · ' + s.name
              "
              @click="requestDeletion('source', s.id)"
            >
              {{ tr("删除", "Delete") }}
            </button>
          </div>
        </article>
      </section>
      <div class="two-column">
        <section class="panel">
          <div class="section-title">
            <h2>
              {{
                editingSource
                  ? tr("编辑数据源", "Edit Data Source")
                  : tr("添加数据源", "Add Data Source")
              }}
            </h2>
            <button v-if="editingSource" class="secondary" @click="resetSource">
              {{ tr("取消编辑", "Cancel Editing") }}
            </button>
          </div>
          <form @submit.prevent="createSource">
            <label
              >{{ tr("名称", "Name")
              }}<input
                v-model="sourceName"
                required
                maxlength="40"
                :placeholder="
                  tr('行情、任务或设备状态', 'Quotes, tasks, or device status')
                " /></label
            ><label
              >{{ tr("接入方式", "Ingest Mode")
              }}<select v-model="sourceMode" :disabled="!!editingSource">
                <option value="push">
                  {{
                    tr(
                      "外部工具通过API上报",
                      "External tools push through the API",
                    )
                  }}
                </option>
                <option value="http">
                  {{ tr("服务器直接读取API", "Server reads an API directly") }}
                </option>
              </select></label
            >
            <template v-if="sourceMode === 'http'"
              ><label
                >{{ tr("API地址", "API Address")
                }}<input
                  v-model="sourceURL"
                  type="url"
                  required
                  placeholder="https://api.example.com/data" /></label
              ><label
                >{{ tr("鉴权请求头JSON", "Authentication Header JSON")
                }}<textarea v-model="headers" rows="2" spellcheck="false" />
              </label>
              <div class="form-grid">
                <label
                  >{{ tr("记录或列表路径", "Record or List Path")
                  }}<input
                    v-model="recordPath"
                    :placeholder="
                      tr(
                        '例如：data 或 data.items；留空为根',
                        'Example: data or data.items; blank means the root',
                      )
                    " /></label
                ><label
                  >{{ tr("列表项目标识路径", "Item ID Path")
                  }}<input
                    v-model="itemIDPath"
                    :placeholder="
                      tr(
                        '例如：symbol；单条记录不填',
                        'Example: symbol; leave blank for one record',
                      )
                    "
                /></label>
              </div>
              <label
                >{{ tr("采集周期（秒）", "Collection Interval (seconds)")
                }}<input
                  v-model.number="interval"
                  type="number"
                  min="60"
                  max="86400"
              /></label>
              <h3>{{ tr("字段映射", "Field Mapping") }}</h3>
              <div v-for="(f, i) in mappings" :key="i" class="mapping-row">
                <input
                  v-model="f.key"
                  :aria-label="tr('字段标识', 'Field key')"
                  placeholder="price"
                /><input
                  v-model="f.path"
                  :aria-label="tr('API字段路径', 'API field path')"
                  placeholder="data.price"
                /><select
                  v-model="f.type"
                  :aria-label="tr('字段类型', 'Field type')"
                >
                  <option
                    v-for="t in [
                      'text',
                      'decimal',
                      'integer',
                      'percent',
                      'boolean',
                      'datetime',
                    ]"
                    :key="t"
                  >
                    {{ t }}
                  </option></select
                ><input
                  v-model="f.label"
                  :aria-label="tr('显示名称', 'Display label')"
                  :placeholder="tr('显示名称', 'Label')"
                /><input
                  v-model="f.unit"
                  :aria-label="tr('单位', 'Unit')"
                  :placeholder="tr('单位', 'Unit')"
                /><button
                  type="button"
                  class="text-button"
                  @click="mappings.splice(i, 1)"
                  :disabled="mappings.length === 1"
                >
                  {{ tr("删除", "Remove") }}
                </button>
              </div>
              <button
                type="button"
                class="secondary"
                @click="
                  mappings.push({
                    key: '',
                    path: '',
                    type: 'text',
                    label: '',
                    unit: '',
                  })
                "
              >
                {{ tr("添加字段", "Add Field") }}
              </button>
              <p class="muted">
                {{
                  tr(
                    "鉴权信息留在服务器；编辑时请求头留空保留原鉴权，填{}清空。路径支持点号和数字下标。采集周期不代表桌面刷新承诺。",
                    "Authentication stays on the server. Leave the header blank while editing to keep it, or enter {} to clear it. Paths accept dots and numeric indexes. The collection interval is not a Home Screen refresh guarantee.",
                  )
                }}
              </p></template
            ><button class="primary" :disabled="busy">
              {{
                editingSource
                  ? tr("保存数据源修改", "Save Data Source")
                  : tr("创建数据源", "Create Data Source")
              }}
            </button>
          </form>
        </section>
        <section class="panel">
          <h2>{{ tr("查看与手动更新内容", "View and Update Content") }}</h2>
          <p
            v-if="dataSource?.mode === 'http' && dataSource.enabled"
            class="muted"
          >
            {{
              tr(
                "这个数据源正在自动读取API。手动保存的内容可能被下一次采集替换。",
                "This source is polling an API. A manual save may be replaced by the next collection.",
              )
            }}
          </p>
          <p class="muted">
            {{
              tr(
                "选定数据源后可读取当前内容、手动保存或复制脚本上报地址。每次写入会更新所有使用此源的卡片。",
                "Select a source to read its content, save manually, or copy the script URL. Each write updates every card using that source.",
              )
            }}
          </p>
          <label
            >{{ tr("数据源", "Data Source")
            }}<select
              v-model="dataSourceID"
              @change="selectDataSource(dataSourceID)"
            >
              <option disabled value="">{{ tr("请选择", "Select") }}</option>
              <option v-for="s in sources" :key="s.id" :value="s.id">
                {{ s.name }}
              </option>
            </select></label
          >
          <div class="studio-tabs">
            <button
              class="secondary"
              @click="
                dataEditor = JSON.stringify(
                  sampleState('quotes', locale),
                  null,
                  2,
                )
              "
            >
              {{ tr("虚构行情示例", "Sample Quotes") }}</button
            ><button
              class="secondary"
              @click="
                dataEditor = JSON.stringify(
                  sampleState('task', locale),
                  null,
                  2,
                )
              "
            >
              {{ tr("任务进度示例", "Sample Task") }}</button
            ><button
              class="secondary"
              @click="
                dataEditor = JSON.stringify(dataSource?.state || {}, null, 2)
              "
            >
              {{ tr("读取当前内容", "Load Current Content") }}
            </button>
          </div>
          <textarea
            v-model="dataEditor"
            class="code-editor"
            rows="17"
            :aria-label="tr('卡片数据JSON', 'Card data JSON')"
            spellcheck="false"
          />
          <div class="studio-tabs">
            <button
              class="primary"
              @click="sendData"
              :disabled="busy || !dataSourceID"
            >
              {{ tr("保存最新数据", "Save Latest Data") }}</button
            ><button
              class="secondary"
              @click="sourceAddress"
              :disabled="busy || !dataSourceID"
            >
              {{ tr("复制数据上报地址", "Copy Push URL") }}</button
            ><button
              v-if="dataSource?.mode === 'http'"
              class="secondary"
              @click="poll"
              :disabled="busy || !dataSource.enabled"
            >
              {{ tr("立即采集API", "Collect API Now") }}
            </button>
          </div>
          <p class="muted">
            {{
              tr(
                "每次写入替换最新数据，保留Web设计与手机微调。",
                "Each write replaces the latest data and keeps the Web design and phone adjustments.",
              )
            }}
          </p>
        </section>
      </div>
    </template>
    <template v-else>
      <template v-if="view === 'library'">
        <section class="panel studio-intro">
          <div class="section-title">
            <div>
              <h2>
                {{ tr("我的卡片", "My Cards") }}
                <small>{{
                  tr(`${cards.length} 张`, `${cards.length} cards`)
                }}</small>
              </h2>
              <p class="muted">
                {{
                  tr(
                    "在这里管理已经保存的草稿与已发布卡片。",
                    "Manage saved drafts and published cards here.",
                  )
                }}
              </p>
            </div>
            <button class="primary" @click="newCard" :disabled="busy">
              {{ tr("新建卡片", "New Card") }}
            </button>
          </div>
          <ol class="flow-guide">
            <li>
              <strong>{{ tr("1 接入数据", "1 Connect Data") }}</strong
              ><span>{{
                tr(
                  "读取JSON/API，或让脚本主动上报",
                  "Read a JSON/API or push from a script",
                )
              }}</span>
            </li>
            <li>
              <strong>{{ tr("2 设计样式", "2 Design") }}</strong
              ><span>{{
                tr(
                  "选择布局、字段，可使用AI辅助",
                  "Choose a layout and fields, with optional AI help",
                )
              }}</span>
            </li>
            <li>
              <strong>{{ tr("3 发布订阅", "3 Publish") }}</strong
              ><span>{{
                tr(
                  "手机输入订阅码，持续显示最新内容",
                  "Enter the code on a phone to follow the latest content",
                )
              }}</span>
            </li>
          </ol>
          <details>
            <summary>
              {{
                tr(
                  "脚本、数据源、卡片和订阅码有什么关系？",
                  "How do scripts, sources, cards, and codes relate?",
                )
              }}
            </summary>
            <p>
              {{
                tr(
                  "脚本将JSON发送到数据源专属地址，卡片读取其中的字段并排版。订阅码用于手机添加卡片，不是脚本上报地址。",
                  "A script sends JSON to a source address. Cards read and arrange its fields. A subscription code adds the card on a phone; it is not the script address.",
                )
              }}
            </p>
            <p>
              {{
                tr(
                  "例如“行情”与“服务器状态”各用一个数据源，就有两个独立上报地址；“行情概览”和“行情明细”若共用同一份数据源，脚本上报一次，两张卡片都会更新。",
                  "Quotes and server status can use separate sources and therefore separate push URLs. An overview and a detail card can share one source, so one push updates both.",
                )
              }}
            </p>
          </details>
        </section>
        <label v-if="cards.length" class="library-search"
          >{{ tr("查找卡片", "Find a Card")
          }}<input
            v-model="search"
            :placeholder="
              tr('卡片名称或数据源名称', 'Card or data source name')
            "
        /></label>
        <div class="card-library">
          <article
            v-for="c in filteredCards"
            :key="c.id"
            class="panel managed-card"
          >
            <div class="section-title">
              <h3>{{ c.draft.name }}</h3>
              <span class="status-tag">{{ cardStatus(c, locale) }}</span>
            </div>
            <p class="muted">
              {{ tr("数据源", "Data source") }}{{ locale === "en" ? ": " : "："
              }}{{
                sources.find((s) => s.id === c.source_id)?.name ||
                tr("未找到数据源", "Data source not found")
              }}
            </p>
            <p class="muted">
              {{
                sources.find((s) => s.id === c.source_id)?.state
                  ? tr("已有数据", "Data connected")
                  : tr("等待数据接入", "Waiting for data")
              }}
              ·
              {{
                c.revision === "0"
                  ? tr("手机暂不可订阅", "Not yet subscribable")
                  : tr(
                      `已发布第${c.revision}版`,
                      `Published revision ${c.revision}`,
                    )
              }}
            </p>
            <small class="muted">{{
              !sources.find((s) => s.id === c.source_id)?.state
                ? tr("布局占位预览", "Layout placeholder")
                : c.published
                  ? tr("预览：已发布设计", "Preview: published design")
                  : tr("预览：草稿设计", "Preview: draft design")
            }}</small>
            <div class="library-preview">
              <div
                class="widget-canvas"
                :class="{
                  dark: widgetTheme((c.published || c.draft).theme) === 'dark',
                }"
              >
                <CardPreview
                  :node="(c.published || c.draft).layout"
                  :state="
                    sources.find((s) => s.id === c.source_id)?.state ||
                    neutralState(locale)
                  "
                  :rows="3"
                />
              </div>
            </div>
            <div class="studio-tabs card-actions">
              <button
                class="primary"
                @click="loadCard(c)"
                :aria-label="
                  tr('编辑设计', 'Edit design') + ' · ' + c.draft.name
                "
              >
                {{ tr("编辑设计", "Edit Design") }}</button
              ><button
                class="secondary"
                @click="manageCard(c)"
                :aria-label="
                  tr('接入与订阅', 'Access and subscription') +
                  ' · ' +
                  c.draft.name
                "
              >
                {{ tr("接入与订阅", "Access") }}</button
              ><button
                class="danger-link"
                :disabled="busy"
                :aria-label="
                  tr('删除卡片', 'Delete card') + ' · ' + c.draft.name
                "
                @click="requestDeletion('card', c.id)"
              >
                {{ tr("删除卡片", "Delete Card") }}
              </button>
            </div>
          </article>
        </div>
        <section v-if="!cards.length" class="panel empty-library">
          <h3>{{ tr("创建第一张桌面卡片", "Create Your First Card") }}</h3>
          <p>
            {{
              tr(
                "不必先了解组件或数据ID，跟着新建向导选择接入方式和布局即可。",
                "You do not need to learn components or data IDs first. Follow the wizard to choose a source and layout.",
              )
            }}
          </p>
          <button class="primary" @click="newCard">
            {{ tr("开始创建", "Start") }}
          </button>
        </section>
        <p v-else-if="!filteredCards.length" class="muted">
          {{ tr("没有找到符合条件的卡片。", "No cards match this search.") }}
        </p>
      </template>
      <template v-else-if="view === 'setup'">
        <section class="panel setup-panel">
          <button class="text-button" @click="showLibrary">
            {{ tr("← 返回我的卡片", "← Back to My Cards") }}
          </button>
          <h2>
            {{
              tr(
                "新建卡片 · 第1步：数据从哪里来？",
                "New Card · Step 1: Where does the data come from?",
              )
            }}
          </h2>
          <p class="muted">
            {{
              tr(
                "先给卡片命名、选择接入方式，接着查看数据和设计，最后发布给手机。",
                "Name the card, choose how data arrives, then review the design and publish it to a phone.",
              )
            }}
          </p>
          <label
            >{{ tr("卡片名称", "Card Name")
            }}<input
              v-model="newName"
              maxlength="40"
              :placeholder="
                tr(
                  '例如：工作进度、行情概览、服务器状态',
                  'Example: task progress, market overview, server status',
                )
              "
          /></label>
          <label
            >{{ tr("数据来源", "Data Source")
            }}<select v-model="sourceChoice">
              <option value="new">
                {{
                  tr(
                    "创建独立数据源 · 与其他卡片分开更新",
                    "Create a separate source · updates independently",
                  )
                }}
              </option>
              <option value="existing" :disabled="!sources.length">
                {{
                  tr(
                    "使用已有数据源 · 与使用它的卡片同步更新",
                    "Use an existing source · stays in sync with its cards",
                  )
                }}
              </option>
            </select></label
          >
          <label v-if="sourceChoice === 'existing'"
            >{{ tr("已有数据源", "Existing Source")
            }}<select v-model="existingSource">
              <option v-for="s in sources" :key="s.id" :value="s.id">
                {{ s.name }} ·
                {{
                  s.state
                    ? tr("已有数据", "Has data")
                    : tr("等待数据", "Waiting for data")
                }}
              </option>
            </select></label
          >
          <p v-if="sourceChoice === 'existing'" class="muted">
            {{
              tr(
                `当前使用它的卡片：${
                  sourceCards(cards, existingSource)
                    .map((c) => c.draft.name)
                    .join("、") || "暂无"
                }。这些卡片将共用最新数据，但样式各自独立。`,
                `Cards using it now: ${
                  sourceCards(cards, existingSource)
                    .map((c) => c.draft.name)
                    .join(", ") || "none"
                }. They share the latest data, while each keeps its own design.`,
              )
            }}
          </p>
          <template v-else
            ><div class="choice-grid">
              <button
                type="button"
                :class="['choice', { chosen: newSourceMode === 'http' }]"
                @click="newSourceMode = 'http'"
              >
                <strong>{{ tr("读取 JSON/API", "Read JSON/API") }}</strong
                ><span>{{
                  tr(
                    "我已经有可查询的HTTPS接口",
                    "I already have an HTTPS endpoint",
                  )
                }}</span
                ><small>{{
                  tr(
                    "例如：天气、行情、网站指标。服务器按周期读取。",
                    "Examples: weather, quotes, or site metrics. The server reads on a schedule.",
                  )
                }}</small></button
              ><button
                type="button"
                :class="['choice', { chosen: newSourceMode === 'push' }]"
                @click="newSourceMode = 'push'"
              >
                <strong>{{ tr("工具主动上报", "Tool Pushes Updates") }}</strong
                ><span>{{
                  tr(
                    "我的脚本或业务程序产生新结果",
                    "My script or program produces the result",
                  )
                }}</span
                ><small>{{
                  tr(
                    "例如：备份进度、任务完成、工单变化。获取专属上报地址。",
                    "Examples: backup progress, completed tasks, or ticket changes. You get a dedicated URL.",
                  )
                }}</small>
              </button>
              <button
                type="button"
                :class="['choice', { chosen: newSourceMode === 'ai' }]"
                @click="newSourceMode = 'ai'"
              >
                <strong>{{ tr("AI辅助生成", "AI-Assisted Generation") }}</strong
                ><span>{{
                  tr(
                    "我知道这个接口是做什么的",
                    "I know what this API is for",
                  )
                }}</span
                ><small>{{
                  tr(
                    "填写地址、密钥和需求。生成说明交给你的模型，贴回结果即可。",
                    "Enter the address, key, and request. Send the instructions to your model and paste the result.",
                  )
                }}</small>
              </button>
            </div>
            <template v-if="newSourceMode === 'http'"
              ><label
                >{{ tr("JSON/API地址", "JSON/API Address")
                }}<input
                  v-model="newURL"
                  placeholder="https://api.example.com/status"
                  type="url" /></label
              ><label
                >{{ tr("读取周期（秒）", "Read Interval (seconds)")
                }}<input
                  v-model.number="newInterval"
                  type="number"
                  min="60"
                  max="86400"
              /></label>
              <p class="muted">
                {{
                  tr(
                    '把JSON中的字段映射到卡片。例如接口返回 {"value":68}，下面填写字段路径 value。数值也可由接口返回字符串。',
                    'Map JSON fields onto the card. If the API returns {"value":68}, enter the path value below. Numbers may also arrive as strings.',
                  )
                }}
              </p>
              <div v-for="(f, i) in newMappings" :key="i" class="mapping-row">
                <input
                  v-model="f.key"
                  :aria-label="tr('卡片字段标识', 'Card field key')"
                  placeholder="value"
                /><input
                  v-model="f.path"
                  :aria-label="tr('JSON字段路径', 'JSON field path')"
                  placeholder="data.value"
                /><select
                  v-model="f.type"
                  :aria-label="tr('读取字段类型', 'Field type')"
                >
                  <option value="text">{{ tr("文字", "Text") }}</option>
                  <option value="decimal">{{ tr("数值", "Decimal") }}</option>
                  <option value="percent">{{ tr("百分比", "Percent") }}</option>
                  <option value="integer">{{ tr("整数", "Integer") }}</option>
                  <option value="boolean">
                    {{ tr("是/否", "Yes / No") }}
                  </option></select
                ><input
                  v-model="f.label"
                  :aria-label="tr('字段显示名称', 'Display label')"
                  :placeholder="tr('显示名称', 'Label')"
                /><input
                  v-model="f.unit"
                  :aria-label="tr('字段单位', 'Unit')"
                  :placeholder="tr('单位', 'Unit')"
                /><button
                  class="text-button"
                  :disabled="newMappings.length === 1"
                  @click="newMappings.splice(i, 1)"
                >
                  {{ tr("移除", "Remove") }}
                </button>
              </div>
              <button
                class="secondary"
                @click="
                  newMappings.push({
                    key: '',
                    path: '',
                    type: 'text',
                    label: '',
                    unit: '',
                  })
                "
              >
                {{ tr("增加字段", "Add Field") }}
              </button>
              <details>
                <summary>
                  {{
                    tr(
                      "接口需要鉴权或返回多条记录？",
                      "Does the API need authentication or return multiple records?",
                    )
                  }}
                </summary>
                <label
                  >{{ tr("鉴权请求头JSON", "Authentication Header JSON")
                  }}<textarea
                    v-model="newHeaders"
                    rows="2"
                    placeholder='{"Authorization":"Bearer ..."}'
                  />
                </label>
                <p class="muted">
                  {{
                    tr(
                      "请求头加密保存在服务端。列表路径、稳定记录标识等更多选项可在创建后进入“数据源管理”配置。",
                      "Headers are stored encrypted on the server. List paths and stable record IDs can be configured later under Data Sources.",
                    )
                  }}
                </p>
              </details></template
            >
            <form
              v-else-if="newSourceMode === 'ai'"
              class="ai-guide"
              @submit.prevent="saveAiSource"
            >
              <label
                >{{ tr("API地址", "API Address")
                }}<input
                  v-model="aiURL"
                  type="url"
                  required
                  placeholder="https://api.example.com/data"
              /></label>
              <label
                >{{ tr("API Key", "API Key")
                }}<input
                  v-model="aiKey"
                  type="password"
                  autocomplete="off"
                  spellcheck="false"
                  :placeholder="
                    tr('没有密钥可留空', 'Leave blank if there is no key')
                  "
              /></label>
              <label
                >{{ tr("需求", "Request")
                }}<textarea
                  v-model="aiRequest"
                  rows="4"
                  :placeholder="
                    tr(
                      '例如：这是我的资产汇总。读取总资产，用大号数字显示在中间，单位是美元。',
                      'Example: this is my asset summary. Read the total, show it as a large number, in USD.',
                    )
                  "
              /></label>
              <button
                type="button"
                class="secondary"
                :disabled="busy"
                @click="copySourcePrompt"
              >
                {{ tr("生成说明", "Generate Instructions") }}
              </button>
              <p class="muted">
                {{
                  tr(
                    "说明不含 API Key。交给你自己的模型后，把返回的 JSON 贴在下面。",
                    "The instructions do not contain the API key. Send them to your own model, then paste the returned JSON below.",
                  )
                }}
              </p>
              <label v-if="aiPromptText"
                >{{ tr("交给模型的说明", "Instructions for the Model")
                }}<textarea readonly rows="6" :value="aiPromptText"
              /></label>
              <label
                >{{ tr("模型返回的代码", "Code Returned by the Model")
                }}<textarea
                  v-model="aiResult"
                  rows="8"
                  spellcheck="false"
                  :placeholder="
                    tr(
                      '把模型返回的 JSON 贴在这里。',
                      'Paste the JSON returned by the model.',
                    )
                  "
              /></label>
              <button class="primary" :disabled="busy || !aiResult.trim()">
                {{ busy ? tr("正在保存…", "Saving…") : tr("保存", "Save") }}
              </button>
            </form>
            <p v-else class="muted">
              {{
                tr(
                  "点击下一步后会生成数据源。你可以复制上报地址接到任意脚本，也可先在网页填一份JSON。已有Bot无需改动数据采集逻辑。",
                  "The next step creates the data source. Copy its push URL into any script, or enter JSON here first. An existing bot does not need a new collection design.",
                )
              }}
            </p></template
          >
          <h3 v-if="sourceChoice === 'existing' || newSourceMode !== 'ai'">
            {{ tr("选择起始布局", "Choose a Starting Layout") }}
          </h3>
          <div
            v-if="sourceChoice === 'existing' || newSourceMode !== 'ai'"
            class="choice-grid"
          >
            <button
              v-for="layout in layoutChoices"
              :key="layout.id"
              :class="['choice', { chosen: initialLayout === layout.id }]"
              @click="initialLayout = layout.id"
            >
              <strong>{{
                locale === "en" ? layout.titleEn : layout.title
              }}</strong
              ><span>{{
                locale === "en" ? layout.descriptionEn : layout.description
              }}</span>
            </button>
          </div>
          <div
            v-if="sourceChoice === 'existing' || newSourceMode !== 'ai'"
            class="studio-tabs"
          >
            <button class="secondary" @click="showLibrary">
              {{ tr("取消", "Cancel") }}</button
            ><button
              class="primary"
              @click="startDesign"
              :disabled="busy || !newName.trim()"
            >
              {{
                busy
                  ? tr("正在创建…", "Creating…")
                  : tr(
                      "下一步：接入数据与设计",
                      "Next: Connect Data and Design",
                    )
              }}
            </button>
          </div>
        </section>
      </template>
      <template v-else-if="view === 'manage' && managed">
        <section class="panel">
          <button class="text-button" @click="showLibrary">
            {{ tr("← 返回我的卡片", "← Back to My Cards") }}
          </button>
          <div class="section-title">
            <div>
              <h2>{{ managed.draft.name }}</h2>
              <p class="muted">
                {{ cardStatus(managed, locale) }} ·
                {{ tr("数据源", "Data source") }} {{ managedSource?.name }}
              </p>
            </div>
            <button class="secondary" @click="loadCard(managed)">
              {{ tr("编辑设计", "Edit Design") }}
            </button>
          </div>
          <p>
            {{
              tr(
                "脚本更新上报地址，手机使用订阅码。两者在下方分别配置。",
                "Scripts use the push URL. Phones use the subscription code. Configure them separately below.",
              )
            }}
          </p>
          <div class="source-actions">
            <button
              class="danger-link"
              :disabled="busy"
              @click="requestDeletion('card', managed.id)"
            >
              {{ tr("删除这张卡片", "Delete This Card") }}
            </button>
            <button
              class="text-button"
              @click="openDataSource(managed.source_id)"
            >
              {{
                tr("查看或编辑这份数据源 →", "View or Edit This Data Source →")
              }}
            </button>
          </div>
        </section>
        <CardAccess
          :card="managed"
          :source="managedSource"
          :related="sourceCards(cards, managed.source_id)"
          :csrf="csrf"
        />
      </template>
      <template v-else-if="view === 'editor'">
        <section class="panel compact">
          <button class="text-button" @click="showLibrary">
            {{ tr("← 返回我的卡片", "← Back to My Cards") }}
          </button>
          <div class="section-title">
            <div>
              <h2>
                {{ design.name }} ·
                {{ tr("第2步：设计样式", "Step 2: Design") }}
              </h2>
              <p class="muted">
                {{ tr("数据源", "Data source")
                }}{{ locale === "en" ? ": " : "：" }}{{ source?.name }} ·
                {{
                  source?.state
                    ? tr("已有真实接入数据", "Live data connected")
                    : tr(
                        "还未接入数据，当前仅为布局预览",
                        "No data yet; this is only a layout preview",
                      )
                }}
              </p>
            </div>
            <button
              class="secondary"
              v-if="activeCard"
              @click="manageCard(activeCard)"
            >
              {{ tr("第3步：接入与订阅", "Step 3: Access") }}
            </button>
          </div>
          <details :open="integrationOpen">
            <summary>
              {{ tr("接入数据", "Connect Data") }} ·
              {{
                source?.state
                  ? tr(
                      "已收到内容，可查看或更新",
                      "Content received; you can view or update it",
                    )
                  : tr(
                      "先完成这一步，才能发布",
                      "Finish this step before publishing",
                    )
              }}
            </summary>
            <p>
              {{
                tr(
                  "脚本向本数据源地址PUT JSON；或在此手动保存。若选择读取API，在数据源管理中检查读取结果。",
                  "A script PUTs JSON to this source address, or you can save it here. For an API source, check the read result under Data Sources.",
                )
              }}
            </p>
            <div class="studio-tabs">
              <button
                class="secondary"
                @click="copyEditorAddress"
                :disabled="busy"
              >
                {{ tr("复制脚本上报地址", "Copy Script URL") }}</button
              ><button class="secondary" @click="openDataSource(sourceID)">
                {{ tr("配置数据源", "Configure Source") }}</button
              ><button
                class="secondary"
                @click="
                  editorData = JSON.stringify(
                    dataExample(source?.state, locale),
                    null,
                    2,
                  )
                "
              >
                {{ tr("读取当前JSON", "Load Current JSON") }}
              </button>
            </div>
            <h3>{{ tr("手动填写一份数据", "Enter Data Manually") }}</h3>
            <CardDataInput v-model="editorData" /><button
              class="secondary"
              @click="sendEditorData"
              :disabled="busy"
            >
              {{
                tr("保存这份内容到数据源", "Save This Content to the Source")
              }}
            </button>
            <p class="muted">
              {{
                tr(
                  "会更新使用此数据源的所有卡片。初始占位内容不会自动发送，只有点击保存才写入。",
                  "This updates every card using the source. Placeholder content is not sent until you save it.",
                )
              }}
            </p>
          </details>
        </section>
        <div class="studio-layout">
          <section class="panel studio-editor">
            <div class="form-grid">
              <label
                >{{ tr("卡片名称", "Card Name")
                }}<input v-model="design.name" maxlength="40" /></label
              ><label
                >{{ tr("数据源", "Data Source")
                }}<select v-model="sourceID" :disabled="!!activeID">
                  <option disabled value="">
                    {{
                      tr("先到“数据源”添加", "Add one under Data Sources first")
                    }}
                  </option>
                  <option v-for="s in sources" :key="s.id" :value="s.id">
                    {{ s.name }}
                  </option>
                </select></label
              >
            </div>
            <div class="studio-tabs">
              <button class="secondary" @click="replaceLayout('items')">
                {{ tr("多条记录布局", "Multi-row Layout") }}</button
              ><button class="secondary" @click="replaceLayout('fields')">
                {{ tr("信息列表布局", "Field List Layout") }}</button
              ><button class="secondary" @click="replaceLayout('blank')">
                {{ tr("空白布局", "Blank Layout") }}
              </button>
            </div>
            <div class="studio-tabs">
              <button
                :class="mode === 'visual' ? 'primary' : 'secondary'"
                @click="changeMode('visual')"
              >
                {{ tr("可视化编辑", "Visual Editor") }}</button
              ><button
                :class="mode === 'code' ? 'primary' : 'secondary'"
                @click="changeMode('code')"
              >
                {{ tr("JSON代码", "JSON Code") }}</button
              ><button
                :class="mode === 'ai' ? 'primary' : 'secondary'"
                @click="changeMode('ai')"
              >
                {{ tr("AI辅助设计", "AI Design") }}
              </button>
            </div>
            <section v-if="mode === 'ai'" class="ai-guide">
              <h3>
                {{
                  tr(
                    "让AI帮你排版已有数据",
                    "Let AI Arrange the Data You Already Have",
                  )
                }}
              </h3>
              <p>
                {{
                  tr(
                    "AI根据你的要求生成卡片设计JSON；数据接入和更新仍由数据源完成。把下方说明交给你选择的AI，返回后在这里校验预览。",
                    "AI returns card-design JSON from your request. The data source still receives and updates the data. Send the instructions below to your chosen AI, then validate the result here.",
                  )
                }}
              </p>
              <details>
                <summary>
                  {{
                    tr(
                      "先看一个完整例子：任务进度卡片",
                      "See a complete example: a task-progress card",
                    )
                  }}
                </summary>
                <p>
                  {{
                    tr(
                      "输入数据包含 progress（完成率）和 status（状态）。给AI的要求：“中间突出显示完成率，下面显示状态，简洁清楚。”",
                      "The input has progress and status. The request to AI is: “Emphasize completion in the center and show status underneath. Keep it clear.”",
                    )
                  }}
                </p>
                <pre>{{ JSON.stringify(demoState, null, 2) }}</pre>
                <p>
                  {{
                    tr(
                      "一份符合要求的设计结果如下，右侧展示其效果：",
                      "A valid design result is below, with its effect shown alongside:",
                    )
                  }}
                </p>
                <pre>{{ JSON.stringify(demoDesign, null, 2) }}</pre>
                <button
                  class="secondary"
                  @click="copy(JSON.stringify(demoDesign, null, 2))"
                >
                  {{ tr("复制这个示例JSON", "Copy Example JSON") }}
                </button>
                <div class="widget-canvas">
                  <CardPreview
                    :node="demoDesign.layout"
                    :state="demoState"
                    :rows="3"
                  />
                </div>
                <p class="muted">
                  {{
                    tr(
                      "这是说明用途的完整输入/输出例子。它不会改动你的数据或已发布卡片。",
                      "This is a complete input and output example. It does not change your data or published cards.",
                    )
                  }}
                </p>
              </details>
              <h3>
                {{
                  tr(
                    "1. 描述你想要的展示效果",
                    "1. Describe the layout you want",
                  )
                }}
              </h3>
              <textarea
                v-model="aiGoal"
                rows="3"
                :aria-label="tr('给AI的排版要求', 'Layout request for AI')"
              />
              <h3>
                {{
                  tr(
                    "2. 复制说明，发送给你选择的AI",
                    "2. Copy the instructions to your chosen AI",
                  )
                }}
              </h3>
              <p class="muted">
                {{
                  tr(
                    "说明包含当前字段结构、设计规则和当前布局，不包含数据源地址、接口密钥或连接凭证。",
                    "The instructions include the current fields, design rules, and layout. They do not include source URLs, API secrets, or connection credentials.",
                  )
                }}
              </p>
              <button class="secondary" @click="copy(aiPrompt())">
                {{ tr("复制完整AI设计说明", "Copy Full AI Instructions") }}
              </button>
              <details>
                <summary>
                  {{ tr("查看将复制的内容", "View What Will Be Copied") }}
                </summary>
                <pre>{{ aiPrompt() }}</pre>
              </details>
              <h3>
                {{
                  tr("3. 粘贴AI返回的JSON", "3. Paste the JSON returned by AI")
                }}
              </h3>
              <textarea
                v-model="code"
                @input="codeDirty = true"
                rows="14"
                class="code-editor"
                :aria-label="tr('AI返回的卡片JSON', 'Card JSON returned by AI')"
                spellcheck="false"
              /><button
                class="primary"
                :disabled="busy"
                @click="
                  action(async () => {
                    await importCode();
                    mode = 'visual';
                    notice = tr(
                      '设计已校验并导入。请检查右侧预览和字段，再保存或发布。',
                      'Design validated and imported. Check the preview and fields, then save or publish.',
                    );
                  })
                "
              >
                {{ tr("校验并预览AI设计", "Validate and Preview") }}
              </button>
              <p class="muted">
                {{
                  tr(
                    "校验失败保留输入；校验成功只更新当前编辑草稿，发布前不会影响手机。",
                    "Invalid input is kept. A valid result updates only the current draft and does not affect phones until you publish.",
                  )
                }}
              </p>
            </section>
            <template v-else-if="mode === 'code'">
              <textarea
                v-model="code"
                @input="codeDirty = true"
                rows="22"
                class="code-editor"
                :aria-label="tr('卡片设计代码', 'Card design code')"
                spellcheck="false"
              /><button
                class="secondary"
                @click="
                  action(async () => {
                    await importCode();
                    notice = tr(
                      '代码已校验并导入，可切换可视化继续调整。',
                      'Code validated and imported. Switch to the visual editor to continue.',
                    );
                  })
                "
                :disabled="busy"
              >
                {{ tr("校验并导入代码", "Validate and Import Code") }}
              </button>
              <p class="muted">
                {{
                  tr(
                    "AI返回JSON后粘贴于此。错误会保留原代码；导入不会提前发布。",
                    "Paste the JSON returned by AI here. Errors keep your code; importing does not publish early.",
                  )
                }}
              </p></template
            >
            <div v-else class="visual-layout">
              <div class="component-tree">
                <h3>{{ tr("显示内容", "Content") }}</h3>
                <p class="muted">
                  {{
                    tr(
                      "点击一个内容项，选择显示字段、名称和格式；也可以直接点击右侧预览。",
                      "Select an item to choose its field, name, and format. You can also click the preview.",
                    )
                  }}
                </p>
                <div v-if="!advancedLayout" class="field-buttons">
                  <button
                    v-for="leaf in leaves"
                    :key="leaf.id"
                    :class="leaf.id === selectedID ? 'primary' : 'secondary'"
                    @click="selectedID = leaf.id"
                  >
                    {{ nodeLabel(leaf) }}
                  </button>
                </div>
                <label class="advanced-toggle"
                  ><input type="checkbox" v-model="advancedLayout" />{{
                    tr(
                      "高级布局：组件树、排序和添加",
                      "Advanced layout: component tree, order, and adding",
                    )
                  }}</label
                >
                <CardTree
                  v-if="advancedLayout"
                  :node="design.layout"
                  :selected="selectedID"
                  root
                  @select="selectedID = $event"
                  @move="move"
                  @drop="drop"
                /><label v-if="advancedLayout"
                  >{{ tr("添加组件", "Add Component")
                  }}<select
                    value=""
                    @change="
                      add(($event.target as HTMLSelectElement).value);
                      ($event.target as HTMLSelectElement).value = '';
                    "
                  >
                    <option disabled value="">
                      {{ tr("选择组件", "Choose a component") }}
                    </option>
                    <option v-for="kind in kinds" :key="kind" :value="kind">
                      {{ kindName(kind, locale) }}
                    </option>
                  </select></label
                >
              </div>
              <div v-if="node" class="node-inspector">
                <h3>
                  {{ kindName(node.type, locale) }}
                  <small v-if="advancedLayout">{{ node.id }}</small>
                </h3>
                <label v-if="['text', 'number', 'badge'].includes(node.type)"
                  >{{ tr("文字内容", "Text")
                  }}<input
                    v-model="node.text"
                    :placeholder="
                      tr('绑定字段时留空', 'Leave blank when a field is bound')
                    " /></label
                ><label
                  >{{ tr("显示名称", "Display Label")
                  }}<input
                    v-model="node.label"
                    :placeholder="
                      tr('可选的小标题', 'Optional caption')
                    " /></label
                ><label
                  v-if="
                    ['text', 'number', 'badge', 'chart'].includes(node.type)
                  "
                  >{{ tr("显示哪个字段", "Displayed Field")
                  }}<select v-model="node.bind">
                    <option value="">
                      {{
                        tr(
                          "不绑定字段（填写固定文字）",
                          "No field (use fixed text)",
                        )
                      }}
                    </option>
                    <option
                      v-for="field in availableFields"
                      :key="field.path"
                      :value="field.path"
                    >
                      {{ field.label }}
                    </option>
                    <option
                      v-if="
                        node.bind &&
                        !availableFields.some((f) => f.path === node?.bind)
                      "
                      :value="node.bind"
                    >
                      {{ node.bind }} ·
                      {{ tr("当前数据未提供", "Not in current data") }}
                    </option></select
                  ><small v-if="!source?.state">{{
                    tr(
                      "接入数据后，这里会列出你的实际字段。",
                      "Your actual fields appear here after data is connected.",
                    )
                  }}</small></label
                ><label v-if="advancedLayout"
                  >{{ tr("高级字段路径", "Advanced Field Path")
                  }}<input
                    v-model="node.bind"
                    :placeholder="
                      tr(
                        'fields.value 或 series.history',
                        'fields.value or series.history',
                      )
                    "
                /></label>
                <div class="inspector-grid">
                  <label v-if="['text', 'number', 'badge'].includes(node.type)"
                    >{{ tr("字号", "Font Size")
                    }}<input
                      type="number"
                      :value="node.font_size ?? ''"
                      min="10"
                      max="32"
                      @input="number($event, 'font_size')" /></label
                  ><label v-if="['number', 'badge'].includes(node.type)"
                    >{{ tr("小数位", "Decimals")
                    }}<input
                      type="number"
                      :value="node.decimals ?? ''"
                      min="0"
                      max="18"
                      @input="number($event, 'decimals')" /></label
                  ><label
                    v-if="
                      ['row', 'column', 'grid', 'list', 'spacer'].includes(
                        node.type,
                      )
                    "
                    >{{ tr("间距", "Spacing")
                    }}<input
                      type="number"
                      :value="node.spacing ?? ''"
                      min="0"
                      max="24"
                      @input="number($event, 'spacing')" /></label
                  ><label v-if="advancedLayout"
                    >{{ tr("内边距", "Padding")
                    }}<input
                      type="number"
                      :value="node.padding ?? ''"
                      min="0"
                      max="24"
                      @input="number($event, 'padding')" /></label
                  ><label v-if="advancedLayout"
                    >{{ tr("圆角", "Corner Radius")
                    }}<input
                      type="number"
                      :value="node.radius ?? ''"
                      min="0"
                      max="24"
                      @input="number($event, 'radius')" /></label
                  ><label v-if="advancedLayout"
                    >{{ tr("弹性优先级", "Flex Priority")
                    }}<input
                      type="number"
                      :value="node.flex ?? ''"
                      min="0"
                      max="4"
                      @input="number($event, 'flex')"
                  /></label>
                </div>
                <label v-if="advancedLayout"
                  >{{ tr("对齐", "Alignment")
                  }}<select v-model="node.alignment">
                    <option value="leading">{{ tr("靠左", "Leading") }}</option>
                    <option value="center">{{ tr("居中", "Center") }}</option>
                    <option value="trailing">
                      {{ tr("靠右", "Trailing") }}
                    </option>
                  </select></label
                ><label
                  v-if="
                    advancedLayout &&
                    ['text', 'number', 'badge'].includes(node.type)
                  "
                  >{{ tr("字重", "Weight")
                  }}<select v-model="node.weight">
                    <option value="regular">{{ tr("常规", "Regular") }}</option>
                    <option value="medium">{{ tr("中等", "Medium") }}</option>
                    <option value="semibold">
                      {{ tr("半粗", "Semibold") }}
                    </option>
                    <option value="bold">{{ tr("粗体", "Bold") }}</option>
                  </select></label
                ><label
                  v-if="
                    advancedLayout &&
                    ['text', 'number', 'badge'].includes(node.type)
                  "
                  >{{ tr("颜色", "Color")
                  }}<input
                    v-model="node.color"
                    placeholder="primary / secondary / accent / #RRGGBB" /></label
                ><label v-if="advancedLayout"
                  >{{ tr("背景", "Background")
                  }}<input
                    v-model="node.background"
                    placeholder="#RRGGBB" /></label
                ><label
                  v-if="
                    advancedLayout && ['number', 'badge'].includes(node.type)
                  "
                  >{{ tr("数值格式", "Number Format")
                  }}<select v-model="node.format">
                    <option value="">
                      {{ tr("跟随数据", "Follow Data") }}
                    </option>
                    <option value="decimal">
                      {{ tr("十进制", "Decimal") }}
                    </option>
                    <option value="percent">
                      {{ tr("百分比", "Percent") }}
                    </option>
                  </select></label
                ><label
                  v-if="
                    advancedLayout &&
                    ['text', 'number', 'badge'].includes(node.type)
                  "
                  >{{ tr("条件颜色", "Conditional Color")
                  }}<select v-model="node.color_rule">
                    <option value="">{{ tr("不使用", "None") }}</option>
                    <option value="signed">
                      {{
                        tr(
                          "正数绿色，负数红色",
                          "Green when positive, red when negative",
                        )
                      }}
                    </option>
                  </select></label
                ><label v-if="node.type === 'list'"
                  >{{ tr("最多显示行数", "Maximum Rows")
                  }}<input
                    type="number"
                    :value="node.limit"
                    min="1"
                    max="20"
                    @input="number($event, 'limit')" /></label
                ><label v-if="node.type === 'grid'"
                  >{{ tr("网格列数", "Grid Columns")
                  }}<input
                    type="number"
                    :value="node.columns"
                    min="1"
                    max="4"
                    @input="number($event, 'columns')" /></label
                ><button
                  class="danger-link"
                  v-if="advancedLayout"
                  @click="removeNode"
                  :disabled="node.id === design.layout.id"
                >
                  {{ tr("删除组件", "Delete Component") }}
                </button>
              </div>
            </div>
            <div class="studio-tabs">
              <button
                class="secondary"
                @click="saveDraft"
                :disabled="busy || !sourceID"
              >
                {{ tr("保存草稿", "Save Draft") }}</button
              ><button
                class="primary"
                @click="publish"
                :disabled="busy || !sourceID || !source?.state"
              >
                {{ tr("发布到设备", "Publish to Devices") }}</button
              ><span class="muted"
                >{{
                  dirty
                    ? tr("有未保存修改", "Unsaved changes")
                    : tr("草稿已保存", "Draft saved")
                }}
                · {{ revisionLabel(publishedRevision) }}</span
              >
            </div>
          </section>
          <div class="studio-preview">
            <section class="panel">
              <h2>{{ tr("小组件预览", "Widget Preview") }}</h2>
              <p v-if="unmatched.length" class="banner error">
                {{
                  tr(
                    `这些内容还没有绑定到实际数据：${unmatched.join("、")}。在左侧选择对应显示字段后再发布。`,
                    `These items are not bound to current data: ${unmatched.join(", ")}. Choose their fields before publishing.`,
                  )
                }}
              </p>
              <div class="form-grid">
                <label
                  >{{ tr("尺寸", "Size")
                  }}<select v-model="previewFamily">
                    <option value="small">{{ tr("小", "Small") }}</option>
                    <option value="medium">{{ tr("中", "Medium") }}</option>
                    <option value="large">{{ tr("大", "Large") }}</option>
                    <option value="extraLarge">
                      {{ tr("超大 · iPad", "Extra Large · iPad") }}
                    </option>
                  </select></label
                ><label
                  >{{ tr("外观", "Appearance")
                  }}<select v-model="design.theme">
                    <option value="system">
                      {{ tr("跟随系统", "Follow System") }}
                    </option>
                    <option value="light">{{ tr("浅色", "Light") }}</option>
                    <option value="dark">{{ tr("深色", "Dark") }}</option>
                  </select></label
                >
              </div>
              <div class="preview-stage">
                <div
                  class="widget-canvas"
                  :class="[
                    previewFamily,
                    { dark: widgetTheme(design.theme) === 'dark' },
                  ]"
                >
                  <CardPreview
                    :node="design.layout"
                    :state="previewState"
                    :rows="
                      previewFamily === 'small'
                        ? 1
                        : previewFamily === 'medium'
                          ? 3
                          : 12
                    "
                    :selected="selectedID"
                    editable
                    @select="selectedID = $event"
                  /><small class="data-stamp">{{
                    isSample
                      ? tr(
                          "布局占位预览 · 尚未接入数据",
                          "Layout placeholder · no data yet",
                        )
                      : tr(
                          `已接入数据 · 第${source?.revision}版`,
                          `Data connected · revision ${source?.revision}`,
                        )
                  }}</small>
                </div>
              </div>
              <p class="muted">
                {{
                  tr(
                    "分别检查各尺寸；真机字体和系统边距以实际渲染为准。",
                    "Check each size. Fonts and system margins on a real device follow its renderer.",
                  )
                }}
              </p>
            </section>
            <section class="panel">
              <h2>
                {{ tr("第3步：发布到手机", "Step 3: Publish to Phones") }}
              </h2>
              <p class="muted">
                {{
                  tr(
                    "保存草稿用于继续编辑；发布后订阅设备才会跟随新设计。",
                    "Save a draft to keep editing. Subscribed devices follow the new design only after you publish.",
                  )
                }}
              </p>
              <p v-if="!source?.state">
                {{
                  tr(
                    "请先在上方“接入数据”保存有效内容，再发布。",
                    "Save valid content under Connect Data before publishing.",
                  )
                }}
              </p>
              <button
                class="primary"
                :disabled="busy || !activeCard || publishedRevision === '0'"
                @click="activeCard && manageCard(activeCard)"
              >
                {{ tr("打开接入与订阅管理", "Open Access and Subscriptions") }}
              </button>
            </section>
          </div>
        </div>
      </template>
    </template>
  </div>
</template>

<style scoped>
.studio-tabs {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
  margin-bottom: 16px;
}
.studio-tabs button {
  padding: 9px 14px;
}
.studio-layout {
  display: grid;
  grid-template-columns: minmax(0, 1.35fr) minmax(320px, 0.9fr);
  gap: 22px;
  align-items: start;
}
.studio-editor,
.studio-preview {
  min-width: 0;
}
.studio-preview {
  position: sticky;
  top: 18px;
}
.visual-layout {
  display: grid;
  grid-template-columns: minmax(220px, 0.9fr) minmax(240px, 1.1fr);
  gap: 16px;
  margin: 8px 0 18px;
}
.component-tree,
.node-inspector {
  min-width: 0;
}
.node-inspector {
  border: 1px solid var(--border);
  border-radius: 14px;
  padding: 16px 16px 4px;
  background: var(--surface-subtle);
}
.inspector-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0 12px;
}
.inspector-grid label {
  min-width: 0;
}
.preview-stage {
  overflow: auto;
  padding: 8px 2px 12px;
}
.widget-canvas {
  --card-text: #1b2434;
  --card-muted: #66758a;
  --card-line: #e4e9f0;
  background: #ffffff;
  color: var(--card-text);
  border: 1px solid var(--border-strong);
  border-radius: 22px;
  padding: 16px;
  width: min(100%, 350px);
  min-height: 170px;
  display: flex;
  flex-direction: column;
  box-shadow: var(--shadow);
  margin: auto;
}
.widget-canvas.small {
  width: 170px;
  min-height: 170px;
}
.widget-canvas.large {
  min-height: 350px;
}
.widget-canvas.extraLarge {
  width: min(100%, 680px);
  min-height: 350px;
}
.widget-canvas.dark {
  --card-text: #e6ebf5;
  --card-muted: #a6afbf;
  --card-line: #303846;
  background: #1e2530;
  border-color: #303846;
}
.data-stamp {
  font-size: 11px;
  color: var(--card-muted);
  margin-top: auto;
  padding-top: 8px;
}
.source-card {
  display: grid;
  grid-template-columns: minmax(220px, 1fr) minmax(220px, auto);
  gap: 12px 18px;
  align-items: center;
  padding: 14px 16px;
  margin: 10px 0;
  border: 1px solid var(--border);
  border-radius: 14px;
  background: var(--surface-subtle);
}
.source-card.selected {
  border-color: var(--accent-border);
  background: var(--accent-soft);
}
.source-main {
  min-width: 0;
}
.source-name {
  padding: 0;
  font-size: 15px;
  font-weight: 700;
  color: var(--text);
}
.source-actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 8px;
}
.source-error {
  color: var(--danger);
  margin: 4px 0 0;
}
.mapping-row {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(132px, 1fr));
  gap: 8px;
  align-items: center;
  margin-bottom: 10px;
  padding: 12px;
  border: 1px solid var(--border);
  border-radius: 12px;
  background: var(--surface);
}
.mapping-row input,
.mapping-row select {
  min-width: 0;
  margin-top: 0;
}
.subscription-code {
  margin-top: 16px;
}
.flow-guide {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
  list-style: none;
  padding: 0;
  margin: 18px 0 8px;
}
.flow-guide li {
  display: grid;
  gap: 6px;
  padding: 16px;
  border-radius: 14px;
  background: var(--surface-subtle);
  border: 1px solid var(--border);
}
.flow-guide span,
.choice span,
.choice small {
  color: var(--text-secondary);
  font-weight: 500;
}
.card-library {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 340px), 1fr));
  gap: 18px;
}
.managed-card {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.status-tag {
  font-size: 12px;
  border-radius: 999px;
  padding: 5px 10px;
  background: var(--accent-soft);
  color: var(--accent);
  white-space: nowrap;
}
.library-preview {
  padding: 12px 0;
  overflow: auto;
}
.library-preview .widget-canvas {
  width: min(100%, 350px);
  min-height: 180px;
}
.library-search {
  max-width: 420px;
}
.setup-panel {
  max-width: 920px;
}
.choice-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
  margin: 16px 0;
}
.choice {
  display: grid;
  text-align: left;
  gap: 6px;
  padding: 16px;
  border: 1px solid var(--border);
  border-radius: 14px;
  background: var(--surface);
  color: inherit;
}
.choice:hover {
  border-color: var(--accent-border);
}
.choice.chosen {
  border-color: var(--accent);
  background: var(--accent-soft);
}
.field-buttons {
  display: grid;
  gap: 8px;
  margin: 12px 0;
}
.field-buttons button {
  text-align: left;
}
.advanced-toggle {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 8px 0 12px;
  color: var(--text-secondary);
}
.advanced-toggle input {
  width: auto;
  margin: 0;
}
.card-actions {
  display: grid;
  grid-template-columns: 1fr 1fr;
  margin-top: auto;
}
.card-actions .danger-link {
  grid-column: 1 / -1;
  justify-self: start;
}
.ai-guide {
  display: grid;
  gap: 8px;
}
.ai-guide pre {
  font-size: 12px;
  background: var(--code-bg);
  border: 1px solid var(--border);
  padding: 14px;
  border-radius: 12px;
  max-height: 320px;
  overflow: auto;
}
.navigation-confirm {
  position: sticky;
  top: 8px;
  z-index: 5;
}
.empty-library {
  text-align: center;
  margin-top: 8px;
}
.delete-overlay {
  width: min(680px, calc(100% - 32px));
  max-width: calc(100% - 32px);
  padding: 0;
  border: 0;
  background: transparent;
  color: inherit;
}
.delete-overlay::backdrop {
  background: rgba(8, 13, 24, 0.62);
}
.delete-dialog {
  width: min(640px, 100%);
  max-height: min(85vh, 760px);
  overflow: auto;
}
.delete-relations {
  padding-left: 22px;
  line-height: 1.7;
}
.delete-relations small {
  display: block;
  color: var(--text-muted);
}
.destructive-button {
  background: var(--danger);
  color: white;
}
.studio-editor > .studio-tabs:last-of-type {
  margin-top: 8px;
  padding-top: 14px;
  border-top: 1px solid var(--border);
}
@media (max-width: 1100px) {
  .studio-layout,
  .source-card,
  .visual-layout,
  .choice-grid,
  .flow-guide {
    grid-template-columns: 1fr;
  }
  .studio-preview {
    position: static;
  }
  .source-actions,
  .card-actions {
    justify-content: flex-start;
  }
}
@media (max-width: 680px) {
  .inspector-grid,
  .card-actions {
    grid-template-columns: 1fr;
  }
  .node-inspector {
    padding: 12px 12px 0;
  }
  .widget-canvas,
  .widget-canvas.small,
  .widget-canvas.extraLarge {
    width: min(100%, 350px);
  }
}
</style>
