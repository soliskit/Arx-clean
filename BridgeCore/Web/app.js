"use strict";
let csrf = "",
  rights = null,
  lists = [],
  listID = "",
  rows = [],
  editing = null,
  busy = false,
  nextPage = null,
  previousPage = null;
const uncertainWrites = [];
let editorText = {};
const el = (id) => document.getElementById(id);
const text = (tag, value) => {
  const node = document.createElement(tag);
  node.textContent = value;
  return node;
};
// Pure logic is served separately by /logic.js so node --test can run it
// without a browser. index.html loads logic.js before this file.
const { formatDate, formatTime, validSession, validateAdvancedJSON } =
  globalThis.ArxLogic;
function setStatus(value) {
  const warnings = uncertainWrites
    .map(
      (failure) =>
        `At ${failure.at} a ${failure.action} did not confirm: ${failure.message}`,
    )
    .join(" ");
  el("status").textContent = warnings
    ? `${value} Unresolved writes: ${warnings} Check Reminders before repeating them.`
    : value;
}
function clear() {
  nextPage = null;
  previousPage = null;
  el("pages").hidden = true;
  csrf = "";
  rights = null;
  lists = [];
  rows = [];
  listID = "";
  editing = null;
  editorText = {};
  el("workspace").hidden = true;
  el("editor").hidden = true;
  el("edit-form").reset();
  el("list-title").textContent = "Choose a list";
  el("advanced-warning").textContent = "";
  el("pairing").hidden = false;
  el("secret").value = "";
  el("lists").replaceChildren();
  el("reminders").replaceChildren();
}
async function sessionAlive() {
  try {
    const probe = await fetch("/api/session", {
      credentials: "same-origin",
      cache: "no-store",
    });
    if (probe.ok) {
      return validSession(await probe.json()) ? "active" : "unknown";
    }
    return probe.status === 403 ? "denied" : "unknown";
  } catch {
    return "unknown";
  }
}
async function api(path, body) {
  const options = {
    credentials: "same-origin",
    cache: "no-store",
    headers: {},
  };
  if (body !== undefined) {
    options.method = "POST";
    options.headers = {
      "Content-Type": "application/json",
      "X-CSRF-Token": csrf,
    };
    options.body = JSON.stringify(body);
    if (
      path === "/api/mutate" &&
      new TextEncoder().encode(options.body).byteLength > 1_048_576
    ) {
      const failure = Error(
        "This reminder request exceeds 1 MiB, including its original copy. Shorten the notes.",
      );
      failure.writeOutcome = "refused"; // Nothing was sent for this new operation ID.
      throw failure;
    }
  }
  const response = await fetch(path, options);
  let result;
  try {
    result = await response.json();
  } catch {
    if (response.ok) {
      if (path === "/api/session") {
        clear();
      }
      throw Error(
        "Unexpected server response. Access could not be verified. Check the connector.",
      );
    }
    result = { error: "Unexpected server response. Check the connector." };
  }
  if (!response.ok) {
    let message = result?.error || "Request failed.";
    if (response.status === 403) {
      const session =
        path === "/api/session" || path === "/api/pair"
          ? "denied"
          : await sessionAlive();
      if (session !== "active") {
        clear();
        if (session === "unknown") {
          message =
            "Access could not be verified. Refresh to check your session before pairing again.";
        }
      } else {
        message =
          "That list or reminder is no longer available to this client. Refresh to review.";
      }
    }
    const failure = Error(message);
    failure.status = response.status;
    failure.code = result?.code;
    failure.writeOutcome = result?.writeOutcome;
    throw failure;
  }
  if (path === "/api/session" && !validSession(result)) {
    clear();
    throw Error(
      "Access could not be verified. The session response was invalid. Refresh before pairing again.",
    );
  }
  return result;
}
function pageControls() {
  el("next").disabled = busy || !nextPage;
  el("previous").disabled = busy || !previousPage;
}
function controlsBusy(value) {
  for (const button of document.querySelectorAll("button")) {
    button.disabled = value;
  }
  pageControls();
}
async function run(action) {
  if (busy) {
    setStatus(
      "Still working on the previous request. Nothing new was sent. Try again in a moment.",
    );
    return;
  }
  busy = true;
  controlsBusy(true);
  try {
    await action();
  } catch (error) {
    if (!error.reported) {
      setStatus(error.message);
    }
  } finally {
    busy = false;
    controlsBusy(false);
  }
}
function dateValue(name, original) {
  const date = el(`${name}-date`).value,
    time = el(`${name}-time`).value;
  if (!date) {
    if (time) {
      throw Error("A time needs its date.");
    }
    return undefined;
  }
  // Preserve a field's own timezone if its controls are unchanged.
  if (
    original &&
    date === formatDate(original) &&
    time === formatTime(original) &&
    el("timezone").value ===
      (editing?.fields.due?.timeZone ||
        editing?.fields.start?.timeZone ||
        Intl.DateTimeFormat().resolvedOptions().timeZone)
  ) {
    return original;
  }
  const [year, month, day] = date.split("-").map(Number),
    value = { year, month, day };
  if (time) {
    const [hour, minute] = time.split(":").map(Number);
    Object.assign(value, { hour, minute, timeZone: el("timezone").value });
  }
  return value;
}
let editorReturnFocus = null;
let lastInvoker = null;
let focusAfterRerender = false;
function editorError(message) {
  let line = el("editor-error");
  if (!line) {
    line = document.createElement("p");
    line.id = "editor-error";
    line.className = "error";
    line.setAttribute("role", "alert");
    el("save").insertAdjacentElement("beforebegin", line);
  }
  line.textContent = message || "";
  line.hidden = !message;
}
function restoreEditorFocus() {
  const target = editorReturnFocus?.itemId
    ? document.querySelector(
        `button[data-item-id="${CSS.escape(editorReturnFocus.itemId)}"][data-action="${editorReturnFocus.action}"]`,
      )
    : null;
  const button = target || el("new");
  // The click's busy pass disabled every button; this one is moments from re-enabling.
  button.disabled = false;
  button.focus();
}
function confirmDelete(item) {
  return new Promise((resolve) => {
    const title = item.fields.title;
    editorReturnFocus = lastInvoker?.dataset?.itemId
      ? {
          itemId: lastInvoker.dataset.itemId,
          action: lastInvoker.dataset.action,
        }
      : {};
    const overlay = document.createElement("div");
    overlay.className = "dialog-backdrop";
    const dialog = document.createElement("div");
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-modal", "true");
    dialog.setAttribute("aria-labelledby", "delete-heading");
    const heading = text("h2", "Delete this reminder?");
    heading.id = "delete-heading";
    dialog.append(heading);
    const context = document.createElement("div");
    context.className = "delete-context";
    context.append(text("h3", title));
    if (item.fields.due) {
      context.append(
        text(
          "p",
          `Due: ${formatDate(item.fields.due)}${item.fields.due.hour === undefined ? "" : ` ${formatTime(item.fields.due)}`}`,
        ),
      );
    }
    if (item.fields.notes) {
      context.append(text("p", item.fields.notes));
    }
    dialog.append(context);
    if (item.fields.repeats.length) {
      const note = text(
        "p",
        "This reminder repeats. EventKit controls the resulting recurrence behavior; review Reminders afterward.",
      );
      note.className = "hint";
      dialog.append(note);
    }
    const label = text(
      "label",
      "Type the reminder title exactly to confirm deletion.",
    );
    label.setAttribute("for", "delete-confirmation");
    dialog.append(label);
    const input = document.createElement("textarea");
    input.id = "delete-confirmation";
    input.rows = 2;
    input.autocomplete = "off";
    dialog.append(input);
    const error = text("p", "");
    error.className = "error";
    error.setAttribute("role", "alert");
    error.hidden = true;
    dialog.append(error);
    const buttons = document.createElement("div");
    buttons.className = "actions";
    const cancel = text("button", "Cancel");
    cancel.type = "button";
    const confirm = text("button", "Delete reminder");
    confirm.type = "button";
    confirm.className = "danger";
    buttons.append(cancel, confirm);
    dialog.append(buttons);
    overlay.append(dialog);
    const close = (value) => {
      for (const sibling of document.body.children) {
        sibling.inert = false;
      }
      overlay.remove();
      restoreEditorFocus();
      // A confirmed delete rerenders the list; restore again once it lands.
      focusAfterRerender = value !== null;
      resolve(value);
    };
    cancel.addEventListener("click", () => close(null));
    overlay.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        close(null);
        return;
      }
      if (event.key === "Tab") {
        const focusable = [...dialog.querySelectorAll("textarea, button")];
        const first = focusable[0];
        const last = focusable[focusable.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      }
    });
    confirm.addEventListener("click", () => {
      if (input.value === title) {
        close(input.value);
      } else {
        error.textContent = "The title does not match. Nothing was deleted.";
        error.hidden = false;
        input.focus();
      }
    });
    for (const sibling of document.body.children) {
      sibling.inert = true;
    }
    document.body.append(overlay);
    input.focus();
  });
}
function openEditor(item) {
  const invoker = lastInvoker;
  editorReturnFocus = invoker?.dataset?.itemId
    ? { itemId: invoker.dataset.itemId, action: invoker.dataset.action }
    : {};
  editing = item;
  editorError("");
  const f = item?.fields || { title: "", priority: 0, alarms: [], repeats: [] };
  for (const name of ["title", "notes", "url", "location"]) {
    el(name).value = f[name] || "";
    editorText[name] = el(name).value;
  }
  el("priority").value = String(f.priority);
  el("timezone").value =
    f.due?.timeZone ||
    f.start?.timeZone ||
    Intl.DateTimeFormat().resolvedOptions().timeZone;
  for (const name of ["start", "due"]) {
    const date = f[name] ? formatDate(f[name]) : "";
    const time = f[name] ? formatTime(f[name]) : "";
    el(`${name}-date`).value = date;
    el(`${name}-time`).value = time;
    // Observed in WebKit: after one programmatic clear of a real date/time
    // value the form's validity stays stale and blocks the submit event;
    // clearing again makes validity consistent and lets the submit dispatch.
    if (!date) {
      el(`${name}-date`).value = "";
    }
    if (!time) {
      el(`${name}-time`).value = "";
    }
  }
  el("alarms").value = JSON.stringify(f.alarms, null, 2);
  el("repeats").value = JSON.stringify(f.repeats, null, 2);
  el("advanced-warning").textContent = item?.unsupportedAlarms
    ? "This reminder has unsupported alarm actions. Leave alarms unchanged."
    : "";
  el("edit-heading").textContent = item ? "Edit reminder" : "New reminder";
  el("save").textContent = item ? "Save changes" : "Create reminder";
  el("editor").hidden = false;
  el("title").focus();
}
async function mutate(action, item, extra, reload) {
  const command = {
    operationID: crypto.randomUUID(),
    action,
    listID,
    itemID: item?.id,
    base: item,
    ...extra,
  };
  let result;
  try {
    result = await api("/api/mutate", command);
  } catch (error) {
    const refused = error.writeOutcome === "refused";
    const committed = error.writeOutcome === "committed";
    if (!refused) {
      el("editor").hidden = true;
      restoreEditorFocus();
    }
    if (!refused && !committed) {
      uncertainWrites.push({
        at: new Date().toLocaleTimeString(),
        action,
        message: error.message,
      });
    }
    let message = `${error.message} This ${action} may or may not have been saved. Check Reminders before repeating it.`;
    if (refused) {
      message = `${error.message} Nothing was changed.`;
    }
    if (committed) {
      message = `Change saved, but the result could not be reloaded: ${error.message}`;
    }
    if (refused) {
      editorError(message);
      if (error.code === "sessionFull") {
        el("pairing").hidden = false;
      }
    }
    setStatus(message);
    error.reported = true;
    throw error;
  }
  try {
    await reload();
  } catch (error) {
    setStatus(
      `Change saved, but the list could not be reloaded: ${error.message}`,
    );
    error.reported = true;
    throw error;
  }
  const saved = result.reminder;
  setStatus(
    saved && saved.listID === listID && !rows.some((row) => row.id === saved.id)
      ? "Change saved. The reminder is in this list but not on the page shown."
      : "Change saved. Review the refreshed result.",
  );
}
async function load(cursor = {}, target = listID) {
  const page = await api("/api/read", { listID: target, ...cursor });
  // Switch lists only once the new list has actually loaded.
  listID = target;
  for (const button of el("lists").children) {
    button.classList.toggle("selected", button.dataset.listId === listID);
  }
  rows = page.items;
  nextPage = page.next;
  previousPage = page.previous;
  el("pages").hidden = false;
  pageControls();
  const editorWasOpen = !el("editor").hidden;
  el("editor").hidden = true;
  el("list-title").textContent =
    lists.find((l) => l.id === listID)?.title || "Selected list";
  el("new").hidden =
    !rights.manage || !lists.find((l) => l.id === listID)?.writable;
  const container = el("reminders");
  container.replaceChildren();
  if (!rows.length) {
    container.append(
      text(
        "p",
        nextPage || previousPage
          ? "No current reminders on this page. Continue or refresh."
          : "This list has no reminders.",
      ),
    );
  }
  for (const item of rows) {
    const card = document.createElement("article");
    card.className = "reminder";
    card.append(
      text("h3", (item.fields.completed ? "✓ " : "") + item.fields.title),
    );
    if (item.fields.notes) {
      card.append(text("p", item.fields.notes));
    }
    if (item.fields.due) {
      card.append(
        text(
          "p",
          `Due: ${formatDate(item.fields.due)}${item.fields.due.hour === undefined ? "" : ` ${formatTime(item.fields.due)}`}`,
        ),
      );
    }
    const actions = document.createElement("div");
    actions.className = "actions";
    const button = (
      label,
      action,
      danger = false,
      name = label.toLowerCase(),
    ) => {
      const b = text("button", label);
      b.type = "button";
      b.disabled = busy;
      b.className = danger ? "danger" : "";
      b.setAttribute("aria-label", `${label} ${item.fields.title}`);
      b.dataset.itemId = item.id;
      b.dataset.action = name;
      b.addEventListener("click", () => {
        lastInvoker = b;
        run(action);
      });
      actions.append(b);
    };
    const writable = lists.find((l) => l.id === listID)?.writable;
    if (rights.manage && writable) {
      button("Edit", () => openEditor(item));
      button(
        item.fields.completed ? "Reopen" : "Complete",
        () =>
          mutate(item.fields.completed ? "reopen" : "complete", item, {}, load),
        false,
        "complete",
      );
      const dest = document.createElement("select");
      dest.setAttribute("aria-label", `Move ${item.fields.title} to list`);
      for (const l of lists.filter(
        (candidate) => candidate.id !== listID && candidate.writable,
      )) {
        const option = text("option", l.title);
        option.value = l.id;
        dest.append(option);
      }
      if (dest.options.length) {
        actions.append(dest);
        button("Move", () =>
          mutate("move", item, { destination: dest.value }, load),
        );
      }
    }
    if (rights.delete && writable) {
      button(
        "Delete",
        async () => {
          const confirmation = await confirmDelete(item);
          if (confirmation !== null) {
            await mutate("delete", item, { confirmation }, load);
          }
        },
        true,
        "delete",
      );
    }
    card.append(actions);
    container.append(card);
  }
  if (editorWasOpen || focusAfterRerender) {
    restoreEditorFocus();
  }
  focusAfterRerender = false;
}
async function refresh() {
  const state = await api("/api/session");
  csrf = state.csrf;
  rights = state.rights;
  lists = rights.read ? await api("/api/lists") : [];
  el("workspace").hidden = false;
  el("pairing").hidden = true;
  el("editor").hidden = true;
  el("lists").replaceChildren();
  for (const list of lists) {
    const b = text(
      "button",
      list.title + (list.writable ? "" : " (read-only)"),
    );
    b.type = "button";
    b.dataset.listId = list.id;
    b.className = list.id === listID ? "selected" : "";
    b.addEventListener("click", () => run(() => load({}, list.id)));
    el("lists").append(b);
  }
  if (!lists.some((l) => l.id === listID)) {
    listID = "";
    rows = [];
    el("reminders").replaceChildren();
    el("list-title").textContent = lists.length
      ? "Choose a list"
      : "No lists shared";
    el("new").hidden = true;
    el("pages").hidden = true;
  } else {
    await load();
  }
  setStatus(
    rights.read
      ? "Connected. Only your granted lists and actions are shown."
      : "Connected. No lists or actions have been shared with this browser.",
  );
}
el("next").addEventListener("click", () =>
  run(() => load({ after: nextPage })),
);
el("previous").addEventListener("click", () =>
  run(() => load({ before: previousPage })),
);
el("pair-form").addEventListener("submit", (event) => {
  event.preventDefault();
  run(async () => {
    const secret = el("secret").value;
    el("secret").value = "";
    await api("/api/pair", { secret });
    await refresh();
  });
});
el("refresh").addEventListener("click", () => run(refresh));
el("forget").addEventListener("click", () => {
  clear();
  setStatus(
    "Page cleared. Revoke this client in the Mac app to end its session.",
  );
});
el("new").addEventListener("click", () => {
  lastInvoker = el("new");
  run(() => openEditor(null));
});
el("cancel-edit").addEventListener("click", () => {
  editing = null;
  el("editor").hidden = true;
  restoreEditorFocus();
});
el("edit-form").addEventListener("submit", (event) => {
  event.preventDefault();
  run(async () => {
    const f = structuredClone(editing?.fields || { completed: false });
    for (const name of ["title", "notes", "url", "location"]) {
      if (!editing || el(name).value !== editorText[name]) {
        f[name] = el(name).value || undefined;
      }
    }
    f.priority = Number(el("priority").value);
    f.start = dateValue("start", editing?.fields.start);
    f.due = dateValue("due", editing?.fields.due);
    f.alarms = JSON.parse(el("alarms").value);
    f.repeats = JSON.parse(el("repeats").value);
    validateAdvancedJSON(f.alarms, f.repeats);
    await mutate(editing ? "edit" : "create", editing, { fields: f }, load);
  });
});
setInterval(() => {
  if (rights && !busy) {
    api("/api/session").catch(() => {});
  }
}, 30000);
run(async () => {
  try {
    await refresh();
  } catch {
    clear();
    setStatus("Pair this browser from the Mac app to begin.");
  }
});
