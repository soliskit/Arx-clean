"use strict";
// Pure wire-shape and date logic shared by the page and the Node test runner.
// The served file is the same file node --test loads, so tests cover the code
// the browser actually runs. Keep this file free of DOM, network and timers.
// The IIFE keeps the helpers out of the global lexical scope: app.js is a
// separate classic script and redeclares these names from ArxLogic.
(() => {
  const formatDate = (d) =>
    [
      d.year,
      String(d.month).padStart(2, "0"),
      String(d.day).padStart(2, "0"),
    ].join("-");
  const formatTime = (d) =>
    d.hour === undefined
      ? ""
      : [
          String(d.hour).padStart(2, "0"),
          String(d.minute).padStart(2, "0"),
        ].join(":");
  function validSession(state) {
    return (
      typeof state?.csrf === "string" &&
      state.csrf.length > 0 &&
      Array.isArray(state.rights?.lists) &&
      state.rights.lists.every((id) => typeof id === "string") &&
      ["read", "manage", "delete"].every(
        (key) => typeof state.rights[key] === "boolean",
      )
    );
  }
  // Validate wire shapes before sending, not native recurrence semantics or ranges.
  // An unidentifiable malformed wire replay must still keep the server's unknown outcome.
  function validateAdvancedJSON(alarms, repeats) {
    const object = (v) =>
      v !== null && typeof v === "object" && !Array.isArray(v);
    const number = (v) => typeof v === "number" && Number.isFinite(v);
    const integer = (v) => Number.isSafeInteger(v);
    const string = (v) => typeof v === "string";
    const date = (v) => {
      if (!string(v)) {
        return false;
      }
      const parts =
        /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|[+-](\d{2}):(\d{2}))$/.exec(
          v,
        );
      return (
        parts !== null &&
        Number.isFinite(Date.parse(v)) &&
        Number(parts[2]) < 24 &&
        Number(parts[3]) < 60 &&
        Number(parts[4]) < 60 &&
        (parts[5] === "Z" ||
          (Number(parts[6]) < 24 && Number(parts[7]) < 60)) &&
        new Date(parts[1]).toISOString().startsWith(parts[1])
      );
    };
    const optional = (v, check) => v === undefined || v === null || check(v);
    const validAlarm = (v) =>
      object(v) &&
      ["relativeOffset", "latitude", "longitude", "radius"].every((k) =>
        optional(v[k], number),
      ) &&
      ["proximity", "label"].every((k) => optional(v[k], string)) &&
      optional(v.absoluteDate, date);
    const validRepeat = (v) =>
      object(v) &&
      string(v.frequency) &&
      integer(v.interval) &&
      ["count", "firstDayOfWeek"].every((k) => optional(v[k], integer)) &&
      optional(v.calendarIdentifier, string) &&
      optional(v.endDate, date) &&
      [
        "daysOfMonth",
        "monthsOfYear",
        "weeksOfYear",
        "daysOfYear",
        "positions",
      ].every((k) =>
        optional(v[k], (a) => Array.isArray(a) && a.every(integer)),
      ) &&
      optional(
        v.daysOfWeek,
        (a) =>
          Array.isArray(a) &&
          a.every((d) => object(d) && integer(d.day) && integer(d.week)),
      );
    if (
      !Array.isArray(alarms) ||
      !Array.isArray(repeats) ||
      !alarms.every(validAlarm) ||
      !repeats.every(validRepeat)
    ) {
      throw Error(
        "Check the alarm and repeat JSON field types and required keys. Nothing was sent or changed.",
      );
    }
  }
  globalThis.ArxLogic = {
    formatDate,
    formatTime,
    validSession,
    validateAdvancedJSON,
  };
})();
