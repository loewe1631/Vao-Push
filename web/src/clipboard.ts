// Public HTTP origins do not expose navigator.clipboard. Keep copy buttons usable
// there via the browser's user-initiated selection command.
export async function copyText(value: string): Promise<void> {
  if (window.isSecureContext && navigator.clipboard) {
    try {
      await navigator.clipboard.writeText(value);
      return;
    } catch {
      // Try the selection path when clipboard permission was not granted.
    }
  }
  const focused = document.activeElement as HTMLElement | null;
  const input = document.createElement("textarea");
  input.value = value;
  input.setAttribute("readonly", "");
  input.style.position = "fixed";
  input.style.top = "0";
  input.style.left = "-9999px";
  document.body.appendChild(input);
  try {
    input.focus();
    input.select();
    input.setSelectionRange(0, value.length);
    if (!document.execCommand("copy")) throw new Error("Copy failed");
  } finally {
    input.remove();
    focused?.focus();
  }
}
