<script setup lang="ts">
import { computed } from "vue";
import {
  nodeValue,
  signedColor,
  trendSignedColor,
  visible,
  visibleChildren,
  stateStyle,
  trendGeometry,
  type Node,
} from "./cardDesign";
import { locale, tr } from "./i18n";
import BrowserCardIcon from "./BrowserCardIcon.vue";
import { chartGeometry } from "./cardCompatibility";
const p = defineProps<{
  node: Node;
  state: any;
  item?: any;
  rows: number;
  selected?: string;
  editable?: boolean;
  legacy?: boolean;
}>();
const emit = defineEmits<{ select: [id: string] }>();
const field = computed(
  () =>
    (p.item?.fields || p.state?.fields || {})[
      (p.node.bind || "").split(".")[1] || ""
    ],
);
const value = computed(() => nodeValue(p.node, field.value, locale.value));
const signed = computed(() =>
  p.node.type === "sparkline"
    ? trendSignedColor(series.value)
    : signedColor(field.value),
);
const color = (value?: string) =>
  ({
    primary: "var(--card-text)",
    secondary: "var(--card-muted)",
    accent: "var(--card-accent)",
    surface: "var(--card-soft)",
  })[value || "primary"] || value;
const pair = (p?: { light: string; dark: string }) =>
  p ? `light-dark(${color(p.light)},${color(p.dark)})` : undefined;
const mapped = computed(() => stateStyle(p.node, field.value));
const foreground = computed(() =>
  mapped.value
    ? pair(mapped.value.colors) || color(mapped.value.color || "secondary")
    : p.node.color_rule === "signed"
      ? p.node.type === "badge"
        ? "white"
        : signed.value
      : pair(p.node.colors) || color(p.node.color),
);
const background = computed(() =>
  mapped.value
    ? pair(mapped.value.background_colors) ||
      color(mapped.value.background || "surface")
    : p.node.type === "badge" && p.node.color_rule === "signed"
      ? signed.value
      : pair(p.node.background_colors) ||
        (p.node.background
          ? color(p.node.background)
          : p.node.type === "badge"
            ? "var(--card-soft)"
            : "transparent"),
);
const activeChildren = computed(() =>
  p.legacy ? p.node.children || [] : visibleChildren(p.node, p.state, p.item),
);
const activeItems = computed(() =>
  (p.state?.items || [])
    .filter((i: any) => p.node.row && visible(p.node.row, p.state, i))
    .slice(0, Math.min(p.node.limit || 3, p.rows)),
);
const trend = computed(() => trendGeometry(series.value, p.node));
const style = computed(() => ({
  color: foreground.value,
  background:
    p.node.type === "badge"
      ? p.legacy && p.node.background
        ? color(p.node.background)
        : "transparent"
      : background.value,
  border: p.node.border
    ? `${p.node.border.width}px solid ${pair(p.node.border.colors) || color(p.node.border.color || "secondary")}`
    : undefined,
  fontSize: (p.node.font_size ?? (p.node.type === "text" ? 13 : 16)) + "px",
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
  flex: p.node.flex === 0 || p.node.type === "badge" ? "0 0 auto" : "1 1 0",
  minWidth: 0,
}));
const series = computed(
  () =>
    (p.item?.series || p.state?.series || {})[
      (p.node.bind || "").split(".")[1] || ""
    ],
);
const geometry = computed(() => chartGeometry(series.value));
const points = computed(() => geometry.value.points);
const candles = computed(() => geometry.value.candles);
</script>
<template>
  <div
    v-if="legacy || visible(node, state, item)"
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
        v-for="child in activeChildren"
        :key="child.id"
        :node="child"
        :state="state"
        :item="item"
        :rows="rows"
        :selected="selected"
        :editable="editable"
        :legacy="legacy"
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
        v-for="child in activeChildren"
        :key="child.id"
        :node="child"
        :state="state"
        :item="item"
        :rows="rows"
        :selected="selected"
        :editable="editable"
        :legacy="legacy"
        @select="emit('select', $event)"
      />
    </div>
    <div
      v-else-if="node.type === 'list'"
      class="preview-list"
      :style="{ gap: (node.spacing ?? 8) + 'px' }"
    >
      <template v-for="(record, index) in activeItems" :key="record.item_id"
        ><CardPreview
          v-if="node.row"
          :node="node.row"
          :state="state"
          :item="record"
          :rows="rows"
          :selected="selected"
          :editable="editable"
          :legacy="legacy"
          @select="emit('select', $event)" />
        <hr v-if="Number(index) < activeItems.length - 1"
      /></template>
      <span v-if="!activeItems.length" class="placeholder">{{
        tr("暂无列表数据", "No list items yet")
      }}</span>
    </div>
    <hr v-else-if="node.type === 'divider'" />
    <div
      v-else-if="node.type === 'spacer'"
      :style="{ minHeight: (node.spacing ?? 4) + 'px' }"
    />
    <BrowserCardIcon v-else-if="node.type === 'icon'" :node="node" />
    <svg
      v-else-if="node.type === 'sparkline'"
      viewBox="0 0 300 70"
      preserveAspectRatio="none"
      :style="{ height: (node.height || 32) + 'px', minHeight: 0 }"
      role="img"
      :aria-label="node.label || 'Trend'"
    >
      <template v-if="node.chart_style === 'bar'">
        <rect
          v-for="(bar, index) in trend.bars"
          :key="index"
          :x="bar.x - bar.width / 2"
          :y="bar.y"
          :width="bar.width"
          :height="bar.height"
          :fill="
            node.color_rule === 'signed'
              ? bar.positive
                ? '#16A667'
                : '#F6465D'
              : foreground
          "
        />
      </template>
      <template v-else>
        <polyline
          v-for="(segment, index) in trend.segments"
          :key="index"
          :points="segment"
          fill="none"
          :stroke="foreground"
          stroke-width="1.5"
        />
        <circle
          v-for="(point, index) in trend.bars"
          :key="index"
          :cx="point.x"
          :cy="point.pointY"
          r="1.5"
          :fill="foreground"
        />
      </template>
    </svg>
    <div v-else-if="node.type === 'chart'" class="native-chart">
      <span v-if="!series" class="placeholder">{{
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
          stroke="var(--card-accent)"
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
          background: legacy
            ? node.color_rule === 'signed'
              ? signed
              : 'var(--card-soft)'
            : background,
          color: foreground,
          borderRadius: (node.radius ?? 5) + 'px',
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
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  overflow-wrap: anywhere;
  font-variant-numeric: tabular-nums;
}
.node-badge {
  display: inline-block;
  white-space: nowrap;
  border-radius: 5px;
  padding: 5px 7px;
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
  height: 70px;
  min-height: 40px;
  max-height: 140px;
}
</style>
