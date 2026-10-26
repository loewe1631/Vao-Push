<script setup lang="ts">
import { computed, ref } from "vue";
import { tr } from "./i18n";
const props = defineProps<{ modelValue: string }>();
const emit = defineEmits<{ "update:modelValue": [value: string] }>();
const raw = ref(false);
const document = computed(() => {
  try {
    return JSON.parse(props.modelValue);
  } catch {
    return null;
  }
});
const fields = computed(
  () => Object.entries(document.value?.fields || {}) as [string, any][],
);
function change(key: string, property: string, value: string) {
  const doc = JSON.parse(props.modelValue),
    field = doc.fields[key];
  if (property === "value")
    field.value = field.type === "boolean" ? value === "true" : value;
  else if (property === "type") {
    field.type = value;
    field.value = value === "boolean" ? false : value === "text" ? "" : "0";
  } else field[property] = value;
  emit("update:modelValue", JSON.stringify(doc, null, 2));
}
function rename(key: string, value: string) {
  const next = value.trim();
  if (
    !/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(next) ||
    Object.hasOwn(document.value.fields, next)
  )
    return;
  const doc = JSON.parse(props.modelValue);
  doc.fields = Object.fromEntries(
    Object.entries(doc.fields).map(([k, v]) => [k === key ? next : k, v]),
  );
  emit("update:modelValue", JSON.stringify(doc, null, 2));
}
function add() {
  const doc = JSON.parse(props.modelValue);
  let index = 1;
  while (doc.fields["field" + index]) index++;
  doc.fields["field" + index] = {
    type: "text",
    label: tr("新字段", "New Field"),
    value: "",
  };
  emit("update:modelValue", JSON.stringify(doc, null, 2));
}
</script>
<template>
  <div class="data-input">
    <div class="input-tabs">
      <button
        :class="!raw && document?.fields ? 'primary' : 'secondary'"
        type="button"
        @click="raw = false"
        :disabled="!document?.fields"
      >
        {{ tr("按字段填写", "Field Form") }}</button
      ><button
        :class="raw || !document?.fields ? 'primary' : 'secondary'"
        type="button"
        @click="raw = true"
      >
        {{ tr("编辑JSON", "Edit JSON") }}
      </button>
    </div>
    <template v-if="!raw && document?.fields"
      ><p class="muted">
        {{
          tr(
            "给每个字段填写名称和值。字段标识用于脚本与设计绑定，请保持一致。",
            "Fill in a display label and value for each field. Keep field keys aligned with your script and card bindings.",
          )
        }}
      </p>
      <div v-for="[key, f] in fields" :key="key" class="field-entry">
        <label
          >{{ tr("字段标识", "Field Key")
          }}<input
            :value="key"
            @change="
              rename(key, ($event.target as HTMLInputElement).value)
            " /></label
        ><label
          >{{ tr("显示名称", "Display Label")
          }}<input
            :value="f.label || ''"
            @input="
              change(key, 'label', ($event.target as HTMLInputElement).value)
            " /></label
        ><label
          >{{ tr("类型", "Type")
          }}<select
            :value="f.type"
            @change="
              change(key, 'type', ($event.target as HTMLSelectElement).value)
            "
          >
            <option value="text">{{ tr("文字", "Text") }}</option>
            <option value="decimal">{{ tr("数值", "Decimal") }}</option>
            <option value="integer">{{ tr("整数", "Integer") }}</option>
            <option value="percent">{{ tr("百分比", "Percent") }}</option>
            <option value="boolean">{{ tr("是/否", "Yes / No") }}</option>
            <option value="datetime">{{ tr("时间", "Date & Time") }}</option>
          </select></label
        ><label
          >{{ tr("内容", "Value")
          }}<select
            v-if="f.type === 'boolean'"
            :value="String(f.value)"
            @change="
              change(key, 'value', ($event.target as HTMLSelectElement).value)
            "
          >
            <option value="true">{{ tr("是", "Yes") }}</option>
            <option value="false">{{ tr("否", "No") }}</option></select
          ><input
            v-else
            :value="f.value ?? ''"
            @input="
              change(key, 'value', ($event.target as HTMLInputElement).value)
            "
        /></label>
      </div>
      <button
        class="secondary"
        type="button"
        @click="add"
        :disabled="fields.length >= 32"
      >
        {{ tr("增加数据字段", "Add Data Field") }}
      </button>
    </template>
    <template v-else
      ><p v-if="document?.items" class="muted">
        {{
          tr(
            "这份数据含多条记录（items），在JSON中编辑每条记录。也可以让脚本按同一结构更新。",
            "This payload contains multiple records (items). Edit each record in JSON or push updates with the same schema.",
          )
        }}
      </p>
      <textarea
        :value="modelValue"
        @input="
          emit(
            'update:modelValue',
            ($event.target as HTMLTextAreaElement).value,
          )
        "
        rows="12"
        class="code-editor"
        spellcheck="false"
        :aria-label="tr('数据内容JSON', 'Card Data JSON')"
      />
    </template>
  </div>
</template>
<style scoped>
.input-tabs {
  display: flex;
  gap: 8px;
  margin: 12px 0;
}
.field-entry {
  display: grid;
  grid-template-columns: 1fr 1fr 1fr 1.5fr;
  gap: 12px;
  padding: 14px;
  margin-bottom: 10px;
  background: var(--surface-subtle);
  border: 1px solid var(--border);
  border-radius: 12px;
}
.field-entry label {
  min-width: 0;
  margin-bottom: 0;
}
.field-entry input {
  min-width: 0;
}
@media (max-width: 750px) {
  .field-entry {
    grid-template-columns: 1fr 1fr;
  }
}
</style>
