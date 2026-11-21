import assert from "node:assert/strict";
import test from "node:test";
import { EventEmitter } from "node:events";
import { startupDiagnostics } from "./browser-startup.mjs";

const fixture = (changes = {}) => {
  let written;
  let time = 100;
  const recorder = startupDiagnostics("/fixture/chrome", "/fixture/temp", {
    realpath: () => "/fixture/resolved-chrome",
    version: () => "Chrome fixture 1",
    disk: () => ({ bavail: 4, bsize: 512 }),
    cpu: () => 2,
    memory: () => 4096,
    now: () => time++,
    write: (_path, value) => {
      written = value;
    },
    ...changes,
  });
  return { recorder, read: () => JSON.parse(written) };
};
for (const ending of [
  "ready",
  "launch-error",
  "early-exit",
  "readiness-timeout",
]) {
  test(`fake child startup ${ending}`, () => {
    const { recorder, read } = fixture();
    const child = new EventEmitter();
    child.on("spawn", () => recorder.mark("spawn"));
    child.on("error", () => recorder.mark("launch-error"));
    child.on("exit", (code, signal) => recorder.mark("exit", { code, signal }));
    recorder.mark("spawn-request");
    child.emit("spawn");
    if (ending === "launch-error") {
      child.emit("error", Error("must not disclose this"));
    }
    if (ending === "early-exit") {
      child.emit("exit", 1, null);
    }
    recorder.mark(ending, {
      debuggingFile: ending === "ready",
      connectionAnswered: ending === "ready",
    });
    assert.equal(recorder.write("/fixture/result"), true);
    const result = read();
    assert.equal(result.chromeVersion, "Chrome fixture 1");
    assert.equal(result.temporaryFreeBytes, 2048);
    assert.equal(result.events.at(-1).stage, ending);
    assert.ok(result.events.at(-1).milliseconds >= 0);
    assert.equal(JSON.stringify(result).includes("must not disclose"), false);
  });
}
test("diagnostic failures and size caps never mask original failure", () => {
  const { recorder, read } = fixture({
    version: () => {
      throw Error("private detail");
    },
  });
  recorder.mark("readiness-timeout", { debuggingFile: false });
  assert.equal(recorder.write("/fixture/result"), true);
  assert.equal(read().chromeVersion, "unknown");
  const unavailable = fixture({
    write: () => {
      throw Error("not writable");
    },
  });
  assert.equal(unavailable.recorder.write("/fixture/result"), false);
  const huge = fixture({ realpath: () => "x".repeat(20_000) });
  assert.equal(huge.recorder.write("/fixture/result"), false);
});
