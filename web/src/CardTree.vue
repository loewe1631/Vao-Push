<script setup lang="ts">
import { kindName, type Node } from "./cardDesign";
import { locale, tr } from "./i18n";
defineProps<{ node: Node; selected: string; root?: boolean }>();
const emit = defineEmits<{
  select: [id: string];
  move: [id: string, step: number];
  drop: [from: string, to: string];
}>();
function drag(event: DragEvent, id: string) {
  event.dataTransfer?.setData("text/plain", id);
}
</script>
<template>
  <div class="tree-branch">
    <div
      class="tree-row"
      :class="{ chosen: selected === node.id }"
      draggable="true"
      @dragstart.stop="drag($event, node.id)"
      @dragover.prevent
      @drop.prevent.stop="
        emit('drop', $event.dataTransfer?.getData('text/plain') || '', node.id)
      "
    >
      <button type="button" class="tree-pick" @click="emit('select', node.id)">
        {{ kindName(node.type, locale)
        }}<small>{{ node.label || node.bind || node.text || node.id }}</small>
      </button>
      <template v-if="!root"
        ><button
          type="button"
          :title="tr('向上移动', 'Move up')"
          @click="emit('move', node.id, -1)"
        >
          ↑</button
        ><button
          type="button"
          :title="tr('向下移动', 'Move down')"
          @click="emit('move', node.id, 1)"
        >
          ↓
        </button></template
      >
    </div>
    <div class="tree-children">
      <CardTree
        v-for="child in node.children || []"
        :key="child.id"
        :node="child"
        :selected="selected"
        @select="emit('select', $event)"
        @move="(id, step) => emit('move', id, step)"
        @drop="(from, to) => emit('drop', from, to)"
      />
      <CardTree
        v-if="node.row"
        :node="node.row"
        :selected="selected"
        @select="emit('select', $event)"
        @move="(id, step) => emit('move', id, step)"
        @drop="(from, to) => emit('drop', from, to)"
      />
    </div>
  </div>
</template>
<style scoped>
.tree-row {
  display: flex;
  align-items: center;
  gap: 4px;
  border: 1px solid transparent;
  border-radius: 10px;
  margin: 4px 0;
  padding: 2px 4px;
  transition:
    background 0.15s,
    border-color 0.15s;
}
.tree-row:hover {
  background: var(--surface-subtle);
}
.tree-row.chosen {
  border-color: var(--accent-border);
  background: var(--accent-soft);
}
.tree-row button {
  border: 0;
  background: transparent;
  color: inherit;
  padding: 6px 8px;
}
.tree-pick {
  flex: 1;
  text-align: left;
  min-width: 0;
  font-weight: 500;
}
.tree-pick small {
  display: block;
  font-size: 11px;
  color: var(--text-muted);
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 220px;
  font-weight: 400;
}
.tree-children {
  padding-left: 14px;
  border-left: 1px solid var(--border);
}
</style>
