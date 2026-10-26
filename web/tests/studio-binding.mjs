import { readFile } from "node:fs/promises";
import { test } from "node:test";
import assert from "node:assert/strict";
import ts from "typescript";
const source = await readFile(
  new URL("../src/studioWorkflow.ts", import.meta.url),
  "utf8",
);
const js = ts.transpileModule(source, {
  compilerOptions: {
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ESNext,
  },
}).outputText;
const { createLayout, missingBindings } = await import(
  "data:text/javascript;base64," + Buffer.from(js).toString("base64")
);
test("Binding checks use per-record fields inside a list and reject missing API mappings", () => {
  const state = {
    fields: { rootOnly: { type: "text", value: "root" } },
    items: [{ fields: { price: { type: "decimal", value: "0" } } }],
  };
  const design = createLayout("items", state, "Records");
  assert.deepEqual(missingBindings(design, state), []);
  design.layout.row.children[0].bind = "fields.rootOnly";
  assert.equal(missingBindings(design, state).length, 1);
  design.layout.row.children[0].text = "Fixed title";
  assert.deepEqual(missingBindings(design, state), []);
});
