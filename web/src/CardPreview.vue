<script setup lang="ts">
import { computed } from "vue";
import { formatValue, type Node } from "./cardDesign";
import { locale, tr } from "./i18n";
const p = defineProps<{
  node: Node;
  state: any;
  item?: any;
  rows: number;
  selected?: string;
  editable?: boolean;
}>();
const emit = defineEmits<{ select: [id: string] }>();
const field = computed(
  () =>
    (p.item?.fields || p.state?.fields || {})[
      (p.node.bind || "").split(".")[1] || ""
    ],
);
const value = computed(
  () =>
    p.node.text ||
    formatValue(field.value, p.node.decimals, p.node.format, locale.value),
);
const signed = computed(() =>
  field.value?.value == null
    ? "#7c8999"
    : String(field.value.value).startsWith("-")
      ? "#F6465D"
      : "#16A667",
);
const color = (value?: string) =>
  ({
    primary: "var(--card-text)",
    secondary: "var(--card-muted)",
    accent: "#1677F2",
  })[value || "primary"] || value;
const style = computed(() => ({
  color:
    p.node.color_rule === "signed" && p.node.type !== "badge"
      ? signed.value
      : color(p.node.color),
  background: p.node.background ? color(p.node.background) : "transparent",
  fontSize: (p.node.font_size || (p.node.type === "text" ? 13 : 16)) + "px",
  fontWeight:
    p.node.weight === "bold"
      ? 700
      : p.node.weight === "semibold"
        ? 600
        : p.node.weight === "medium"
          ? 500
          : 400,
  padding: (p.node.padding || 0) + "px",
  borderRadius: (p.node.radius || 0) + "px",
  textAlign: (p.node.alignment === "trailing"
    ? "right"
    : p.node.alignment === "center"
      ? "center"
      : "left") as any,
  flex: p.node.flex === 0 ? "0 0 auto" : "1 1 0",
  minWidth: 0,
}));
const series = computed(
  () =>
    (p.item?.series || p.state?.series || {})[
      (p.node.bind || "").split(".")[1] || ""
    ],
);
const points = computed(() => {
  const values = (series.value?.points || []).map((p: any) =>
    Number(p.c ?? p.value),
  );
  const min = Math.min(...values),
    max = Math.max(...values),
    span = max - min || 1;
  return values
    .map(
      (v: number, i: number) =>
        `${5 + (i * 290) / Math.max(values.length - 1, 1)},${65 - ((v - min) / span) * 60}`,
    )
    .join(" ");
});

const candles = computed(() => {
  const points = series.value?.points || [];
  const low = Math.min(...points.map((p: any) => Number(p.l))),
    high = Math.max(...points.map((p: any) => Number(p.h))),
    span = high - low || 1;
  return points.map((p: any, i: number) => {
    const y = (v: string) => 65 - ((Number(v) - low) / span) * 60;
    return {
      x: 5 + (i * 290) / Math.max(points.length - 1, 1),
      high: y(p.h),
      low: y(p.l),
      top: Math.min(y(p.o), y(p.c)),
      height: Math.max(Math.abs(y(p.o) - y(p.c)), 1),
      width: Math.min(10, 240 / Math.max(points.length, 1)),
      color: Number(p.c) >= Number(p.o) ? "#16A667" : "#F6465D",
    };
  });
});
</script>
<template>
  <div
    class="card-node"
    :class="{ picked: editable && selected === node.id }"
    :style="style"
    @click.stop="editable && emit('select', node.id)"
  >
    <div
      v-if="node.type === 'row' || node.type === 'column'"
      :style="{
        display: 'flex',
        flexDirection: node.type === 'row' ? 'row' : 'column',
        gap: (node.spacing ?? (node.type === 'row' ? 8 : 5)) + 'px',
        alignItems: node.type === 'row' ? 'center' : 'stretch',
      }"
    >
      <CardPreview
        v-for="child in node.children || []"
        :key="child.id"
        :node="child"
        :state="state"
        :item="item"
        :rows="rows"
        :selected="selected"
        :editable="editable"
        @select="emit('select', $event)"
      />
    </div>
    <div
      v-else-if="node.type === 'grid'"
      :style="{
        display: 'grid',
        gridTemplateColumns: `repeat(${node.columns || 2},minmax(0,1fr))`,
        gap: (node.spacing ?? 8) + 'px',
      }"
    >
      <CardPreview
        v-for="child in node.children || []"
        :key="child.id"
        :node="child"
        :state="state"
        :item="item"
        :rows="rows"
        :selected="selected"
        :editable="editable"
        @select="emit('select', $event)"
      />
    </div>
    <div
      v-else-if="node.type === 'list'"
      class="preview-list"
      :style="{ gap: (node.spacing ?? 8) + 'px' }"
    >
      <template
        v-for="(record, index) in (state?.items || []).slice(
          0,
          Math.min(node.limit || 3, rows),
        )"
        :key="record.item_id"
        ><CardPreview
          v-if="node.row"
          :node="node.row"
          :state="state"
          :item="record"
          :rows="rows"
          :selected="selected"
          :editable="editable"
          @select="emit('select', $event)" />
        <hr
          v-if="
            Number(index) <
            Math.min(state.items.length, node.limit || 3, rows) - 1
          "
      /></template>
      <span v-if="!state?.items?.length" class="placeholder">{{
        tr("暂无列表数据", "No list items yet")
      }}</span>
    </div>
    <hr v-else-if="node.type === 'divider'" />
    <div
      v-else-if="node.type === 'spacer'"
      :style="{ minHeight: (node.spacing || 4) + 'px' }"
    />
    <div v-else-if="node.type === 'chart'">
      <span v-if="!series?.points?.length" class="placeholder">{{
        tr("暂无历史数据", "No chart history yet")
      }}</span
      ><svg
        v-else
        viewBox="0 0 300 70"
        role="img"
        :aria-label="tr('历史图表', 'History chart')"
      >
        <g v-if="series.type === 'ohlc'">
          <g v-for="(bar, index) in candles" :key="index">
            <line
              :x1="bar.x"
              :x2="bar.x"
              :y1="bar.high"
              :y2="bar.low"
              :stroke="bar.color"
            />
            <rect
              :x="bar.x - bar.width / 2"
              :y="bar.top"
              :width="bar.width"
              :height="bar.height"
              :fill="bar.color"
            />
          </g>
        </g>
        <polyline
          v-else
          :points="points"
          fill="none"
          stroke="#1677F2"
          stroke-width="2"
        />
      </svg>
    </div>
    <div v-else>
      <small v-if="node.label" class="node-label">{{ node.label }}</small
      ><span
        v-if="node.type === 'badge'"
        class="node-badge"
        :style="{
          background: node.color_rule === 'signed' ? signed : '#eaf3ff',
          color: node.color_rule === 'signed' ? 'white' : color(node.color),
        }"
        >{{ value }}</span
      ><span v-else class="node-value">{{ value }}</span>
    </div>
  </div>
</template>
<style scoped>
.card-node {
  box-sizing: border-box;
  line-height: 1.25;
  position: relative;
}
.picked {
  outline: 1.5px dashed #1677f2;
  outline-offset: 3px;
}
.preview-list {
  display: flex;
  flex-direction: column;
}
.node-label {
  display: block;
  font-size: 10px;
  color: var(--card-muted);
  margin-bottom: 2px;
}
.node-value {
  overflow-wrap: anywhere;
  font-variant-numeric: tabular-nums;
}
.node-badge {
  display: inline-block;
  white-space: nowrap;
  border-radius: 6px;
  padding: 5px 8px;
  font-variant-numeric: tabular-nums;
}
.placeholder {
  color: var(--card-muted);
  font-size: 12px;
}
hr {
  width: 100%;
  margin: 0;
  border: 0;
  border-top: 1px solid var(--card-line);
}
svg {
  width: 100%;
  height: auto;
  max-height: 140px;
}
</style>
