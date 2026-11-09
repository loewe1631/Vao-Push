<script setup lang="ts">
import { ref, watch, onUnmounted } from "vue";
import type { Node } from "./cardDesign";
const p = defineProps<{ node: Node }>();
const image = ref("");
let active: AbortController | undefined;
let blob = "";
function clear() {
  active?.abort();
  if (blob) URL.revokeObjectURL(blob);
  blob = "";
  image.value = "";
}
onUnmounted(clear);
watch(
  () => p.node.image_url,
  async (raw) => {
    clear();
    if (!raw) return;
    let u: URL;
    try {
      u = new URL(raw);
    } catch {
      return;
    }
    if (
      u.protocol !== "https:" ||
      u.username ||
      u.password ||
      u.hash ||
      (u.port && u.port !== "443") ||
      !u.hostname.includes(".") ||
      /^([\d.]+|localhost)$/.test(u.hostname) ||
      u.hostname.endsWith(".local")
    )
      return;
    const controller = new AbortController();
    active = controller;
    const timer = setTimeout(() => controller.abort(), 2000);
    try {
      const r = await fetch(u, {
        credentials: "omit",
        redirect: "error",
        referrerPolicy: "no-referrer",
        signal: controller.signal,
      });
      if (
        !r.ok ||
        !r.headers.get("Content-Type")?.startsWith("image/") ||
        Number(r.headers.get("Content-Length") || 0) > 524288
      )
        return;
      const reader = r.body?.getReader();
      if (!reader) return;
      let length = 0;
      const chunks: Uint8Array[] = [];
      for (;;) {
        const part = await reader.read();
        if (part.done) break;
        length += part.value.byteLength;
        if (length > 524288) {
          await reader.cancel();
          return;
        }
        chunks.push(part.value);
      }
      const data = new Uint8Array(length);
      let offset = 0;
      for (const c of chunks) {
        data.set(c, offset);
        offset += c.length;
      }
      const flags = new TextDecoder("latin1").decode(data);
      if (flags.includes("acTL") || flags.includes("ANIM")) return;
      const b = new Blob([data]);
      const decoded = await createImageBitmap(b);
      const valid =
        decoded.width > 0 &&
        decoded.height > 0 &&
        decoded.width <= 2048 &&
        decoded.height <= 2048;
      decoded.close();
      if (!valid || controller.signal.aborted) return;
      blob = URL.createObjectURL(b);
      image.value = blob;
    } catch {
    } finally {
      clearTimeout(timer);
    }
  },
  { immediate: true },
);
</script>
<template>
  <span
    :style="{
      display: 'inline-flex',
      width: (node.icon_size || 20) + 'px',
      height: (node.icon_size || 20) + 'px',
      alignItems: 'center',
      justifyContent: 'center',
    }"
    role="img"
    :aria-label="node.label || node.symbol || 'Icon'"
    ><img
      v-if="image"
      :src="image"
      style="width: 100%; height: 100%; object-fit: contain"
      alt="" /><svg
      v-else
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
    >
      <template v-if="node.symbol?.includes('server')">
        <rect x="3" y="3" width="18" height="7" rx="2" />
        <rect x="3" y="14" width="18" height="7" rx="2" />
        <path d="M6 6h2m-2 11h2M12 6h6m-6 11h6" />
      </template>
      <template v-else>
        <rect x="3" y="3" width="18" height="18" rx="4" />
        <path d="M9 8a3 3 0 1 1 4 3c-1 .5-1 1-1 3m0 3v1" />
      </template></svg
  ></span>
</template>
