<script setup lang="ts">
import { randomID } from "./random";
import { copyText } from "./clipboard";
import { ref, computed, onMounted, onUnmounted } from "vue";
import CardStudio from "./CardStudio.vue";
import {
  locale,
  themeMode,
  setLocale,
  setThemeMode,
  tr,
  localizeErrorMessage,
  type ThemeMode,
} from "./i18n";
type Row = Record<string, any>;
const empty = () => ({
  devices: [],
  streams: [],
  messages: [],
  deliveries: [],
});
const user = ref<Row | null>(null),
  data = ref<Row>(empty());
const page = ref("home"),
  username = ref("admin"),
  password = ref(""),
  busy = ref(false),
  error = ref(""),
  notice = ref(""),
  csrf = ref("");
const apns = ref<Row>({ configured: false });
const cards = ref<Row[]>([]),
  sources = ref<Row[]>([]);
const menu = computed(() => [
  { id: "home", name: tr("概览", "Overview"), icon: "home" },
  { id: "send", name: tr("发送消息", "Messages"), icon: "send" },
  { id: "studio", name: tr("卡片工作台", "Card Studio"), icon: "studio" },
  { id: "streams", name: tr("设备数据", "Device Data"), icon: "streams" },
  { id: "devices", name: tr("接入设备", "Devices"), icon: "devices" },
  { id: "history", name: tr("发送记录", "Delivery Log"), icon: "history" },
  {
    id: "settings",
    name: tr("服务器设置", "Server Settings"),
    icon: "settings",
  },
]);
const publishedCards = computed(() =>
  cards.value.filter((c) => c.revision && c.revision !== "0"),
);
const collectingSources = computed(() =>
  sources.value.filter((s) => s.mode === "http" && s.enabled),
);
const sourceErrors = computed(() => sources.value.filter((s) => s.last_error));
const pushSources = computed(() =>
  sources.value.filter((s) => s.mode !== "http"),
);
const notifiedDevices = computed(() =>
  devices.value.filter((d) => d.has_apns_token),
);
function openPage(id: string) {
  page.value = id;
  error.value = "";
  notice.value = "";
}
const devices = computed<Row[]>(() =>
  data.value.devices.filter((d: Row) => !d.revoked),
);
const active = computed(() => devices.value.filter((d) => d.enabled));
const message = ref({
  title: "",
  body: "",
  targets: [] as string[],
  level: "active",
  sound: "default",
  url: "",
});
const defaultRoute = ref<Row>({
  configured: false,
  device_ids: [],
  revision: "0",
});
const routeETag = ref('"route-0"');
let routeInitialized = false;
const routeChanged = computed(
  () =>
    JSON.stringify([...message.value.targets].sort()) !==
    JSON.stringify([...defaultRoute.value.device_ids].sort()),
);
function useSavedRecipients() {
  message.value.targets = [...defaultRoute.value.device_ids];
}
const recipientRows = computed<Row[]>(() => {
  const rows: Row[] = devices.value.map((d) => ({
    ...d,
    unavailable: !d.enabled,
  }));
  for (const id of message.value.targets)
    if (!rows.some((d) => d.id === id))
      rows.push({
        id,
        name: tr("已移除的设备", "Removed device"),
        unavailable: true,
      });
  return rows;
});
function selectAllRecipients() {
  message.value.targets = active.value.map((d) => d.id);
}
const stateDevice = ref(""),
  dataID = ref("task_progress"),
  etag = ref(""),
  loadedIdentity = ref(""),
  advanced = ref(false),
  editor = ref("");
type FieldRow = {
  key: string;
  label: string;
  type: string;
  value: string;
  unit: string;
  missing: boolean;
};
const stateExtras = ref<Row>({}),
  extrasIdentity = ref("");
const fields = ref<FieldRow[]>([
  {
    key: "progress",
    label: tr("完成率", "Completion"),
    type: "percent",
    value: "68",
    unit: "",
    missing: false,
  },
  {
    key: "status",
    label: tr("状态", "Status"),
    type: "text",
    value: tr("运行中", "Running"),
    unit: "",
    missing: false,
  },
]);
const availableStates = computed<Row[]>(() =>
  data.value.streams.filter((s: Row) => s.device_id === stateDevice.value),
);
const identity = () => stateDevice.value + ":" + dataID.value;
const statePath = () =>
  "widgets/" +
  encodeURIComponent(dataID.value) +
  "/state?device_id=" +
  encodeURIComponent(stateDevice.value);
const selectedDevice = ref(""),
  access = ref<Row | null>(null),
  revokeTarget = ref("");
const currentPassword = ref(""),
  newPassword = ref("");
let pendingMessage: { body: string; key: string } | null = null,
  pendingState: { body: string; key: string } | null = null;
function fail(value: unknown, fallback: string) {
  throw new Error(
    localizeErrorMessage(typeof value === "string" && value ? value : fallback),
  );
}
async function api(
  path: string,
  method = "GET",
  body?: unknown,
  headers: Record<string, string> = {},
) {
  const res = await fetch("/v1/" + path, {
    method,
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      ...(method === "GET" ? {} : { "X-CSRF-Token": csrf.value }),
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const value = await res.json().catch(() => null);
  if (!res.ok) {
    if (res.status === 401) user.value = null;
    fail(
      value?.error?.message,
      tr(
        "请求未完成，请稍后重试。",
        "Request could not be completed. Please try again.",
      ),
    );
  }
  return { data: value.data, etag: res.headers.get("ETag") || "" };
}
async function action(fn: () => Promise<void>) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    await fn();
  } catch (e) {
    error.value =
      e instanceof Error
        ? e.message
        : tr("操作未完成", "Operation could not be completed");
  } finally {
    busy.value = false;
  }
}
async function refresh() {
  const [dash, route, cardList, sourceList] = await Promise.all([
    api("dashboard"),
    api("message-route"),
    api("cards"),
    api("card-sources"),
  ]);
  data.value = dash.data;
  cards.value = cardList.data.cards || [];
  sources.value = sourceList.data.sources || [];
  defaultRoute.value = route.data;
  routeETag.value = `"route-${route.data.revision}"`;
  if (!routeInitialized) {
    useSavedRecipients();
    routeInitialized = true;
  }
  if (
    !stateDevice.value ||
    !active.value.some((d) => d.id === stateDevice.value)
  )
    stateDevice.value = active.value[0]?.id || "";
  try {
    apns.value = (await api("apns")).data;
  } catch {
    apns.value = { configured: null };
  }
}
async function login() {
  await action(async () => {
    const r = await api("auth/login", "POST", {
      username: username.value,
      password: password.value,
    });
    user.value = r.data;
    csrf.value = r.data.csrf_token;
    password.value = "";
    await refresh();
  });
}
async function logout() {
  await action(async () => {
    await api("auth/logout", "POST", {});
    user.value = null;
    csrf.value = "";
    data.value = empty();
    access.value = null;
    selectedDevice.value = "";
    editor.value = "";
    pendingMessage = pendingState = null;
    message.value.targets = [];
    routeInitialized = false;
    defaultRoute.value = { configured: false, device_ids: [], revision: "0" };
  });
}
async function saveRecipients() {
  await action(async () => {
    const response = await api(
      "message-route",
      "PUT",
      { device_ids: [...message.value.targets].sort() },
      { "If-Match": routeETag.value },
    );
    defaultRoute.value = response.data;
    routeETag.value = `"route-${response.data.revision}"`;
    notice.value = message.value.targets.length
      ? tr(
          `已保存 ${message.value.targets.length} 台自动推送接收设备。`,
          `Saved ${message.value.targets.length} automatic recipients.`,
        )
      : tr(
          "已保存空列表，自动消息分发已暂停。",
          "Saved an empty list. Automatic delivery is paused.",
        );
  });
}
async function send() {
  await action(async () => {
    if (!message.value.targets.length)
      throw new Error(
        tr("请至少选择一台接收设备。", "Select at least one recipient."),
      );
    const body = {
      schema_version: 1,
      target: { device_ids: [...message.value.targets].sort() },
      title: message.value.title,
      body: message.value.body,
      notification: { level: message.value.level, sound: message.value.sound },
      ...(message.value.url ? { url: message.value.url } : {}),
    };
    const text = JSON.stringify(body);
    if (pendingMessage?.body !== text)
      pendingMessage = { body: text, key: randomID() };
    const response = await api("messages", "POST", body, {
      "Idempotency-Key": pendingMessage!.key,
    });
    pendingMessage = null;
    await refresh();
    const count = response.data.target_count;
    notice.value =
      apns.value.configured === false
        ? tr(
            `消息已保存，目标 ${count} 台设备。当前服务端还不能向官方 App 发送通知。`,
            `Message saved for ${count} devices. This server cannot notify the official app yet.`,
          )
        : tr(
            `消息已保存并排队，目标 ${count} 台设备。`,
            `Message saved and queued for ${count} devices.`,
          );
  });
}
function formState() {
  const out: Row = {};
  for (const f of fields.value) {
    if (!f.key || Object.hasOwn(out, f.key))
      throw new Error(
        tr(
          "字段标识不能为空或重复。",
          "Field keys must be unique and non-empty.",
        ),
      );
    if (
      f.type === "boolean" &&
      !f.missing &&
      !["true", "false"].includes(f.value)
    )
      throw new Error(
        tr(
          "请为布尔字段选择是或否。",
          "Choose yes or no for each boolean field.",
        ),
      );
    out[f.key] = {
      type: f.type,
      ...(f.label ? { label: f.label } : {}),
      ...(f.unit ? { unit: f.unit } : {}),
      value: f.missing
        ? null
        : f.type === "boolean"
          ? f.value === "true"
          : f.value,
    };
  }
  return {
    ...(extrasIdentity.value === identity() ? stateExtras.value : {}),
    fields: out,
  };
}
function toggleEditor() {
  try {
    if (!advanced.value) {
      editor.value = JSON.stringify(formState(), null, 2);
      advanced.value = true;
    } else {
      const body = JSON.parse(editor.value);
      if (body.items || body.series)
        throw new Error(
          tr(
            "此内容包含项目或图表，请继续使用 JSON 编辑。",
            "This payload contains items or charts. Continue editing JSON.",
          ),
        );
      readFields(body);
      advanced.value = false;
    }
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e);
  }
}
function readFields(body: Row) {
  stateExtras.value = { ...body };
  delete stateExtras.value.fields;
  delete stateExtras.value.source_updated_at;
  extrasIdentity.value = identity();
  fields.value = Object.entries(body.fields || {}).map(
    ([key, v]: [string, any]) => ({
      key,
      label: v.label || "",
      type: v.type,
      value: v.value == null ? "" : String(v.value),
      unit: v.unit || "",
      missing: v.value === null,
    }),
  );
}
async function loadState() {
  if (!stateDevice.value || !dataID.value)
    throw new Error(
      tr("请选择设备并填写数据 ID。", "Select a device and enter a data ID."),
    );
  const r = await api(statePath());
  editor.value = JSON.stringify(r.data.state, null, 2);
  readFields(r.data.state);
  advanced.value = !!(r.data.state.items || r.data.state.series);
  etag.value = r.etag;
  loadedIdentity.value = identity();
}
async function chooseState(event: Event) {
  const id = (event.target as HTMLSelectElement).value;
  if (!id) return;
  dataID.value = id;
  await action(loadState);
}
async function saveState() {
  await action(async () => {
    if (!stateDevice.value || !/^[a-z0-9_-]{1,64}$/.test(dataID.value))
      throw new Error(
        tr(
          "请选择设备，数据 ID 使用小写字母、数字、下划线或短横线。",
          "Select a device. Data IDs use lowercase letters, digits, underscores, or hyphens.",
        ),
      );
    const body = advanced.value ? JSON.parse(editor.value) : formState();
    const headers: Record<string, string> =
      loadedIdentity.value === identity() && etag.value
        ? { "If-Match": etag.value }
        : { "If-None-Match": "*" };
    const text = identity() + JSON.stringify(headers) + JSON.stringify(body);
    if (pendingState?.body !== text)
      pendingState = { body: text, key: randomID() };
    const result = await api(statePath(), "PUT", body, {
      ...headers,
      "Idempotency-Key": pendingState!.key,
    });
    pendingState = null;
    await refresh();
    await loadState();
    notice.value =
      result.data.dispatch_status === "no_subscribers"
        ? tr(
            "最新数据已保存。现在可在手机中用这份数据创建卡片。",
            "Latest data saved. You can now create a card from it.",
          )
        : tr(
            "最新数据已保存，手机卡片的别名和排版保持不变。",
            "Latest data saved. Card names and layouts remain unchanged.",
          );
  });
}
async function showAccess(id: string) {
  await action(async () => {
    access.value = null;
    selectedDevice.value = id;
    access.value = (await api("devices/" + id + "/access")).data;
  });
}
async function revokeDevice() {
  await action(async () => {
    await api("devices/" + revokeTarget.value, "DELETE");
    revokeTarget.value = "";
    access.value = null;
    selectedDevice.value = "";
    await refresh();
    notice.value = tr(
      "设备已移除，发送 Key 与读取权限均已撤销。",
      "Device removed. Its send key and read access were revoked.",
    );
  });
}
async function changePassword() {
  await action(async () => {
    await api("auth/password", "PUT", {
      current_password: currentPassword.value,
      password: newPassword.value,
    });
    currentPassword.value = "";
    newPassword.value = "";
    notice.value = tr("管理密码已更新。", "Administrator password updated.");
  });
}
async function copy(value: string) {
  try {
    await copyText(value);
    notice.value = tr("已复制。", "Copied.");
  } catch {
    error.value = tr(
      "无法自动复制，请选择文字手动复制。",
      "Automatic copy failed. Select the text and copy it manually.",
    );
  }
}
const statusNames = computed<Row>(() => ({
  queued: tr("已排队", "Queued"),
  sending: tr("发送中", "Sending"),
  retry: tr("等待重试", "Retrying"),
  accepted: tr("APNs 已接受", "Accepted by APNs"),
  blocked: tr("等待推送条件", "Waiting for push setup"),
  expired: tr("已过期", "Expired"),
  cancelled: tr("已取消", "Cancelled"),
  superseded: tr("已有更新", "Superseded"),
  failed: tr("发送失败", "Failed"),
}));
const reasonNames = computed<Row>(() => ({
  apns_not_configured: tr(
    "服务器尚未配置苹果推送身份",
    "Apple push identity is not configured",
  ),
  token_missing: tr(
    "设备尚未注册推送 token",
    "Device push token is not registered",
  ),
  device_disabled: tr("设备已暂停", "Device is paused"),
  device_revoked: tr("设备已移除", "Device was removed"),
}));
const attention = computed(() => {
  const items: { id: string; page: string; title: string; detail: string }[] =
    [];
  if (sourceErrors.value.length) {
    const names = sourceErrors.value
      .map((s) => s.name)
      .slice(0, 3)
      .join(locale.value === "en" ? ", " : "、");
    items.push({
      id: "source-errors",
      page: "studio",
      title: tr(
        `${sourceErrors.value.length} 个数据源最近采集失败`,
        `${sourceErrors.value.length} data sources failed their last collection`,
      ),
      detail: names,
    });
  }
  const missing = devices.value.filter((d) => d.enabled && !d.has_apns_token);
  if (missing.length) {
    items.push({
      id: "tokens",
      page: "devices",
      title: tr(
        `${missing.length} 台正在接收的设备还没有通知注册`,
        `${missing.length} receiving devices have not registered for alerts`,
      ),
      detail: tr(
        "打开手机上的 Vao Push 后会自动注册。",
        "They register automatically after Vao Push is opened on the phone.",
      ),
    });
  }
  if (!defaultRoute.value.device_ids?.length) {
    items.push({
      id: "route",
      page: "send",
      title: tr("还没有自动接收设备", "No automatic recipients"),
      detail: tr(
        "脚本推送需要先保存接收列表。",
        "Script delivery needs a saved recipient list.",
      ),
    });
  }
  return items;
});
const time = (value: string) =>
  value
    ? new Date(value).toLocaleString(locale.value === "zh" ? "zh-CN" : "en")
    : "—";
function chooseTheme(mode: ThemeMode) {
  setThemeMode(mode);
}
let refreshTimer: ReturnType<typeof setInterval> | undefined;
onMounted(async () => {
  try {
    const r = await api("auth/me");
    user.value = r.data;
    csrf.value = r.data.csrf_token;
    await refresh();
  } catch {
    user.value = null;
  }
  refreshTimer = setInterval(() => {
    if (user.value && !busy.value) refresh().catch(() => {});
  }, 15000);
});
onUnmounted(() => {
  if (refreshTimer) clearInterval(refreshTimer);
});
</script>

<template>
  <div v-if="!user" class="login-wrap">
    <section class="login-card">
      <div class="login-preferences">
        <div
          class="segmented"
          role="group"
          :aria-label="tr('语言', 'Language')"
        >
          <button
            type="button"
            :class="{ selected: locale === 'zh' }"
            @click="setLocale('zh')"
          >
            中文
          </button>
          <button
            type="button"
            :class="{ selected: locale === 'en' }"
            @click="setLocale('en')"
          >
            EN
          </button>
        </div>
        <div
          class="segmented"
          role="group"
          :aria-label="tr('外观', 'Appearance')"
        >
          <button
            type="button"
            :class="{ selected: themeMode === 'light' }"
            @click="chooseTheme('light')"
          >
            {{ tr("浅色", "Light") }}
          </button>
          <button
            type="button"
            :class="{ selected: themeMode === 'dark' }"
            @click="chooseTheme('dark')"
          >
            {{ tr("深色", "Dark") }}
          </button>
          <button
            type="button"
            :class="{ selected: themeMode === 'system' }"
            @click="chooseTheme('system')"
          >
            {{ tr("自动", "Auto") }}
          </button>
        </div>
      </div>
      <img class="logo-lg" src="/brand.svg" alt="Vao Push" />
      <small>VAO PUSH</small>
      <h1>
        {{ tr("让信息，恰好在身边。", "Information, right where you are.") }}
      </h1>
      <p class="muted">
        {{
          tr(
            "登录服务器控制台，手动发送消息或更新桌面数据。手机接入无需登录。",
            "Sign in to send messages or update Home Screen cards. Phone setup does not require this login.",
          )
        }}
      </p>
      <form @submit.prevent="login">
        <label
          >{{ tr("管理员", "Administrator")
          }}<input v-model="username" autocomplete="username" required
        /></label>
        <label
          >{{ tr("管理密码", "Password")
          }}<input
            v-model="password"
            type="password"
            autocomplete="current-password"
            required
        /></label>
        <p v-if="error" class="banner error" role="alert">{{ error }}</p>
        <button class="primary wide" :disabled="busy">
          {{
            busy
              ? tr("正在登录…", "Signing in…")
              : tr("进入控制台", "Enter Console")
          }}
        </button>
      </form>
    </section>
  </div>
  <div v-else class="shell">
    <aside class="sidebar">
      <a class="brand" href="#" @click.prevent="openPage('home')"
        ><img src="/brand.svg" alt="" /><span
          >Vao <strong>Push</strong></span
        ></a
      >
      <nav>
        <button
          v-for="item in menu"
          :key="item.id"
          :class="{ selected: page === item.id }"
          @click="openPage(item.id)"
        >
          <span class="nav-icon" aria-hidden="true">
            <svg v-if="item.icon === 'home'" viewBox="0 0 24 24">
              <path d="M4 11.2 12 4.5l8 6.7" />
              <path d="M7 10.8V19h10v-8.2" />
            </svg>
            <svg v-else-if="item.icon === 'send'" viewBox="0 0 24 24">
              <path d="M4.5 12.2 19.5 5.2 14 19.2l-2.4-6.4z" />
            </svg>
            <svg v-else-if="item.icon === 'studio'" viewBox="0 0 24 24">
              <rect x="4" y="5" width="16" height="14" rx="2" />
              <path d="M4 9.5h16M9.5 9.5V19" />
            </svg>
            <svg v-else-if="item.icon === 'streams'" viewBox="0 0 24 24">
              <path d="M5 19V11M12 19V6M19 19v-7" />
            </svg>
            <svg v-else-if="item.icon === 'devices'" viewBox="0 0 24 24">
              <rect x="8" y="3.5" width="8" height="17" rx="2" />
              <path d="M11 17.5h2" />
            </svg>
            <svg v-else-if="item.icon === 'history'" viewBox="0 0 24 24">
              <circle cx="12" cy="12" r="7.5" />
              <path d="M12 8.2V12l2.8 2" />
            </svg>
            <svg v-else viewBox="0 0 24 24">
              <path d="M4 7h16M4 12h16M4 17h16" />
              <circle class="knob" cx="8" cy="7" r="1.7" />
              <circle class="knob" cx="15" cy="12" r="1.7" />
              <circle class="knob" cx="10" cy="17" r="1.7" />
            </svg>
          </span>
          {{ item.name }}
        </button>
      </nav>
      <div class="sidebar-bottom">
        <span>{{ data.server_name }}</span
        ><button class="text-button" @click="logout">
          {{ tr("退出", "Sign Out") }}
        </button>
      </div>
    </aside>
    <main class="workspace">
      <header class="topbar">
        <div>
          <small>VAO PUSH</small>
          <h1>{{ menu.find((item) => item.id === page)?.name }}</h1>
        </div>
        <div class="toolbar">
          <div
            class="segmented"
            role="group"
            :aria-label="tr('语言', 'Language')"
          >
            <button
              type="button"
              :class="{ selected: locale === 'zh' }"
              @click="setLocale('zh')"
            >
              中文</button
            ><button
              type="button"
              :class="{ selected: locale === 'en' }"
              @click="setLocale('en')"
            >
              EN
            </button>
          </div>
          <div
            class="segmented"
            role="group"
            :aria-label="tr('外观', 'Appearance')"
          >
            <button
              type="button"
              :class="{ selected: themeMode === 'light' }"
              @click="chooseTheme('light')"
            >
              {{ tr("浅色", "Light") }}</button
            ><button
              type="button"
              :class="{ selected: themeMode === 'dark' }"
              @click="chooseTheme('dark')"
            >
              {{ tr("深色", "Dark") }}</button
            ><button
              type="button"
              :class="{ selected: themeMode === 'system' }"
              @click="chooseTheme('system')"
            >
              {{ tr("自动", "Auto") }}
            </button>
          </div>
          <button class="secondary" @click="action(refresh)" :disabled="busy">
            {{ tr("刷新", "Refresh") }}
          </button>
        </div>
      </header>
      <p v-if="error" class="banner error" role="alert">{{ error }}</p>
      <p v-if="notice" class="banner success" role="status">{{ notice }}</p>
      <p v-if="!devices.length" class="banner">
        {{
          tr(
            "先在 iPhone 的 Vao Push 中添加服务器地址：",
            "Add this server address in Vao Push on iPhone:",
          )
        }}
        <span class="mono">{{ data.server_url }}</span>
      </p>
      <template v-if="page === 'home'">
        <section
          class="stat-grid"
          :aria-label="tr('当前状况', 'Current status')"
        >
          <button type="button" class="stat-card" @click="openPage('studio')">
            <span>{{ tr("卡片", "Cards") }}</span>
            <strong>{{ cards.length }}</strong>
            <small>{{
              tr(
                `已发布 ${publishedCards.length} · 草稿 ${cards.length - publishedCards.length}`,
                `${publishedCards.length} published · ${cards.length - publishedCards.length} drafts`,
              )
            }}</small>
          </button>
          <button type="button" class="stat-card" @click="openPage('studio')">
            <span>{{ tr("正在采集", "Collecting") }}</span>
            <strong>{{ collectingSources.length }}</strong>
            <small>{{
              tr(
                `出错 ${sourceErrors.length} · 主动上报 ${pushSources.length}`,
                `${sourceErrors.length} with errors · ${pushSources.length} push sources`,
              )
            }}</small>
          </button>
          <button type="button" class="stat-card" @click="openPage('devices')">
            <span>{{ tr("已连接设备", "Connected Devices") }}</span>
            <strong>{{ devices.length }}</strong>
            <small>{{
              tr(
                `接收中 ${active.length} · 通知已注册 ${notifiedDevices.length}`,
                `${active.length} receiving · ${notifiedDevices.length} alerts registered`,
              )
            }}</small>
          </button>
          <button type="button" class="stat-card" @click="openPage('send')">
            <span>{{ tr("自动接收", "Automatic Recipients") }}</span>
            <strong>{{ defaultRoute.device_ids?.length || 0 }}</strong>
            <small>{{
              tr(
                `最近消息 ${data.messages.length} 条`,
                `${data.messages.length} recent messages`,
              )
            }}</small>
          </button>
        </section>
        <div class="two-column">
          <section class="panel">
            <h2>{{ tr("需要留意", "Needs Attention") }}</h2>
            <div v-if="attention.length" class="attention-list">
              <button
                v-for="item in attention"
                :key="item.id"
                type="button"
                @click="openPage(item.page)"
              >
                <strong>{{ item.title }}</strong>
                <small>{{ item.detail }}</small>
              </button>
            </div>
            <p v-else class="muted">
              {{
                tr(
                  "目前没有需要处理的情况。",
                  "Nothing needs attention right now.",
                )
              }}
            </p>
          </section>
          <section class="panel">
            <div class="section-title">
              <h2>{{ tr("最近发送", "Recent Deliveries") }}</h2>
              <button
                class="text-button"
                type="button"
                @click="openPage('history')"
              >
                {{ tr("查看全部", "View all") }}
              </button>
            </div>
            <p v-if="!data.deliveries.length" class="muted">
              {{ tr("还没有发送记录。", "No deliveries yet.") }}
            </p>
            <article
              v-for="d in data.deliveries.slice(0, 5)"
              :key="d.id"
              class="overview-row"
            >
              <div>
                <strong>{{ d.device_name }}</strong>
                <p>
                  {{
                    d.kind === "message"
                      ? tr("消息", "Message")
                      : tr("卡片数据", "Card Data")
                  }}
                  · {{ time(d.created_at) }}
                </p>
              </div>
              <span class="badge" :class="d.status">{{
                statusNames[d.status] || d.status
              }}</span>
            </article>
          </section>
        </div>
      </template>
      <KeepAlive
        ><CardStudio v-if="page === 'studio'" :csrf="csrf"
      /></KeepAlive>

      <template v-if="page === 'send'">
        <div class="two-column">
          <section class="panel">
            <h2>{{ tr("发一条消息", "Send a Message") }}</h2>
            <form @submit.prevent="send">
              <fieldset class="recipient-picker" :disabled="busy">
                <legend>
                  {{
                    tr("接收设备 · 可多选", "Recipients · Multiple Selection")
                  }}
                </legend>
                <div class="recipient-actions">
                  <span>{{
                    tr(
                      `已选 ${message.targets.length} 台`,
                      `${message.targets.length} selected`,
                    )
                  }}</span
                  ><button
                    type="button"
                    class="secondary"
                    @click="selectAllRecipients"
                    :disabled="!active.length"
                  >
                    {{ tr("全选", "All") }}</button
                  ><button
                    type="button"
                    class="secondary"
                    @click="message.targets = []"
                    :disabled="!message.targets.length"
                  >
                    {{ tr("清空", "Clear") }}
                  </button>
                </div>
                <p v-if="!recipientRows.length" class="muted">
                  {{
                    tr(
                      "请先在手机中添加本服务器。",
                      "Add this server on a phone first.",
                    )
                  }}
                </p>
                <div v-else class="recipient-list">
                  <label
                    v-for="d in recipientRows"
                    :key="d.id"
                    class="check recipient-option"
                    :class="{ selected: message.targets.includes(d.id) }"
                    ><input
                      type="checkbox"
                      v-model="message.targets"
                      :value="d.id"
                      :disabled="
                        d.unavailable && !message.targets.includes(d.id)
                      "
                      :aria-label="d.name + ' · ' + d.id.slice(-8)"
                    /><span
                      >{{ d.name
                      }}<small
                        >{{ tr("设备标识", "Device ID")
                        }}{{ locale === "en" ? ": " : "："
                        }}{{ d.id.slice(-8) }}</small
                      ><small v-if="d.unavailable">{{
                        d.revoked || !d.platform
                          ? tr("已移除，请取消选择", "Removed; deselect it")
                          : tr("已暂停接收", "Receiving paused")
                      }}</small></span
                    ></label
                  >
                </div>
                <p class="muted">
                  {{
                    tr(
                      "手动消息只发送给本次选中的设备。",
                      "A manual message goes only to the devices selected now.",
                    )
                  }}
                </p>
                <div class="recipient-actions">
                  <button
                    type="button"
                    class="secondary"
                    @click="saveRecipients"
                  >
                    {{
                      tr("保存为自动接收设备", "Save Automatic Recipients")
                    }}</button
                  ><button
                    v-if="defaultRoute.configured"
                    type="button"
                    class="secondary"
                    @click="useSavedRecipients"
                  >
                    {{ tr("使用已保存列表", "Use Saved List") }}
                  </button>
                </div>
                <p class="muted">
                  {{
                    defaultRoute.configured
                      ? tr(
                          `自动推送已保存 ${defaultRoute.device_ids.length} 台设备`,
                          `${defaultRoute.device_ids.length} automatic recipients saved`,
                        )
                      : tr(
                          "尚未设置自动接收设备",
                          "No automatic recipients saved",
                        )
                  }}{{
                    routeChanged
                      ? tr(
                          " · 当前勾选尚未保存",
                          " · Current selection is unsaved",
                        )
                      : ""
                  }}
                </p>
                <button
                  v-if="defaultRoute.message_url"
                  type="button"
                  class="secondary"
                  @click="copy(defaultRoute.message_url)"
                >
                  {{ tr("复制自动推送地址", "Copy Automatic Push URL") }}
                </button>
              </fieldset>
              <label
                >{{ tr("标题", "Title")
                }}<input
                  v-model="message.title"
                  maxlength="100"
                  :placeholder="tr('例如：任务完成', 'Example: Task complete')"
              /></label>
              <label
                >{{ tr("内容", "Message")
                }}<textarea
                  v-model="message.body"
                  rows="6"
                  required
                  maxlength="1200"
                  :placeholder="
                    tr('想发送到手机的内容', 'Content to send to the phone')
                  "
                ></textarea>
              </label>
              <details>
                <summary>{{ tr("通知选项", "Notification Options") }}</summary>
                <label
                  >{{ tr("提醒方式", "Alert Style")
                  }}<select v-model="message.level">
                    <option value="active">
                      {{ tr("正常提醒", "Normal Alert") }}
                    </option>
                    <option value="passive">
                      {{ tr("安静显示", "Quiet") }}
                    </option>
                  </select></label
                ><label
                  >{{ tr("声音", "Sound")
                  }}<select v-model="message.sound">
                    <option value="default">
                      {{ tr("默认提示音", "Default") }}
                    </option>
                    <option value="none">{{ tr("无声音", "Silent") }}</option>
                  </select></label
                ><label
                  >{{ tr("点击链接", "Tap Link")
                  }}<input
                    v-model="message.url"
                    type="url"
                    placeholder="https://example.com"
                /></label>
              </details>
              <button
                class="primary"
                :disabled="busy || !message.targets.length"
              >
                {{
                  busy
                    ? tr("正在提交…", "Submitting…")
                    : tr(
                        `发送到已选 ${message.targets.length} 台设备`,
                        `Send to ${message.targets.length} Selected`,
                      )
                }}
              </button>
            </form>
          </section>
          <div>
            <section class="preview">
              <small>{{ tr("内容预览", "Preview") }}</small>
              <div class="notification">
                <img src="/brand.svg" alt="" />
                <div>
                  <small
                    >VAO PUSH <span>{{ tr("现在", "Now") }}</span></small
                  ><strong>{{ message.title || tr("消息", "Message") }}</strong>
                  <p>
                    {{
                      message.body ||
                      tr(
                        "你填写的消息会显示在这里。",
                        "Your message appears here.",
                      )
                    }}
                  </p>
                </div>
              </div>
              <p>
                {{
                  tr(
                    "最终通知样式由 iOS 决定。",
                    "iOS determines the final notification appearance.",
                  )
                }}
              </p>
            </section>
            <section class="panel compact">
              <h3>{{ tr("接入很简单", "Simple Setup") }}</h3>
              <p>
                {{
                  tr(
                    "手机添加服务器后，即可在这里发送。",
                    "After a phone adds the server, you can send from here.",
                  )
                }}
              </p>
              <p class="muted">
                {{
                  tr(
                    "脚本可使用“接入设备”中的发送地址。",
                    "Scripts can use the send URL shown under Devices.",
                  )
                }}
              </p>
            </section>
          </div>
        </div>
      </template>

      <template v-if="page === 'streams'">
        <section class="panel">
          <h2>{{ tr("保存最新内容", "Save Latest Content") }}</h2>
          <p class="muted">
            {{
              tr(
                "填写固定数据 ID。首次发送自动创建，之后覆盖最新内容。",
                "Enter a stable data ID. The first update creates it; later updates replace the latest content.",
              )
            }}
          </p>
          <div class="form-grid">
            <label
              >{{ tr("接收设备", "Device")
              }}<select v-model="stateDevice">
                <option v-for="d in active" :key="d.id" :value="d.id">
                  {{ d.name }} · {{ d.id.slice(-8) }}
                </option>
              </select></label
            ><label
              >{{ tr("已有数据", "Existing Data")
              }}<select value="" @change="chooseState">
                <option value="">
                  {{
                    tr(
                      "选择读取，或填写新的数据 ID",
                      "Load existing data or enter a new ID",
                    )
                  }}
                </option>
                <option
                  v-for="s in availableStates"
                  :key="s.id"
                  :value="s.data_id"
                >
                  {{ s.data_id }}
                </option>
              </select></label
            >
          </div>
          <label
            >{{ tr("数据 ID", "Data ID")
            }}<input
              v-model="dataID"
              maxlength="64"
              placeholder="task_progress" /></label
          ><button
            class="text-button"
            @click="action(loadState)"
            :disabled="busy"
          >
            {{ tr("读取已有内容", "Load Existing Content") }}
          </button>
          <div class="section-title">
            <h3>
              {{
                advanced
                  ? tr("内容 JSON", "Content JSON")
                  : tr("显示字段", "Display Fields")
              }}
            </h3>
            <button class="text-button" @click="toggleEditor">
              {{
                advanced
                  ? tr("使用字段表单", "Use Field Form")
                  : tr("使用 JSON 编辑", "Edit JSON")
              }}
            </button>
          </div>
          <template v-if="!advanced"
            ><article
              v-for="(f, index) in fields"
              :key="index"
              class="field-editor"
            >
              <div class="form-grid">
                <label
                  >{{ tr("字段标识", "Field Key")
                  }}<input v-model="f.key" maxlength="64" /></label
                ><label
                  >{{ tr("默认名称", "Default Label")
                  }}<input v-model="f.label"
                /></label>
              </div>
              <div class="form-grid">
                <label
                  >{{ tr("类型", "Type")
                  }}<select v-model="f.type">
                    <option value="text">{{ tr("文字", "Text") }}</option>
                    <option value="decimal">{{ tr("数值", "Decimal") }}</option>
                    <option value="integer">{{ tr("整数", "Integer") }}</option>
                    <option value="percent">
                      {{ tr("百分比", "Percent") }}
                    </option>
                    <option value="boolean">
                      {{ tr("是 / 否", "Yes / No") }}
                    </option>
                    <option value="datetime">
                      {{ tr("日期时间", "Date & Time") }}
                    </option>
                  </select></label
                ><label
                  >{{ tr("值", "Value")
                  }}<select
                    v-if="f.type === 'boolean'"
                    v-model="f.value"
                    :disabled="f.missing"
                  >
                    <option value="true">{{ tr("是", "Yes") }}</option>
                    <option value="false">{{ tr("否", "No") }}</option></select
                  ><input
                    v-else
                    v-model="f.value"
                    :disabled="f.missing" /></label
                ><label
                  >{{ tr("单位", "Unit")
                  }}<input
                    v-model="f.unit"
                    :placeholder="tr('可选', 'Optional')"
                /></label>
              </div>
              <label class="check"
                ><input type="checkbox" v-model="f.missing" />{{
                  tr("暂时无数据", "Temporarily unavailable")
                }}</label
              ><button class="danger-link" @click="fields.splice(index, 1)">
                {{ tr("移除此字段", "Remove Field") }}
              </button>
            </article>
            <button
              class="secondary"
              @click="
                fields.push({
                  key: '',
                  label: '',
                  type: 'text',
                  value: '',
                  unit: '',
                  missing: false,
                })
              "
              :disabled="fields.length >= 32"
            >
              {{ tr("添加字段", "Add Field") }}
            </button></template
          >
          <textarea
            v-else
            v-model="editor"
            class="code-editor"
            spellcheck="false"
            rows="20"
            :aria-label="tr('状态 JSON', 'State JSON')"
          ></textarea>
          <div class="button-row">
            <button
              class="primary"
              @click="saveState"
              :disabled="busy || !stateDevice"
            >
              {{ tr("保存并更新卡片数据", "Save and Update Card Data") }}
            </button>
          </div>
        </section>
      </template>

      <template v-if="page === 'devices'">
        <section class="panel">
          <h2>{{ tr("自动接入的设备", "Automatically Connected Devices") }}</h2>
          <p class="muted">
            {{
              tr(
                "在手机中添加本服务器即可，无需配对码。",
                "Add this server on the phone. No pairing code is required.",
              )
            }}
          </p>
          <article v-for="d in devices" :key="d.id" class="device-row">
            <div class="device-icon">▣</div>
            <div>
              <strong>{{ d.name }}</strong>
              <p class="mono">{{ d.id }}</p>
              <p>
                {{
                  d.enabled
                    ? tr("接收已启用", "Receiving enabled")
                    : tr("接收已暂停", "Receiving paused")
                }}
              </p>
              <small
                >{{ tr("通知", "Alerts") }}
                {{
                  d.has_apns_token
                    ? tr("已注册", "registered")
                    : tr("待注册", "pending")
                }}
                · {{ tr("小组件", "Widget") }}
                {{
                  d.has_widget_token
                    ? tr("已注册", "registered")
                    : tr("待注册", "pending")
                }}</small
              >
            </div>
            <button
              class="secondary"
              @click="showAccess(d.id)"
              :disabled="busy"
            >
              {{ tr("发送地址", "Send URL") }}</button
            ><button class="danger-link" @click="revokeTarget = d.id">
              {{ tr("移除", "Remove") }}
            </button>
          </article>
          <div v-if="access" class="pair-box">
            <strong>{{
              devices.find((d) => d.id === selectedDevice)?.name
            }}</strong
            ><label
              >{{ tr("消息接口（POST）", "Message Endpoint (POST)")
              }}<code class="code-block">{{ access.message_url }}</code></label
            ><button class="secondary" @click="copy(access.message_url)">
              {{ tr("复制消息地址", "Copy Message URL") }}</button
            ><label
              >{{ tr("卡片数据接口（PUT）", "Card Data Endpoint (PUT)")
              }}<code class="code-block">{{ access.state_url }}</code></label
            ><button class="secondary" @click="copy(access.state_url)">
              {{ tr("复制数据地址", "Copy Data URL") }}</button
            ><button class="text-button" @click="access = null">
              {{ tr("收起地址", "Hide URLs") }}
            </button>
          </div>
          <div v-if="revokeTarget" class="confirm-box">
            <p>
              {{
                tr(
                  "移除后，该设备的发送地址、读取和推送权限将失效。",
                  "Removing the device invalidates its send URL, read access, and push permissions.",
                )
              }}
            </p>
            <button class="danger" @click="revokeDevice" :disabled="busy">
              {{ tr("确认移除", "Confirm Removal") }}</button
            ><button class="secondary" @click="revokeTarget = ''">
              {{ tr("取消", "Cancel") }}
            </button>
          </div>
        </section>
      </template>

      <template v-if="page === 'history'">
        <section class="panel">
          <h2>{{ tr("最近处理状态", "Recent Delivery Status") }}</h2>
          <p class="muted">
            {{
              tr(
                "“APNs 已接受”表示苹果接受请求，不代表手机已经显示。",
                "“Accepted by APNs” means Apple accepted the request, not that the phone displayed it.",
              )
            }}
          </p>
          <p v-if="!data.deliveries.length" class="empty">
            {{ tr("暂无发送记录。", "No deliveries yet.") }}
          </p>
          <div v-else class="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>{{ tr("时间", "Time") }}</th>
                  <th>{{ tr("设备", "Device") }}</th>
                  <th>{{ tr("类型", "Type") }}</th>
                  <th>{{ tr("状态", "Status") }}</th>
                  <th>{{ tr("说明", "Details") }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="d in data.deliveries" :key="d.id">
                  <td>{{ time(d.created_at) }}</td>
                  <td>{{ d.device_name }}</td>
                  <td>
                    {{
                      d.kind === "message"
                        ? tr("消息", "Message")
                        : tr("卡片数据", "Card Data")
                    }}
                  </td>
                  <td>
                    <span class="badge" :class="d.status">{{
                      statusNames[d.status] || d.status
                    }}</span>
                  </td>
                  <td>{{ reasonNames[d.error] || d.error || "—" }}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
        <section class="panel">
          <h2>{{ tr("消息历史", "Message History") }}</h2>
          <article
            v-for="m in data.messages"
            :key="m.message_id"
            class="message-row"
          >
            <div>
              <strong>{{ m.title || tr("消息", "Message") }}</strong>
              <p>{{ m.body }}</p>
            </div>
            <time>{{ time(m.received_at) }}</time>
          </article>
        </section>
      </template>

      <template v-if="page === 'settings'">
        <div class="two-column">
          <section class="panel">
            <h2>{{ tr("管理密码", "Administrator Password") }}</h2>
            <form @submit.prevent="changePassword">
              <label
                >{{ tr("当前密码", "Current Password")
                }}<input
                  type="password"
                  v-model="currentPassword"
                  autocomplete="current-password"
                  required /></label
              ><label
                >{{ tr("新密码", "New Password")
                }}<input
                  type="password"
                  v-model="newPassword"
                  autocomplete="new-password"
                  minlength="12"
                  maxlength="72"
                  required /></label
              ><button class="secondary" :disabled="busy">
                {{ tr("更新密码", "Update Password") }}
              </button>
            </form>
          </section>
        </div>
      </template>
    </main>
  </div>
</template>
