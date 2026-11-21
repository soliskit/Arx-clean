// Synthetic browser regressions using the real fixture service. No native data.
import assert from "node:assert/strict";

export async function checkBrowserEdits({ evaluate, until, screenshot }) {
  await evaluate(`window.editFixture = { fetch: window.fetch.bind(window), commands: [] };
    window.fetch = (path, options) => {
      if (path === "/api/mutate") window.editFixture.commands.push(JSON.parse(options.body));
      return window.editFixture.fetch(path, options);
    };`);
  const submit = async (source) => {
    await evaluate(`${source};el("edit-form").requestSubmit()`);
    await until("!busy");
  };
  try {
    // Leave real values in the date/time controls before the edit below:
    // WebKit keeps a programmatically cleared date/time control invalid,
    // and saving an undated reminder must survive that engine state.
    await evaluate(`(async () => {
      await load({}, "inbox");
      openEditor(null);
      el("due-date").value = "2027-01-15";
      el("due-time").value = "09:00";
      el("cancel-edit").click();
    })()`);
    await evaluate(`(async () => {
      const value = await api("/api/mutate", { operationID: crypto.randomUUID(), action: "create", listID: "inbox",
        fields: { title: "Line one\\nLine two", location: "Room\\nB", notes: "first\\r\\nsecond",
          priority: 0, completed: false, alarms: [], repeats: [] } });
      window.editFixture.original = value.reminder;
      await load({}, "inbox"); openEditor(value.reminder);
    })()`);
    await submit('el("priority").value="5"');
    const preserved = await evaluate(
      "window.editFixture.commands.at(-1).fields",
    );
    assert.equal(preserved.title, "Line one\nLine two");
    assert.equal(preserved.location, "Room\nB");
    assert.equal(preserved.notes, "first\r\nsecond");
    assert.equal(preserved.priority, 5);
    await screenshot("05c-untouched-text-preserved");
    await evaluate(
      "openEditor(rows.find(row=>row.id===window.editFixture.original.id))",
    );
    const before = await evaluate(
      "({count:window.editFixture.commands.length,unknown:JSON.stringify(uncertainWrites)})",
    );
    const malformed = [
      ['[{"relativeOffset":"-900"}]', "[]"],
      ["[]", '[{"frequency":"daily"}]'],
      ["[null]", "[]"],
      ["[]", '[{"frequency":"daily","interval":1,"daysOfWeek":[{"day":2}]}]'],
      ['[{"absoluteDate":"not-a-date"}]', "[]"],
      ['[{"absoluteDate":"2030-02-31T12:00:00Z"}]', "[]"],
      ['[{"absoluteDate":"2030-01-01T24:00:00Z"}]', "[]"],
      ["[]", '[{"frequency":"daily","interval":1,"count":"3"}]'],
    ];
    const checkMalformed = async ([alarms, repeats]) => {
      await submit(
        `el("alarms").value=${JSON.stringify(alarms)};el("repeats").value=${JSON.stringify(repeats)}`,
      );
      assert.match(
        await evaluate('el("status").textContent'),
        /Nothing was sent or changed/,
      );
      assert.deepEqual(
        await evaluate(
          "({count:window.editFixture.commands.length,unknown:JSON.stringify(uncertainWrites)})",
        ),
        before,
      );
    };
    // Sequential saves deliberately exercise the same still-open editor.
    await malformed.reduce(
      (prior, value) => prior.then(() => checkMalformed(value)),
      Promise.resolve(),
    );
    await screenshot("05d-malformed-json-not-sent");
    // A time without its date is refused before sending and keeps the editor.
    // The status is cleared before each refusal so the fresh refusal text
    // proves the submit actually dispatched; leftover text cannot pass it.
    await submit(
      'el("status").textContent="";el("due-date").value="";el("due-time").value="09:00"',
    );
    assert.match(
      await evaluate('el("status").textContent'),
      /A time needs its date/,
    );
    assert.deepEqual(
      await evaluate(
        '({count:window.editFixture.commands.length,unknown:JSON.stringify(uncertainWrites),editorOpen:!el("editor").hidden})',
      ),
      { ...before, editorOpen: true },
    );
    // Direct programmatic clears leave WebKit's form validity stale and
    // silently block later submits. Reopening through the product path
    // re-asserts the empty controls, the verified restore, so the next
    // refusal and the final save really dispatch.
    await evaluate(
      "openEditor(rows.find(row=>row.id===window.editFixture.original.id))",
    );
    await submit(
      'el("status").textContent="";el("start-date").value="";el("start-time").value="17:30"',
    );
    assert.match(
      await evaluate('el("status").textContent'),
      /A time needs its date/,
    );
    assert.equal(
      await evaluate("window.editFixture.commands.length"),
      before.count,
    );
    await evaluate(
      "openEditor(rows.find(row=>row.id===window.editFixture.original.id))",
    );
    await submit(
      'el("alarms").value=\'[ {"relativeOffset":-900} ]\';el("repeats").value=\'[ {"frequency":"daily","interval":1} ]\';el("title").value="Changed text fixture";el("notes").value="";el("location").value=""',
    );
    const changed = await evaluate("window.editFixture.commands.at(-1).fields");
    assert.equal(changed.title, "Changed text fixture");
    assert.equal(changed.notes, undefined);
    assert.equal(changed.location, undefined);
    assert.equal(changed.alarms[0].relativeOffset, -900);
    assert.equal(changed.repeats[0].interval, 1);
    // Remove the final five rows between loading page one and following Next.
    await evaluate(`(async () => {
      await load({}, "pages");
      const tail = await api("/api/read", { listID, after: nextPage });
      await tail.items.reduce((prior, item) => prior.then(() => api("/api/mutate", {
        operationID: crypto.randomUUID(), action: "delete", listID, itemID: item.id,
        base: item, confirmation: item.fields.title })), Promise.resolve());
      el("next").click();
    })()`);
    await until("!busy && rows.length===100");
    assert.doesNotMatch(
      await evaluate('el("reminders").textContent'),
      /This list has no reminders/,
    );
    await screenshot("05e-deleted-tail-recovers");
    await evaluate('load({}, "inbox")');
  } finally {
    await evaluate(
      "window.fetch=window.editFixture.fetch;delete window.editFixture;",
    );
  }
}
