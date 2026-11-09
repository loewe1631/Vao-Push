<script setup lang="ts">
import { ref } from "vue";
import { tr } from "./i18n";
import type { Node, ColorPair } from "./cardDesign";
const p = defineProps<{ node: Node }>();
const error = ref("");
function json(event: Event, key: "states" | "unknown_state") {
  try {
    const text = (event.target as HTMLTextAreaElement).value;
    const v = text.trim() ? JSON.parse(text) : undefined;
    if (v !== undefined && (!v || typeof v !== "object" || Array.isArray(v)))
      throw Error();
    p.node[key] = v;
    error.value = "";
  } catch {
    error.value = tr("请输入有效 JSON 对象", "Enter a valid JSON object");
  }
}
function pair(key: "colors" | "background_colors") {
  if (p.node[key]) delete p.node[key];
  else p.node[key] = { light: "#153047", dark: "#E6EDF3" };
}
function numeric(
  e: Event,
  key: "icon_size" | "height" | "min_points" | "gap_seconds",
) {
  const text = (e.target as HTMLInputElement).value;
  if (text === "") delete p.node[key];
  else p.node[key] = Number(text);
}
</script>
<template>
  <fieldset>
    <legend>{{ tr("1.2 卡片能力", "1.2 Card features") }}</legend>
    <label
      >{{ tr("有值时显示（fields.key）", "Show when a field has a value")
      }}<input v-model="node.visible_when" placeholder="fields.optional_note"
    /></label>
    <label
      ><input type="checkbox" v-model="node.hide_if_empty" />{{
        tr(
          "缺失、null、空白时收起；0 和 false 保留",
          "Hide missing, null or blank; keep 0 and false",
        )
      }}</label
    >
    <div v-for="key in ['colors', 'background_colors'] as const" :key="key">
      <button type="button" class="secondary" @click="pair(key)">
        {{
          key === "colors"
            ? tr("文字明暗色对", "Text light/dark colors")
            : tr("背景明暗色对", "Background light/dark colors")
        }}
        · {{ node[key] ? tr("移除", "Remove") : tr("启用", "Enable") }}
      </button>
      <template v-if="node[key]"
        ><label
          >{{ tr("浅色", "Light") }}<input v-model="node[key]!.light" /></label
        ><label
          >{{ tr("深色", "Dark") }}<input v-model="node[key]!.dark" /></label
      ></template>
    </div>
    <label
      ><input
        type="checkbox"
        :checked="!!node.border"
        @change="
          node.border = node.border
            ? undefined
            : { width: 1, color: 'secondary' }
        "
      />{{ tr("边框", "Border") }}</label
    >
    <template v-if="node.border"
      ><label
        >{{ tr("颜色", "Color") }}<input v-model="node.border.color" /></label
      ><label
        >{{ tr("宽度", "Width")
        }}<input
          v-model.number="node.border.width"
          type="number"
          min="1"
          max="3"
      /></label>
      <button
        class="secondary"
        @click="
          node.border.colors = node.border.colors
            ? undefined
            : { light: '#D3DEE8', dark: '#334252' }
        "
      >
        {{ tr("边框明暗色对", "Border light/dark colors") }}
      </button>
      <template v-if="node.border.colors"
        ><input
          v-model="node.border.colors.light"
          :aria-label="tr('浅色边框', 'Light border')" /><input
          v-model="node.border.colors.dark"
          :aria-label="tr('深色边框', 'Dark border')" /></template
    ></template>
    <template v-if="['number', 'badge'].includes(node.type)"
      ><label
        >{{ tr("前缀", "Prefix")
        }}<input v-model="node.prefix" maxlength="32" /></label
      ><label
        >{{ tr("后缀", "Suffix")
        }}<input v-model="node.suffix" maxlength="32" /></label
    ></template>
    <template v-if="node.type === 'badge'"
      ><label
        >{{ tr("状态映射 JSON", "State mapping JSON")
        }}<textarea
          :value="node.states ? JSON.stringify(node.states, null, 2) : ''"
          @change="json($event, 'states')"
          placeholder='{"ok":{"text":"正常","color":"#16835B","background_colors":{"light":"#E5F5EE","dark":"#12372A"}}}'
        /></label
      ><label
        >{{
          tr(
            "未知状态样式 JSON（默认中性色）",
            "Unknown state JSON (neutral by default)",
          )
        }}<textarea
          :value="
            node.unknown_state
              ? JSON.stringify(node.unknown_state, null, 2)
              : ''
          "
          @change="json($event, 'unknown_state')"
          placeholder='{"text":"未知","color":"secondary","background":"surface"}'
        /></label
    ></template>
    <template v-if="node.type === 'icon'"
      ><label
        >SF Symbol<input
          v-model="node.symbol"
          placeholder="sf:server.rack" /></label
      ><label
        >{{ tr("HTTPS 图标地址", "HTTPS image URL")
        }}<input
          v-model="node.image_url"
          type="url"
          placeholder="https://example.com/icon.png" /></label
      ><label
        >{{ tr("尺寸", "Size")
        }}<input
          :value="node.icon_size"
          type="number"
          min="10"
          max="48"
          @input="numeric($event, 'icon_size')" /></label
      ><small>{{
        tr(
          "图片失败时显示系统图标；Web 系统图标为近似预览。",
          "Images fall back to a system symbol; Web symbols are approximate.",
        )
      }}</small></template
    >
    <template v-if="node.type === 'sparkline'"
      ><label
        >{{ tr("序列路径", "Series binding")
        }}<input v-model="node.bind" placeholder="series.history" /></label
      ><label
        >{{ tr("样式", "Style")
        }}<select v-model="node.chart_style">
          <option value="line">{{ tr("折线", "Line") }}</option>
          <option value="bar">{{ tr("迷你条形", "Mini bars") }}</option>
        </select></label
      ><label
        >{{ tr("高度", "Height")
        }}<input
          :value="node.height"
          type="number"
          min="16"
          max="80"
          @input="numeric($event, 'height')" /></label
      ><label
        >{{ tr("最少样本数", "Minimum samples")
        }}<input
          :value="node.min_points"
          type="number"
          min="2"
          max="60"
          @input="numeric($event, 'min_points')" /></label
      ><label
        >{{
          tr(
            "超过多少秒断开（0 为采样间隔的3倍）",
            "Gap seconds (0 = 3 sample intervals)",
          )
        }}<input
          :value="node.gap_seconds"
          type="number"
          min="0"
          max="604800"
          @input="numeric($event, 'gap_seconds')" /></label
    ></template>
    <p v-if="error" role="alert">{{ error }}</p>
  </fieldset>
</template>
<style scoped>
fieldset {
  display: grid;
  gap: 10px;
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 12px;
}
label {
  display: grid;
  gap: 5px;
}
textarea {
  min-height: 90px;
  width: 100%;
  font-family: monospace;
}
small {
  opacity: 0.7;
}
</style>
