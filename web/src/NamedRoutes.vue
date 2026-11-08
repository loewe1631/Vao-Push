<script setup lang="ts">
import { ref, onMounted } from "vue";
import { tr } from "./i18n";
import { copyText } from "./clipboard";
const props = defineProps<{
  csrf: string;
  devices: Record<string, any>[];
  selectionOnly?: boolean;
}>();
const emit = defineEmits<{ select: [devices: string[]] }>();
const routes = ref<Record<string, any>[]>([]),
  draft = ref({ id: "", name: "", device_ids: [] as string[], revision: "0" }),
  busy = ref(false),
  error = ref(""),
  notice = ref("");
async function api(
  path: string,
  method = "GET",
  body?: unknown,
  revision?: string,
) {
  const r = await fetch("/v1/" + path, {
    method,
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      "X-CSRF-Token": props.csrf,
      ...(revision ? { "If-Match": `"route-${revision}"` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const v = await r.json();
  if (!r.ok) throw Error(v.error?.message || "Request failed");
  return v.data;
}
async function load() {
  routes.value = (await api("message-routes")).routes;
}
async function run(work: () => Promise<void>) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    await work();
  } catch (e) {
    error.value = String(e);
  } finally {
    busy.value = false;
  }
}
function edit(r: any) {
  draft.value = {
    id: r.id,
    name: r.name,
    device_ids: [...r.device_ids],
    revision: r.revision,
  };
}
async function save() {
  await run(async () => {
    const d = draft.value;
    await api(
      "message-routes" + (d.id ? "/" + d.id : ""),
      d.id ? "PUT" : "POST",
      { name: d.name, device_ids: d.device_ids },
      d.id ? d.revision : undefined,
    );
    draft.value = { id: "", name: "", device_ids: [], revision: "0" };
    await load();
    notice.value = tr(
      "列表已保存，其他列表及原默认地址保留。",
      "List saved. Other lists and the original default URL are kept.",
    );
  });
}
async function remove(r: any) {
  if (
    !window.confirm(
      tr(
        `删除「${r.name}」？${r.device_ids.length}台设备不解绑，此列表地址将失效。`,
        `Delete “${r.name}”? Its URL will stop working. Devices remain connected.`,
      ),
    )
  )
    return;
  await run(async () => {
    await api("message-routes/" + r.id, "DELETE", undefined, r.revision);
    await load();
  });
}
onMounted(() => run(load));
</script>
<template>
  <section class="panel">
    <h2>{{ tr("推送列表", "Push Lists") }}</h2>
    <p class="muted">
      {{
        tr(
          "每个列表有独立推送地址。原默认列表继续在发送消息页管理。",
          "Each list has its own URL. Manage the original default list on the Messages page.",
        )
      }}
    </p>
    <p v-if="error" class="banner error">{{ error }}</p>
    <p v-if="notice" class="banner">{{ notice }}</p>
    <label v-if="selectionOnly"
      >{{
        tr(
          "选择已保存列表（临时载入接收设备）",
          "Load recipients from a saved list",
        )
      }}<select
        @change="
          emit(
            'select',
            routes.find(
              (r) => r.id === ($event.target as HTMLSelectElement).value,
            )?.device_ids || [],
          )
        "
      >
        <option value="">{{ tr("选择列表", "Choose a list") }}</option>
        <option v-for="r in routes" :key="r.id" :value="r.id">
          {{ r.name }} · {{ r.device_ids.length }}
        </option>
      </select></label
    ><template v-if="!selectionOnly"
      ><article v-for="r in routes" :key="r.id" class="panel">
        <strong>{{ r.name }}</strong> · {{ r.device_ids.length }}
        {{ tr("台设备", "devices")
        }}<input
          :value="r.message_url"
          readonly
          :aria-label="tr('推送地址', 'Push URL')"
        />
        <div class="actions">
          <button
            @click="
              run(async () => {
                await copyText(r.message_url);
                notice = tr('已复制', 'Copied');
              })
            "
          >
            {{ tr("复制地址", "Copy URL") }}</button
          ><button @click="edit(r)">{{ tr("编辑", "Edit") }}</button
          ><button :disabled="busy" @click="remove(r)">
            {{ tr("删除", "Delete") }}
          </button>
        </div>
      </article>
      <form @submit.prevent="save">
        <h3>
          {{
            draft.id ? tr("编辑列表", "Edit List") : tr("新建列表", "New List")
          }}
        </h3>
        <label
          >{{ tr("名称", "Name")
          }}<input v-model="draft.name" required maxlength="120" /></label
        ><label v-for="d in devices" :key="d.id"
          ><input
            type="checkbox"
            v-model="draft.device_ids"
            :value="d.id"
            :disabled="!d.enabled"
          />{{ d.name }} {{ !d.enabled ? tr("已停用", "Disabled") : "" }}</label
        >
        <p class="muted">
          {{
            tr("空列表不发送给任何设备。", "An empty list sends to no devices.")
          }}
        </p>
        <button class="primary" :disabled="busy">
          {{ tr("保存列表", "Save List") }}</button
        ><button
          type="button"
          @click="draft = { id: '', name: '', device_ids: [], revision: '0' }"
        >
          {{ tr("取消编辑", "Cancel") }}
        </button>
      </form></template
    >
  </section>
</template>
