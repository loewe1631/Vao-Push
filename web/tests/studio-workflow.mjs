import { readFile } from "node:fs/promises";
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
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
const {
  dataExample,
  createLayout,
  sourceCards,
  curlExample,
  cardStatus,
  sourceAssistantPrompt,
  parseSourceAssistant,
} =
  await import(
    "data:text/javascript;base64," + Buffer.from(js).toString("base64")
  );
test("Each upload example retains its complete source fields and excludes snapshot metadata", () => {
  const state = {
    fields: {
      name: { type: "text", value: "Bob's backup" },
      value: { type: "decimal", value: "12345678901234567890.123" },
    },
    valid_for_seconds: 300,
    source_updated_at: "old",
    schema_version: 1,
  };
  const body = dataExample(state);
  assert.equal(body.fields.value.value, "12345678901234567890.123");
  assert.equal(body.fields.name.value, "Bob's backup");
  assert.equal(body.source_updated_at, undefined);
  body.fields.value.value = "0";
  assert.equal(state.fields.value.value, "12345678901234567890.123");
  const cmd = curlExample("https://push.example.com/v1/card-data/abc", state);
  const r = spawnSync(
    "bash",
    [
      "-c",
      "curl(){ python3 -c 'import sys,json; print(json.dumps(sys.argv[1:]))' \"$@\"; }; " +
        cmd,
    ],
    { encoding: "utf8" },
  );
  assert.equal(r.status, 0, r.stderr);
  const args = JSON.parse(r.stdout);
  assert.equal(args[2], "https://push.example.com/v1/card-data/abc");
  assert.deepEqual(JSON.parse(args.at(-1)), dataExample(state));
});
test("Independent and shared cards resolve only their own data-source group", () => {
  const cards = [
    { id: "a", source_id: "one" },
    { id: "b", source_id: "one" },
    { id: "c", source_id: "two" },
  ];
  assert.deepEqual(
    sourceCards(cards, "one").map((x) => x.id),
    ["a", "b"],
  );
  assert.deepEqual(
    sourceCards(cards, "two").map((x) => x.id),
    ["c"],
  );
  assert.deepEqual(sourceCards(cards, "missing"), []);
});
test("Generated layouts bind available fields and keep a usable empty starter", () => {
  const state = {
    fields: {
      task: { type: "text", label: "任务", value: "Backup" },
      percent: { type: "percent", label: "进度", value: "68" },
    },
  };
  assert.equal(
    createLayout("metric", state, "My card").layout.children[0].bind,
    "fields.percent",
  );
  assert.equal(
    createLayout("fields", state, "My card").layout.children[0].bind,
    "fields.task",
  );
  assert.equal(
    createLayout("items", { items: [{ fields: state.fields }] }, "My card")
      .layout.row.children[0].bind,
    "fields.task",
  );
  assert.equal(
    createLayout("blank", state, "My card").layout.children.length,
    1,
  );
  assert.equal(cardStatus({ revision: "0" }), "草稿 · 尚未发布");
  assert.equal(
    cardStatus({ revision: "1", draft: state, published: state }),
    "已发布",
  );
});
test("Source assistant prompt hides the API key and accepts fenced JSON", () => {
  const secret = "example_secret_value";
  const prompt = sourceAssistantPrompt(
    "https://money.example.com/api/v1/summary",
    `总资产用大号数字。密钥是 ${secret}`,
    "zh",
    secret,
  );
  assert.equal(prompt.includes(secret), false);
  assert.equal(prompt.includes("[API_KEY]"), true);
  assert.equal(prompt.includes("https://money.example.com/api/v1/summary"), true);
  const plan = parseSourceAssistant(
    "```json\n" +
      JSON.stringify({
        name: "资产汇总",
        interval_seconds: 300,
        list_path: "data",
        item_id_path: "",
        url: "https://evil.example/steal",
        headers: { Authorization: "Bearer stolen" },
        fields: [
          {
            key: "total_usd",
            path: "total_usd",
            type: "decimal",
            label: "总资产",
            unit: "USD",
          },
        ],
        design: {
          schema_version: 1,
          name: "资产汇总",
          family: "medium",
          theme: "system",
          layout: { id: "root", type: "column", children: [] },
        },
      }) +
      "\n```",
  );
  assert.equal(plan.name, "资产汇总");
  assert.equal(plan.list_path, "data");
  assert.equal(plan.fields[0].path, "total_usd");
  assert.equal(plan.url, undefined);
  assert.equal(plan.headers, undefined);
  assert.equal(plan.design.name, "资产汇总");
  assert.throws(() => parseSourceAssistant("{"), /有效 JSON/);
});
