# Card design v3 (App 1.2)

Version 3 adds optional native capabilities. Existing v1/v2 designs remain valid and do not require conversion. The visual editor's **Enable 1.2 features** action saves the current layouts as the fixed legacy representation before enabling new properties.

```json
{
  "schema_version": 3,
  "name": "Status",
  "family": "medium",
  "theme": "system",
  "layout": {
    "id": "status", "type": "badge", "bind": "fields.status",
    "states": {"ok": {"text": "Ready", "color": "#16835B", "background": "surface"}},
    "hide_if_empty": true
  },
  "fallback": {"layout": {"id": "status", "type": "text", "bind": "fields.status"}}
}
```

`X-Vao-Card-Schema: 3` selects the full design. Header `2` selects `fallback.layout/layouts` as v2; an absent or unknown header selects only `fallback.layout` as v1. The publication revision is shared by all representations. App 1.2 retries a v1 response with header 2 to retain size overrides when connected to a 1.1 server; this retry cannot roll back the publication or snapshot revision. Fallback is validated as a complete v2 design and saved at publication time; snapshot changes never rewrite it. Keep legacy numeric fields when adding a new textual status field. The client preserves compatible local node adjustments when upgrading representations; changed adjusted node identities/types remain conflicts.

The document limit is 64 KiB. Each tree has at most 64 nodes, six levels, and 24 KiB. Four size overrides are supported. Fallback must also fit the original limits. Node IDs are unique within each tree.

| Property | Behavior |
| --- | --- |
| `visible_when: "fields.key"` | Show when the scoped value exists and is neither null nor blank. `0` and `false` both count as values. It is a presence condition, not a comparison expression. |
| `hide_if_empty: true` | Hide a missing/null/blank bound field or static text. Empty containers collapse; adjacent/edge dividers and spacers collapse. List rows use item scope only. |
| `colors`, `background_colors` | `{ "light": "#RRGGBB", "dark": "#RRGGBB" }`; semantic colors are also allowed. |
| `states` | Badge map from exact raw values to `{text,color,colors,background,background_colors}`; up to 16 states. Boolean keys are `true`/`false`. |
| `unknown_state` | Optional fallback badge style. Without one, unknown values retain their value with secondary text and a surface fill. |
| `border` | `{width: 1..3, color?, colors?}` on existing nodes/containers. |
| `prefix`, `suffix` | Up to 32 UTF-8 bytes each on number/badge. Decorate the formatted value; numeric precision and units are retained. |
| `icon` | Static `symbol` (SF Symbol, optional `sf:` prefix), `image_url`, and `icon_size` 10..48. Requires a symbol or image; image failure falls back to a symbol/question mark. |
| `sparkline` | Bind `series.key`; `chart_style` line/bar, `height` 16..80, `min_points` 2..60, `gap_seconds` 0..604800. Fewer samples collapse the node. |

Colors are `primary`, `secondary`, `accent`, `surface`, or six-digit hex. Priority is badge state mapping, signed coloring, light/dark pair, then static/semantic color. Container appearance follows the card's theme, including local theme adjustments. Web SF Symbols are approximate; the iOS renderer is authoritative.

HTTPS icons use public DNS host names on port 443, without credentials or redirects. Native DNS validation has a one-second deadline; downloads have a 2-second request/3-second resource timeout, 512 KiB limit, one decoded frame, dimensions up to 2048 square, and at most four concurrent requests. App/Widget share an independent cache of up to 20 images (10 MiB compressed), valid for seven days; failures back off for five minutes. Widget refresh prefetches at most four unique URLs. Icons receive no server bearer token, cookies or stored credentials. Offline cards retain their cached snapshot and use a cached icon or symbol. An image is decorative and never changes the card's availability.

Sparklines use real timestamps and preserve gaps larger than `gap_seconds`, defaulting to three declared sample intervals. OHLC uses close values for mini trends. Signed lines use the change from first to last value. Bars use a zero baseline; signed bars distinguish positive/negative samples. Empty or unavailable data is never converted into zero. Existing full charts retain their original behavior.

## Opt-in source history

Authenticated Web administrators can `GET/PUT /v1/card-sources/{id}/history`. Save with `If-Match: "history-N"`. Configuration affects only that administrator's source and starts accumulating from subsequent valid reports:

```json
{"rules":[{"field":"fields.rate","series_key":"rate_history","interval_seconds":300,"retention_hours":24,"limit":60,"status_field":"fields.status","accepted_statuses":["ok"]}]}
```

Rules accept root numeric fields only: at most four series per source, 2..60 points each, 60..86400 seconds minimum interval and 1..168 hours retention. The optional status filter skips warming/unavailable/low-sample states according to the source's own vocabulary. New samples require a strictly later source timestamp and the configured interval; replays, old timestamps, nulls and invalid values do not create samples. No timer fabricates source data. Upstream series with the same name are rejected. The full resulting snapshot still obeys the original 64 KiB/four-series limits. Writes and history changes share the stream transaction; failed writes cannot append points.

Changing a rule restarts that rule's accumulation; unchanged rules retain samples. Removing rules stops accumulation, and the next source report drops their generated series. Hourly pruning removes expired stored samples even for inactive sources. PostgreSQL backups include rules and points. After saving or publishing a v3 design, reverting to a server older than 1.2 requires restoring the matching pre-upgrade database backup: those binaries do not understand v3 layouts. A program-only rollback is not sufficient after new-format writes. Source deletion retains the existing no-reference requirement and removes only that source's history.

See [v3 JSON schema](card-design-v3.schema.json). Runtime validation additionally enforces UTF-8 byte limits, node-specific properties and URL restrictions.
