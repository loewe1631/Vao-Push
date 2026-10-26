<script setup lang="ts">
import { copyText } from "./clipboard";
import { ref, computed, watch } from "vue";
import { curlExample, dataExample } from "./studioWorkflow";
import { locale, tr, localizeErrorMessage } from "./i18n";
const props = defineProps<{
  card: Record<string, any>;
  source?: Record<string, any>;
  related: Record<string, any>[];
  csrf: string;
}>();
const busy = ref(false),
  error = ref(""),
  notice = ref(""),
  address = ref(""),
  code = ref<any>(null),
  devices = ref<any[]>([]),
  loaded = ref(false),
  confirmAction = ref("");
const example = computed(() =>
  JSON.stringify(dataExample(props.source?.state, locale.value), null, 2),
);
const command = computed(() =>
  curlExample(
    address.value ||
      (locale.value === "en"
        ? "https://push.example.com/v1/card-data/YOUR_SOURCE_TOKEN"
        : "https://push.example.com/v1/card-data/你的数据源凭据"),
    props.source?.state,
    locale.value,
  ),
);
watch(
  () => props.card.id,
  () => {
    address.value = "";
    code.value = null;
    devices.value = [];
    loaded.value = false;
    error.value = "";
    notice.value = "";
    confirmAction.value = "";
  },
);
async function api(path: string, method = "GET") {
  const r = await fetch("/v1/" + path, {
    method,
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      ...(method === "GET"
        ? {}
        : { "X-CSRF-Token": props.csrf, "Content-Type": "application/json" }),
    },
    ...(method === "POST" ? { body: "{}" } : {}),
  });
  const v = await r.json();
  if (!r.ok)
    throw Error(
      localizeErrorMessage(
        v.error?.message ||
          tr("操作未完成", "Operation could not be completed"),
      ),
    );
  return v.data;
}
async function act(fn: () => Promise<void>) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    await fn();
  } catch (e) {
    error.value =
      e instanceof Error
        ? localizeErrorMessage(e.message)
        : tr("操作未完成", "Operation could not be completed");
  } finally {
    busy.value = false;
  }
}
async function copy(value: string) {
  await copyText(value);
  notice.value = tr("已复制", "Copied");
}
async function loadAddress() {
  await act(async () => {
    address.value = (
      await api("card-sources/" + props.card.source_id + "/access")
    ).data_url;
  });
}
async function subscribers() {
  devices.value = (
    await api("cards/" + props.card.id + "/subscribers")
  ).devices;
  loaded.value = true;
}
</script>
<template>
  <div class="access-content">
    <p v-if="error" class="banner error" role="alert">{{ error }}</p>
    <p v-if="notice" class="banner success" role="status">{{ notice }}</p>
    <section class="panel">
      <h2>{{ tr("1. 把内容发到这张卡片", "1. Send Data to This Card") }}</h2>
      <p>
        {{ tr("这张卡片读取数据源 ", "This card reads from data source ")
        }}<strong>{{
          source?.name || tr("未找到数据源", "Data source not found")
        }}</strong
        >{{
          tr(
            "。脚本每次更新这份数据，所有绑定它的卡片都会读取最新内容。",
            ". Every update to this source refreshes all cards bound to it.",
          )
        }}
      </p>
      <p class="muted">
        {{ tr("接入方式：", "Ingest mode: ")
        }}{{
          source?.mode === "http"
            ? tr(
                "服务器自动读取 API，也可手动或脚本上报",
                "Server polls HTTPS API automatically (manual or script push also supported)",
              )
            : tr(
                "脚本、Bot 或其他工具上报，也可在网页手动填写",
                "Pushed by your script, bot, or tool (or edited manually in the web console)",
              )
        }}
      </p>
      <p class="muted">
        {{ tr("同一数据源的卡片：", "Cards sharing this data source: ")
        }}{{
          related
            .map((c) => c.draft.name)
            .join(locale === "en" ? ", " : "、") || card.draft.name
        }}{{
          tr(
            "。需要单独更新另一张卡片时，为它选择独立数据源。",
            ". Create a separate data source if another card needs independent updates.",
          )
        }}
      </p>
      <div class="studio-tabs">
        <button class="secondary" @click="loadAddress" :disabled="busy">
          {{ tr("显示脚本上报地址", "Reveal Script Push URL") }}
        </button>
      </div>
      <template v-if="address">
        <label class="address-label"
          >{{ tr("PUT · 数据源专属地址", "PUT · Dedicated Data Source URL")
          }}<input
            :value="address"
            readonly
            class="mono"
            @focus="($event.target as HTMLInputElement).select()"
        /></label>
        <div class="studio-tabs">
          <button class="secondary" @click="act(() => copy(address))">
            {{ tr("复制上报地址", "Copy Push URL") }}</button
          ><button class="secondary" @click="act(() => copy(command))">
            {{ tr("复制完整 curl 示例", "Copy Full curl Example") }}
          </button>
        </div>
        <p class="muted">
          {{
            tr(
              "地址含写入凭据，请只交给需要更新这份数据的工具。每次写入替换整份数据；不会改动排版或手机微调。",
              "This URL contains write credentials—share it only with tools that update this source. Each PUT replaces the latest snapshot without overwriting card layout or device tweaks.",
            )
          }}
        </p>
      </template>
      <details>
        <summary>
          {{
            tr("查看请求示例与字段说明", "View Request Example & Field Guide")
          }}
        </summary>
        <p>
          {{
            tr(
              "请求使用 PUT，Content-Type 为 application/json。字段标识须与设计中的绑定相同，数值使用字符串。",
              "Send an HTTP PUT request with Content-Type: application/json. Field keys must match the card bindings, and numeric values should be passed as strings.",
            )
          }}
        </p>
        <pre>{{ command }}</pre>
        <pre>{{ example }}</pre>
        <p class="muted">
          {{
            tr(
              "HTTP 200/202 表示数据已保存；桌面实际刷新由 iOS 调度。",
              "HTTP 200/202 confirms the snapshot is saved; actual Home Screen widget reload timing is scheduled by iOS.",
            )
          }}
        </p>
      </details>
    </section>
    <section class="panel">
      <h2>
        {{ tr("2. 让手机订阅这张卡片", "2. Subscribe on iPhone or iPad") }}
      </h2>
      <p>
        {{
          tr(
            "发布设计后生成订阅码。在客户端“卡片 → ＋ → 通过订阅码导入”中，选择当前服务器并粘贴。导入一次后持续跟随数据和已发布设计更新。",
            "Publish your card design to generate a subscription code. In the iOS app under Cards → + → Import with Subscription Code, select this server and paste the code. Once imported, the card follows future data and published design updates.",
          )
        }}
      </p>
      <p v-if="card.revision === '0'" class="banner">
        {{
          tr(
            "这张卡片还没有发布。先在设计页接入有效数据，再点击“发布到设备”。",
            "This card has not been published yet. Connect valid data in the designer and click “Publish to Devices” first.",
          )
        }}
      </p>
      <div class="studio-tabs">
        <button
          class="primary"
          :disabled="busy || card.revision === '0'"
          @click="
            act(async () => {
              code = await api('cards/' + card.id + '/codes', 'POST');
            })
          "
        >
          {{ tr("生成订阅码", "Generate Subscription Code") }}
        </button>
      </div>
      <div v-if="code" class="subscription-code">
        <code>{{ code.code }}</code>
        <p class="muted">
          {{
            tr(
              "1小时内有效，最多10台已绑定设备。后续更新数据使用上面的上报地址，无需反复生成订阅码。",
              "Valid for 1 hour for up to 10 paired devices. Use the push URL above for ongoing data updates—no need to regenerate codes.",
            )
          }}
        </p>
        <div class="studio-tabs">
          <button class="secondary" @click="act(() => copy(code.code))">
            {{ tr("复制订阅码", "Copy Code") }}</button
          ><button class="secondary" @click="act(() => copy(code.link))">
            {{ tr("复制导入链接", "Copy Import Link") }}
          </button>
        </div>
      </div>
    </section>
    <section class="panel" v-if="card.revision !== '0'">
      <h2>{{ tr("3. 管理订阅设备", "3. Manage Subscribed Devices") }}</h2>
      <div class="studio-tabs">
        <button class="secondary" @click="act(subscribers)" :disabled="busy">
          {{ tr("查看订阅设备", "Load Subscribed Devices") }}</button
        ><button
          class="secondary"
          @click="confirmAction = 'codes'"
          :disabled="busy"
        >
          {{ tr("停用已有订阅码", "Revoke Active Codes") }}
        </button>
      </div>
      <p v-if="loaded && !devices.length" class="muted">
        {{
          tr(
            "还没有设备订阅这张卡片。",
            "No devices are subscribed to this card yet.",
          )
        }}
      </p>
      <div v-for="d in devices" :key="d.id" class="source-row">
        <span>{{ d.name }} · {{ d.id.slice(-8) }}</span
        ><button
          class="danger-link"
          @click="confirmAction = d.id"
          :disabled="busy"
        >
          {{ tr("取消此设备订阅", "Unsubscribe Device") }}
        </button>
      </div>
      <div v-if="confirmAction" class="banner">
        <p>
          {{
            confirmAction === "codes"
              ? tr(
                  "停用后，已有订阅继续更新；旧码不能再导入。需要时可重新生成新码。",
                  "Existing subscribed devices keep receiving updates, but previous codes can no longer be imported. You can generate a new code anytime.",
                )
              : tr(
                  "取消后，该设备不再读取此卡片。持有其他有效订阅码仍可重新导入。",
                  "This device will lose read access to this card. It can re-import if given a new valid subscription code.",
                )
          }}
        </p>
        <div class="studio-tabs">
          <button class="secondary" @click="confirmAction = ''">
            {{ tr("返回", "Back") }}</button
          ><button
            class="primary"
            :disabled="busy"
            @click="
              act(async () => {
                await api(
                  confirmAction === 'codes'
                    ? 'cards/' + card.id + '/codes'
                    : 'cards/' + card.id + '/subscribers/' + confirmAction,
                  'DELETE',
                );
                if (confirmAction === 'codes') code = null;
                else await subscribers();
                confirmAction = '';
                notice = tr(
                  '已更新订阅权限',
                  'Subscription permissions updated',
                );
              })
            "
          >
            {{ tr("确认", "Confirm") }}
          </button>
        </div>
      </div>
    </section>
  </div>
</template>
<style scoped>
.access-content {
  display: grid;
  gap: 18px;
}
.studio-tabs {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin: 14px 0 6px;
}
.source-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  padding: 12px 14px;
  margin-top: 8px;
  background: var(--surface-subtle);
  border: 1px solid var(--border);
  border-radius: 10px;
}
.address-label {
  margin-top: 14px;
}
pre {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  font-size: 12px;
  background: var(--code-bg);
  border: 1px solid var(--border);
  padding: 16px;
  border-radius: 10px;
}
summary {
  cursor: pointer;
  margin: 16px 0 8px;
}
.subscription-code {
  margin-top: 16px;
  padding: 16px 18px;
  background: var(--surface-subtle);
  border: 1px solid var(--border);
  border-radius: 12px;
}
code {
  display: block;
  font-size: 22px;
  font-weight: 600;
  letter-spacing: 1px;
  color: var(--accent);
  overflow-wrap: anywhere;
  margin: 4px 0 10px;
}
</style>
