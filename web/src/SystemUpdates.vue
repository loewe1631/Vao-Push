<script setup lang="ts">
import { ref, onMounted, onUnmounted, computed } from "vue";
import { tr } from "./i18n";
const props = defineProps<{ csrf: string }>();
const state = ref<Record<string, any>>({}),
  busy = ref(false),
  error = ref("");
let timer: ReturnType<typeof setInterval> | undefined;
const running = computed(() => state.value.task?.status === "running");
async function request(path = "", body?: unknown) {
  const r = await fetch("/v1/system/update" + path, {
    method: path ? "POST" : "GET",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", "X-CSRF-Token": props.csrf },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const v = await r.json();
  if (!r.ok) throw Error(v.error?.message || "Update request failed");
  state.value = v.data;
}
async function run(path = "", body?: unknown) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await request(path, body);
  } catch (e) {
    error.value =
      tr(
        "请求暂未完成，任务可能仍在运行。页面会重连：",
        "Request incomplete; the task may still be running. Reconnecting: ",
      ) + String(e);
  } finally {
    busy.value = false;
  }
}
const pending = ref<Record<string, any> | null>(null);
function install() {
  if (state.value.available) pending.value = { ...state.value.available };
}
async function confirmInstall() {
  const target = pending.value;
  if (!target) return;
  pending.value = null;
  await run("/install", { release_id: target.release_id, confirm: true });
}
onMounted(() => {
  run();
  timer = setInterval(() => {
    if (!busy.value && state.value.configured) run();
  }, 4000);
});
onUnmounted(() => clearInterval(timer));
const stages: Record<string, string> = {
  checking: "检查版本",
  downloading: "下载安装包",
  verifying: "验证安装包",
  backup: "备份数据",
  installing: "切换并验证服务",
  completed: "升级完成",
  failed: "升级失败",
  interrupted: "任务中断，需检查",
};
</script>
<template>
  <section class="panel">
    <h2>{{ tr("系统更新", "System Updates") }}</h2>
    <p>
      {{ tr("当前服务端版本：", "Server version: ")
      }}{{ state.running_version || state.current_version || "—" }}
    </p>
    <p class="muted">
      {{
        tr(
          "服务端与Web一起更新；旧版App继续使用已有功能，手机更新通过App Store完成。",
          "The server and Web UI update together. Existing apps stay supported; app updates use the App Store.",
        )
      }}
    </p>
    <p v-if="error" class="banner error">{{ error }}</p>
    <p v-if="!state.configured" class="muted">
      {{
        tr(
          "Web更新尚未启用。执行一次保留数据的标准升级（--upgrade）即可补齐，无需重新安装；之后直接在此检查更新。",
          "Web updates are not enabled. Run one standard in-place upgrade (--upgrade) to enable them without reinstalling or resetting data. Then check for updates here.",
        )
      }}
    </p>
    <p v-if="state.checked_at">
      {{ tr("最近检查：", "Last checked: ") }}{{ state.checked_at }}
    </p>
    <p v-if="state.check_error" class="banner error">{{ state.check_error }}</p>
    <div v-if="state.available">
      <h3>
        {{ tr("可升级版本：", "Available version: ")
        }}{{ state.available.version }}
      </h3>
      <p style="white-space: pre-wrap">{{ state.available.notes }}</p>
      <p>
        {{ tr("最低App版本：", "Minimum app version: ")
        }}{{ state.available.min_app_version }}
      </p>
      <button class="primary" :disabled="busy || running" @click="install">
        {{ tr("备份并升级", "Back Up and Upgrade") }}
      </button>
    </div>
    <p v-else-if="state.checked_at && !state.check_error">
      {{
        tr(
          "没有适用于此安装的更新。",
          "No compatible update is available for this installation.",
        )
      }}
    </p>
    <div v-if="pending" role="dialog" aria-label="确认系统升级" class="banner">
      <h3>
        {{ tr("确认升级到", "Confirm upgrade to") }} {{ pending.version }}
      </h3>
      <p>
        {{
          tr(
            "系统会先备份，再短暂停止服务并切换版本。现有配置与数据保留；升级期间页面会自动重连。",
            "A backup precedes a brief service stop and version switch. Configuration and data are kept; this page reconnects automatically.",
          )
        }}
      </p>
      <button
        class="primary"
        :disabled="busy || running"
        @click="confirmInstall"
      >
        {{ tr("确认备份并升级", "Confirm Backup and Upgrade") }}</button
      ><button :disabled="busy" @click="pending = null">
        {{ tr("取消", "Cancel") }}
      </button>
    </div>
    <button
      :disabled="!state.configured || busy || running"
      @click="run('/check')"
    >
      {{ tr("检查更新", "Check for Updates") }}
    </button>
    <div v-if="state.task" class="banner">
      <strong>{{ state.task.target_version }}</strong> ·
      {{ tr(stages[state.task.stage] || state.task.stage, state.task.stage) }} ·
      {{ state.task.status }}
      <p>{{ state.task.message }}</p>
    </div>
  </section>
</template>
