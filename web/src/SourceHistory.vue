<script setup lang="ts">
import { ref, watch } from "vue";
import { tr } from "./i18n";
const p = defineProps<{ sourceID: string; csrf: string }>();
const rules = ref<any[]>([]),
  revision = ref("0"),
  error = ref(""),
  notice = ref(""),
  busy = ref(false),
  loaded = ref(false);
let generation = 0;
async function request(method = "GET") {
  const target = p.sourceID,
    current = ++generation;
  loaded.value = false;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    const r = await fetch("/v1/card-sources/" + target + "/history", {
      method,
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": p.csrf,
        "If-Match": `"history-${revision.value}"`,
      },
      body:
        method === "PUT" ? JSON.stringify({ rules: rules.value }) : undefined,
    });
    const body = await r.json();
    if (current !== generation || p.sourceID !== target) return;
    if (!r.ok) throw Error(body.error?.message || "Request failed");
    rules.value = body.data.rules;
    revision.value = body.data.revision;
    loaded.value = true;
    if (method === "PUT")
      notice.value = tr(
        "已保存；从后续有效上报开始积累",
        "Saved; accumulation starts with future valid reports",
      );
  } catch (e) {
    if (current === generation) error.value = String(e);
  } finally {
    if (current === generation) busy.value = false;
  }
}
watch(
  () => p.sourceID,
  () => {
    rules.value = [];
    revision.value = "0";
    if (p.sourceID) request();
  },
  { immediate: true },
);
</script>
<template>
  <details v-if="sourceID">
    <summary>
      {{
        tr(
          "历史序列积累（按源显式开启）",
          "History accumulation (opt in per source)",
        )
      }}
    </summary>
    <p>
      {{
        tr(
          "每源最多4组、每组60点、保留1至168小时。只积累真实有效上报，缺失和无效状态跳过，不提高采样频率。更改规则会重新积累该规则；停用后下一次上报移除其序列。",
          "Up to 4 series, 60 points each, 1–168 hours. Only actual valid reports are sampled. Missing values and invalid statuses are skipped. Changing a rule restarts that series; disabling removes it on the next report.",
        )
      }}
    </p>
    <div
      v-for="(rule, index) in rules"
      :key="index"
      style="display: grid; gap: 6px; margin: 12px 0"
    >
      <label
        >{{ tr("数值字段", "Numeric field")
        }}<input v-model="rule.field" placeholder="fields.rate" /></label
      ><label
        >{{ tr("序列名", "Series key")
        }}<input v-model="rule.series_key" /></label
      ><label
        >{{ tr("最短采样间隔（秒）", "Minimum interval (seconds)")
        }}<input
          v-model.number="rule.interval_seconds"
          type="number"
          min="60"
          max="86400" /></label
      ><label
        >{{ tr("保留小时", "Retention hours")
        }}<input
          v-model.number="rule.retention_hours"
          type="number"
          min="1"
          max="168" /></label
      ><label
        >{{ tr("最多点数", "Point limit")
        }}<input
          v-model.number="rule.limit"
          type="number"
          min="2"
          max="60" /></label
      ><label
        >{{ tr("状态字段（可选）", "Status field (optional)")
        }}<input
          v-model="rule.status_field"
          placeholder="fields.status" /></label
      ><label v-if="rule.status_field"
        >{{ tr("可积累状态（逗号分隔）", "Accepted statuses (comma separated)")
        }}<input
          :value="(rule.accepted_statuses || []).join(',')"
          @change="
            rule.accepted_statuses = ($event.target as HTMLInputElement).value
              .split(',')
              .map((x) => x.trim())
              .filter(Boolean)
          " /></label
      ><button class="secondary" @click="rules.splice(index, 1)">
        {{ tr("删除规则", "Remove rule") }}
      </button>
    </div>
    <button
      class="secondary"
      :disabled="!loaded || busy || rules.length >= 4"
      @click="
        rules.push({
          field: 'fields.value',
          series_key: 'value_history',
          interval_seconds: 300,
          retention_hours: 24,
          limit: 60,
        })
      "
    >
      {{ tr("添加历史规则", "Add history rule") }}</button
    ><button
      class="primary"
      :disabled="!loaded || busy"
      @click="request('PUT')"
    >
      {{ tr("保存历史配置", "Save history settings") }}</button
    ><button class="secondary" :disabled="busy" @click="request()">
      {{ tr("重新读取", "Reload") }}
    </button>
    <p v-if="error" role="alert">{{ error }}</p>
    <p v-if="notice">{{ notice }}</p>
  </details>
</template>
