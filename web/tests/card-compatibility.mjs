import { readFile } from "node:fs/promises";
import { test } from "node:test";
import assert from "node:assert/strict";
import ts from "typescript";
async function load(name) {
  let source = await readFile(
    new URL("../src/" + name + ".ts", import.meta.url),
    "utf8",
  );
  let js = ts.transpileModule(source, {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ESNext,
    },
  }).outputText;
  if (name === "cardDesign") {
    const random = ts.transpileModule(
      await readFile(new URL("../src/random.ts", import.meta.url), "utf8"),
      {
        compilerOptions: {
          target: ts.ScriptTarget.ES2022,
          module: ts.ModuleKind.ESNext,
        },
      },
    ).outputText;
    js = js.replace(
      '"./random"',
      JSON.stringify(
        "data:text/javascript;base64," + Buffer.from(random).toString("base64"),
      ),
    );
  }
  return import(
    "data:text/javascript;base64," + Buffer.from(js).toString("base64")
  );
}
const { formatValue, nodeValue, signedColor } = await load("cardDesign");
const {
  fieldsForNode,
  wrapGroup,
  pillNode,
  usesNumericFormat,
  designPrompt,
  chartGeometry,
} = await load("cardCompatibility");
test("Native text semantics retain empty literals and numeric-looking text", () => {
  assert.equal(
    nodeValue(
      { id: "x", type: "text", text: "", bind: "fields.x" },
      { type: "decimal", value: null },
    ),
    "",
  );
  assert.equal(
    nodeValue(
      { id: "x", type: "text", bind: "fields.x", decimals: 2 },
      { type: "text", value: "123.456", unit: "USD" },
    ),
    "123.456",
  );
  assert.equal(
    formatValue({ type: "text", value: "123.456" }, 2, "decimal"),
    "123.46",
  );
  assert.equal(
    formatValue({ type: "decimal", value: "0", unit: "kH/s" }, 1),
    "0.0 kH/s",
  );
  assert.equal(formatValue({ type: "decimal", value: null }, 1), "不可用");
  assert.equal(formatValue({ type: "text", value: "", unit: "USD" }), "");
});
test("Signed colors use valid decimal values and preserve zero", () => {
  assert.equal(
    signedColor({ type: "text", value: "故障" }),
    "var(--card-muted)",
  );
  assert.equal(signedColor({ value: false }), "var(--card-muted)");
  assert.equal(signedColor({ value: null }), "var(--card-muted)");
  assert.equal(signedColor({ value: "-0.00" }), "#16A667");
  assert.equal(signedColor({ value: "-0.001" }), "#F6465D");
  assert.equal(signedColor({ value: "12345678901234567890.1" }), "#16A667");
  assert.equal(signedColor({ value: "-1e3" }), "var(--card-muted)");
});
test("List field choices stay in item scope and include fields beyond the first record", () => {
  const row = {
    id: "row",
    type: "row",
    children: [{ id: "price", type: "text", bind: "fields.price" }],
  };
  const root = {
    id: "root",
    type: "column",
    children: [
      { id: "rootValue", type: "text" },
      { id: "list", type: "list", row },
    ],
  };
  const state = {
    fields: { privateRoot: { type: "text" } },
    items: [
      { fields: { price: { type: "decimal" } } },
      { fields: { status: { type: "text" } } },
    ],
  };
  assert.deepEqual(Object.keys(fieldsForNode(root, row.children[0], state)), [
    "price",
    "status",
  ]);
  assert.deepEqual(Object.keys(fieldsForNode(root, root.children[0], state)), [
    "privateRoot",
  ]);
  assert.equal(usesNumericFormat(row.children[0], { type: "decimal" }), true);
  assert.equal(usesNumericFormat(row.children[0], { type: "text" }), false);
});
test("Group and static-pill compositions use existing nodes and preserve selected content", () => {
  const root = {
    id: "root",
    type: "column",
    children: [{ id: "status", type: "badge", bind: "fields.status" }],
  };
  const result = wrapGroup(root, "status", "wrapper");
  assert.deepEqual(result.children[0].children[0], root.children[0]);
  assert.equal(root.children[0].id, "status");
  assert.equal(result.children[0].type, "column");
  const pill = pillNode("pill", "zh");
  assert.equal(pill.type, "text");
  assert.equal(pill.text, "状态");
  assert.equal(pill.color_rule, undefined);
});
test("AI instructions preserve size overrides and distinguish root/item metadata without copying data values", () => {
  const d = {
    schema_version: 2,
    name: "Demo",
    family: "medium",
    theme: "system",
    layout: { id: "root", type: "text", text: "Title" },
    layouts: { small: { id: "root", type: "text", text: "Small" } },
  };
  const state = {
    fields: { root: { type: "decimal", value: "PRIVATE_DATA_SENTINEL" } },
    items: [
      { fields: { item: { type: "text", value: "PRIVATE_ITEM_SENTINEL" } } },
    ],
  };
  for (const lang of ["zh", "en"]) {
    const prompt = designPrompt(d, state, "Retain sizes", lang);
    assert.ok(prompt.includes("schema_version=2"));
    assert.ok(prompt.includes("App 1.0.0"));
    assert.ok(prompt.includes("ids AND types"));
    assert.ok(prompt.includes('"layouts":{"small"'));
    assert.ok(prompt.includes('"root":{"fields"'));
    assert.ok(prompt.includes('"items":{"fields"'));
    assert.equal(prompt.includes("PRIVATE_DATA_SENTINEL"), false);
    assert.equal(prompt.includes("PRIVATE_ITEM_SENTINEL"), false);
  }
});

test("Chart samples use timestamp spacing and native flat-series behavior", () => {
  const s = {
    type: "line",
    points: [
      { t: "2026-11-08T00:00:00Z", value: "1" },
      { t: "2026-11-08T00:01:00Z", value: "2" },
      { t: "2026-11-08T00:03:00Z", value: "3" },
    ],
  };
  const geometry = chartGeometry(s),
    xs = geometry.points.split(" ").map((p) => Number(p.split(",")[0]));
  assert.equal(xs[0], 50);
  assert.equal(xs[2], 250);
  assert.ok(Math.abs(xs[1] - (50 + 200 / 3)) < 1e-9);
  assert.equal(
    chartGeometry({
      points: [
        { t: s.points[0].t, value: "5" },
        { t: s.points[1].t, value: "5" },
      ],
    }).points,
    "75,3 225,3",
  );
  assert.deepEqual(chartGeometry({ points: [] }), { points: "", candles: [] });
  assert.equal(
    chartGeometry({ type: "line", points: [{ t: s.points[0].t, value: null }] })
      .points,
    "",
  );
  assert.equal(
    chartGeometry({ type: "line", points: [{ ...s.points[0], o: "99" }] })
      .candles[0].top,
    3,
  );
});
