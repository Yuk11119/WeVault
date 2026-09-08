import test from "node:test";
import assert from "node:assert/strict";
import { runInNewContext } from "node:vm";
import { restoreScript } from "../src/restore-page.ts";

test("browser bridge validates fragments before exposing a native link and copies only the ID", async () => {
  for (const id of ["binding-" + "a".repeat(32), "binding-" + "b".repeat(64), "", "binding-" + "a".repeat(31), "binding-%61" + "a".repeat(31), "binding-" + "a".repeat(32) + "?path=/tmp", '<img src=x onerror="alert(1)">']) {
    const valid = /^binding-([a-f0-9]{32}|[a-f0-9]{64})$/.test(id);
    let copied: string | undefined;
    let click: (() => Promise<void>) | undefined;
    const elements: Record<string, { hidden?: boolean; value?: string; href?: string; textContent?: string; addEventListener?: (event: string, callback: () => Promise<void>) => void }> = {
      actions: { hidden: true }, binding: {}, open: {}, status: {}, copy: { addEventListener: (_event, callback) => { click = callback; } }
    };
    runInNewContext(restoreScript, { location: { hash: "#" + id }, document: { getElementById: (key: string) => elements[key] }, navigator: { clipboard: { writeText: async (text: string) => { copied = text; } } } });
    assert.equal(elements.actions!.hidden, !valid);
    assert.equal(elements.open!.href, valid ? "wevault://restore/" + id : undefined);
    if (valid) { await click!(); assert.equal(copied, id); }
    else { assert.equal(click, undefined); assert.equal(copied, undefined); }
  }
});
