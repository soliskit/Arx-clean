// Unit tests for the served pure-logic file. The browser loads this exact
// file from /logic.js; node --test loads it here through a fresh vm context,
// so the tested code is the code the browser runs. No browser or server.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import vm from "node:vm";

const root = new URL("..", import.meta.url).pathname;
const logicPath = join(root, "BridgeCore", "Web", "logic.js");
const logicSource = readFileSync(logicPath, "utf8");
const context = vm.createContext({});
vm.runInContext(logicSource, context, { filename: "logic.js" });
const ArxLogic = context.ArxLogic;

test("logic.js stays pure: no DOM, network or timers", () => {
  assert.doesNotMatch(
    logicSource,
    /\bdocument\b|\bwindow\b|\bfetch\b|setInterval|setTimeout/,
  );
  for (const name of [
    "formatDate",
    "formatTime",
    "validSession",
    "validateAdvancedJSON",
  ]) {
    assert.equal(typeof ArxLogic[name], "function", name);
  }
});

test("formatDate pads month and day", () => {
  assert.equal(
    ArxLogic.formatDate({ year: 2026, month: 3, day: 7 }),
    "2026-03-07",
  );
  assert.equal(
    ArxLogic.formatDate({ year: 2026, month: 11, day: 17 }),
    "2026-11-17",
  );
});

test("formatTime pads hour and minute, and is empty without an hour", () => {
  assert.equal(ArxLogic.formatTime({ hour: 9, minute: 5 }), "09:05");
  assert.equal(ArxLogic.formatTime({ hour: 23, minute: 59 }), "23:59");
  assert.equal(ArxLogic.formatTime({ year: 2026, month: 3, day: 7 }), "");
  assert.equal(ArxLogic.formatTime({ minute: 5 }), "");
});

test("validSession accepts only the full session wire shape", () => {
  const valid = {
    csrf: "token",
    rights: { lists: ["a", "b"], read: true, manage: false, delete: true },
  };
  assert.equal(ArxLogic.validSession(valid), true);
  assert.equal(ArxLogic.validSession({ ...valid, extra: 1 }), true);
  assert.equal(ArxLogic.validSession({ ...valid, csrf: "" }), false);
  assert.equal(ArxLogic.validSession({ ...valid, csrf: 7 }), false);
  assert.equal(ArxLogic.validSession({ csrf: "token" }), false);
  assert.equal(
    ArxLogic.validSession({
      ...valid,
      rights: { ...valid.rights, lists: "a" },
    }),
    false,
  );
  assert.equal(
    ArxLogic.validSession({
      ...valid,
      rights: { ...valid.rights, lists: ["a", 1] },
    }),
    false,
  );
  assert.equal(
    ArxLogic.validSession({
      ...valid,
      rights: { lists: [], read: true, manage: false },
    }),
    false,
  );
  assert.equal(
    ArxLogic.validSession({ ...valid, rights: { ...valid.rights, manage: 1 } }),
    false,
  );
  assert.equal(ArxLogic.validSession(null), false);
  assert.equal(ArxLogic.validSession(undefined), false);
  assert.equal(ArxLogic.validSession("session"), false);
});

test("validateAdvancedJSON accepts well-formed wire shapes", () => {
  ArxLogic.validateAdvancedJSON([], []);
  ArxLogic.validateAdvancedJSON([{ relativeOffset: -900 }], []);
  ArxLogic.validateAdvancedJSON([{ absoluteDate: "2030-01-15T09:30:00Z" }], []);
  ArxLogic.validateAdvancedJSON(
    [{ absoluteDate: "2030-01-15T09:30:00+05:30" }],
    [],
  );
  ArxLogic.validateAdvancedJSON(
    [
      {
        latitude: 37.7,
        longitude: -122.4,
        radius: 100,
        proximity: "enter",
        label: "Home",
      },
    ],
    [],
  );
  ArxLogic.validateAdvancedJSON([], [{ frequency: "daily", interval: 1 }]);
  ArxLogic.validateAdvancedJSON(
    [],
    [
      {
        frequency: "weekly",
        interval: 2,
        daysOfWeek: [{ day: 2, week: 1 }],
        count: 4,
      },
    ],
  );
  ArxLogic.validateAdvancedJSON(
    [],
    [
      {
        frequency: "yearly",
        interval: 1,
        endDate: "2031-12-31T23:59:59Z",
        daysOfMonth: [1, 15],
        calendarIdentifier: "cal",
      },
    ],
  );
  // Unknown extra keys are part of the settled wire contract.
  ArxLogic.validateAdvancedJSON(
    [{ relativeOffset: -900, futureKey: true }],
    [],
  );
});

test("validateAdvancedJSON refuses malformed wire shapes before anything is sent", () => {
  const message = /Nothing was sent or changed/;
  const bad = [
    [null, []],
    [[], null],
    [[null], []],
    [["alarm"], []],
    [[{ relativeOffset: "-900" }], []],
    [[{ absoluteDate: "not-a-date" }], []],
    [[{ absoluteDate: "2030-02-31T12:00:00Z" }], []],
    [[{ absoluteDate: "2030-01-01T24:00:00Z" }], []],
    [[{ absoluteDate: "2030-01-01T12:00:00+24:00" }], []],
    [[{ proximity: 3 }], []],
    [[], [{ interval: 1 }]],
    [[], [{ frequency: "daily" }]],
    [[], [{ frequency: "daily", interval: 1.5 }]],
    [[], [{ frequency: "daily", interval: 1, count: "3" }]],
    [[], [{ frequency: "daily", interval: 1, daysOfWeek: [{ day: 2 }] }]],
    [[], [{ frequency: "daily", interval: 1, daysOfMonth: ["1"] }]],
    [
      [],
      [{ frequency: "daily", interval: 1, endDate: "2031-13-01T00:00:00Z" }],
    ],
  ];
  for (const [alarms, repeats] of bad) {
    assert.throws(
      () => ArxLogic.validateAdvancedJSON(alarms, repeats),
      message,
      JSON.stringify([alarms, repeats]),
    );
  }
});

test("the page and server actually serve the tested logic file", () => {
  const index = readFileSync(
    join(root, "BridgeCore", "Web", "index.html"),
    "utf8",
  );
  const logicTag = index.indexOf('<script src="/logic.js"');
  const appTag = index.indexOf('<script src="/app.js"');
  assert.ok(logicTag !== -1, "index.html must load /logic.js");
  assert.ok(appTag !== -1, "index.html must load /app.js");
  assert.ok(logicTag < appTag, "logic.js must load before app.js");
  const server = readFileSync(
    join(root, "BridgeCore", "BridgeServer.swift"),
    "utf8",
  );
  assert.match(
    server,
    /"\/logic\.js":\s*"text\/javascript/,
    "BridgeServer must route and serve /logic.js as JavaScript",
  );
  const app = readFileSync(join(root, "BridgeCore", "Web", "app.js"), "utf8");
  assert.doesNotMatch(
    app,
    /const formatDate =|function validSession|function validateAdvancedJSON/,
    "app.js must use the served ArxLogic copy, not a private duplicate",
  );
});
