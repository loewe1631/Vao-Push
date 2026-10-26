import { ref, computed, watch } from "vue";

export type Locale = "zh" | "en";
export type ThemeMode = "system" | "light" | "dark";

const STORAGE_LOCALE_KEY = "vao_push_locale";
const STORAGE_THEME_KEY = "vao_push_theme";

function readInitialLocale(): Locale {
  if (typeof window === "undefined") return "zh";
  const saved = window.localStorage.getItem(STORAGE_LOCALE_KEY);
  if (saved === "zh" || saved === "en") return saved;
  return "zh";
}

function readInitialTheme(): ThemeMode {
  if (typeof window === "undefined") return "system";
  const saved = window.localStorage.getItem(STORAGE_THEME_KEY);
  if (saved === "light" || saved === "dark" || saved === "system") return saved;
  return "system";
}

export const locale = ref<Locale>(readInitialLocale());
export const themeMode = ref<ThemeMode>(readInitialTheme());
const systemPrefersDark = ref(
  typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches,
);

export const resolvedTheme = computed<"light" | "dark">(() => {
  if (themeMode.value === "light" || themeMode.value === "dark") {
    return themeMode.value;
  }
  return systemPrefersDark.value ? "dark" : "light";
});

export function applyDocumentPreferences() {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  root.lang = locale.value === "zh" ? "zh-CN" : "en";
  root.dataset.theme = resolvedTheme.value;
  root.dataset.themeMode = themeMode.value;
  root.style.colorScheme = resolvedTheme.value;
}

if (typeof window !== "undefined") {
  if (typeof window.matchMedia === "function") {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const listener = (event: MediaQueryListEvent) => {
      systemPrefersDark.value = event.matches;
      applyDocumentPreferences();
    };
    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", listener);
    }
  }
  watch(
    locale,
    (next) => {
      try {
        window.localStorage.setItem(STORAGE_LOCALE_KEY, next);
      } catch {}
      applyDocumentPreferences();
    },
    { immediate: true },
  );
  watch(
    [themeMode, resolvedTheme],
    ([mode]) => {
      try {
        window.localStorage.setItem(STORAGE_THEME_KEY, mode);
      } catch {}
      applyDocumentPreferences();
    },
    { immediate: true },
  );
}

export function setLocale(next: Locale) {
  locale.value = next;
}

export function toggleLocale() {
  locale.value = locale.value === "zh" ? "en" : "zh";
}

export function setThemeMode(next: ThemeMode) {
  themeMode.value = next;
}

export function cycleThemeMode() {
  const order: ThemeMode[] = ["light", "dark", "system"];
  const idx = order.indexOf(themeMode.value);
  themeMode.value = order[(idx + 1) % order.length]!;
}

export function tr(zh: string, en: string): string {
  return locale.value === "en" ? en : zh;
}

const backendMessageTranslations: Record<string, string> = {
  "请求未完成，请稍后重试。":
    "Request could not be completed. Please try again.",
  请求未完成: "Request could not be completed.",
  操作未完成: "Operation could not be completed.",
  账号或密码不正确: "Invalid username or password.",
  "登录已过期，请重新登录": "Session expired. Please sign in again.",
  "数据源仍被卡片使用，不能删除":
    "This data source is still used by cards and cannot be deleted.",
  "删除确认已过期，请重新查看影响范围":
    "Deletion confirmation changed. Please review the impact again.",
};

export function localizeErrorMessage(raw: string): string {
  if (locale.value === "zh") return raw;
  return backendMessageTranslations[raw] || raw;
}
