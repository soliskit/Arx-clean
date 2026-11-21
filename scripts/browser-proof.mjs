// Fixture-only HTTPS/browser qualification. No real Reminders or tunnel account.
import { spawn, execFileSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  writeFileSync,
  existsSync,
  mkdirSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import https from "node:https";
import http from "node:http";
import assert from "node:assert/strict";
import { checkBrowserOutcomes } from "./browser-outcomes.mjs";
import { checkBrowserEdits } from "./browser-edits.mjs";
import { checkBrowserInput } from "./browser-input.mjs";
import { startupDiagnostics } from "./browser-startup.mjs";
const temporary = mkdtempSync(join(tmpdir(), "arx-fixture-"));
const evidence = resolve(process.argv[3] || "browser-evidence");
mkdirSync(evidence, { recursive: true });
const chrome =
  process.env.CHROME_PATH ||
  (process.platform === "darwin"
    ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    : "/usr/bin/chromium");
let proxy, browser, server, ws, send, primaryError, cleanupError;
let logs = "";
// Browser-side errors surface in failure.txt; the fixture server logs only at
// critical level, so a page error is otherwise invisible in the evidence.
let browserLog = "";
let startup;
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const poll = async (check, attempts = 100) => {
  if (await check()) {
    return true;
  }
  if (attempts <= 1) {
    return false;
  }
  await wait(100);
  return poll(check, attempts - 1);
};
const exited = (child) => child.exitCode !== null || child.signalCode !== null;
const waitForExit = (child, milliseconds) =>
  new Promise((resolveExit) => {
    if (exited(child)) {
      resolveExit(true);
      return;
    }
    let timer = null;
    let onExit = null;
    const finish = (didExit) => {
      clearTimeout(timer);
      child.removeListener("exit", onExit);
      resolveExit(didExit);
    };
    onExit = () => finish(true);
    timer = setTimeout(() => finish(false), milliseconds);
    child.once("exit", onExit);
  });
const stopChild = async (child, allowGracefulExit = false) => {
  if (!child || child.pid === undefined || exited(child)) {
    return;
  }
  if (allowGracefulExit && (await waitForExit(child, 3000))) {
    return;
  }
  child.kill("SIGTERM");
  if (await waitForExit(child, 3000)) {
    return;
  }
  child.kill("SIGKILL");
  if (!(await waitForExit(child, 3000))) {
    throw Error("Fixture child did not exit after SIGKILL");
  }
};
const requestBrowserClose = () =>
  new Promise((resolveClose) => {
    const timer = setTimeout(resolveClose, 3000);
    send("Browser.close").then(
      () => {
        clearTimeout(timer);
        resolveClose();
      },
      () => {
        clearTimeout(timer);
        resolveClose();
      },
    );
  });
try {
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      join(temporary, "key.pem"),
      "-out",
      join(temporary, "cert.pem"),
      "-days",
      "1",
      "-subj",
      "/CN=bridge.example.test",
      "-addext",
      "subjectAltName=DNS:bridge.example.test",
    ],
    { stdio: "ignore" },
  );
  const binary = resolve(process.argv[2]);
  server = spawn(
    binary,
    ["https://bridge.example.test:19443", temporary, "18766"],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  server.stdout.on("data", (x) => {
    logs += x;
  });
  server.stderr.on("data", (x) => {
    logs += x;
  });
  await poll(() => {
    if (server.exitCode !== null) {
      throw Error(`Fixture process exited: ${logs}`);
    }
    return existsSync(join(temporary, "ready"));
  });
  const secret = readFileSync(join(temporary, "pairing"), "utf8");
  proxy = https.createServer(
    {
      key: readFileSync(join(temporary, "key.pem")),
      cert: readFileSync(join(temporary, "cert.pem")),
    },
    (req, res) => {
      const headers = {
        ...req.headers,
        host: "bridge.example.test:19443",
        "x-forwarded-proto": "https",
      };
      const upstream = http.request(
        {
          hostname: "127.0.0.1",
          port: 18766,
          path: req.url,
          method: req.method,
          headers,
        },
        (r) => {
          res.writeHead(r.statusCode, r.headers);
          r.pipe(res);
        },
      );
      upstream.on("error", () => {
        res.writeHead(503);
        res.end("{}");
      });
      req.pipe(upstream);
    },
  );
  await new Promise((r) => proxy.listen(19443, "127.0.0.1", r));
  startup = startupDiagnostics(chrome, temporary);
  startup.mark("spawn-request");
  browser = spawn(
    chrome,
    [
      "--headless=new",
      "--no-sandbox",
      "--ignore-certificate-errors",
      "--no-proxy-server",
      "--host-resolver-rules=MAP bridge.example.test 127.0.0.1",
      "--remote-debugging-port=0",
      `--user-data-dir=${join(temporary, "chrome")}`,
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  let launchError, exitStatus;
  let chromeStderr = Buffer.alloc(0);
  browser.on("spawn", () => startup.mark("spawn"));
  browser.on("error", (error) => {
    startup.mark("launch-error");
    launchError = error;
  });
  browser.on("exit", (code, signal) => {
    startup.mark("exit", { code, signal });
    exitStatus = { code, signal };
  });
  browser.stderr.on("data", (chunk) => {
    chromeStderr = Buffer.concat([chromeStderr, chunk]).subarray(-8192);
  });
  const startupFailure = (reason) =>
    Error(
      `Fixture Chrome ${reason}; launch error: ${launchError?.message || "none"}; exit: ${JSON.stringify(exitStatus || null)}; stderr (latest 8 KiB):\n${chromeStderr.toString("utf8")}`,
    );
  const active = join(temporary, "chrome", "DevToolsActivePort");
  // Chrome cold starts on hosted runners have been observed between ~4s and
  // past the original 10s window with identical code and runner images, so
  // the readiness window is 30s. Every assertion after startup is unchanged.
  await poll(() => {
    if (launchError) {
      throw startupFailure("launch failed");
    }
    if (exitStatus) {
      throw startupFailure("exited before readiness");
    }
    return existsSync(active);
  }, 300);
  if (launchError) {
    throw startupFailure("launch failed");
  }
  if (exitStatus) {
    throw startupFailure("exited before readiness");
  }
  if (!existsSync(active)) {
    startup.mark("readiness-timeout", {
      debuggingFile: false,
      connectionAnswered: false,
    });
    throw startupFailure("readiness timed out");
  }
  startup.mark("debugging-file", { debuggingFile: true });
  const port = readFileSync(active, "utf8").split("\n")[0];
  const targets = await (
    await fetch(`http://127.0.0.1:${port}/json/list`)
  ).json();
  startup.mark("debugging-connection", { connectionAnswered: true });
  ws = new WebSocket(
    targets.find((t) => t.type === "page").webSocketDebuggerUrl,
  );
  await new Promise((r, j) => {
    ws.addEventListener("open", r, { once: true });
    ws.addEventListener("error", j, { once: true });
  });
  let serial = 0;
  const pending = new Map();
  ws.addEventListener("message", (event) => {
    const m = JSON.parse(event.data);
    if (m.id && pending.has(m.id)) {
      const { r, j } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? j(Error(JSON.stringify(m.error))) : r(m.result);
    } else if (m.method === "Runtime.exceptionThrown") {
      browserLog += `exception: ${m.params.exceptionDetails?.exception?.description || m.params.exceptionDetails?.text}\n`;
    } else if (
      m.method === "Runtime.consoleAPICalled" &&
      m.params.type === "error"
    ) {
      browserLog += `console.error: ${m.params.args.map((a) => a.value ?? a.description ?? a.type).join(" ")}\n`;
    }
  });
  send = (method, params = {}) =>
    new Promise((r, j) => {
      const id = ++serial;
      pending.set(id, { r, j });
      ws.send(JSON.stringify({ id, method, params }));
    });
  const evaluate = async (expression) => {
    const result = await send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (result.exceptionDetails) {
      throw Error(JSON.stringify(result.exceptionDetails));
    }
    return result.result.value;
  };
  const until = async (expression) => {
    if (!(await poll(() => evaluate(expression)))) {
      throw Error(`Browser condition timed out: ${expression}`);
    }
  };
  const enabled = async () => {
    await until("!busy");
    assert.equal(
      await evaluate(
        '[...document.querySelectorAll("#reminders button")].some(b=>b.disabled)',
      ),
      false,
    );
  };
  const screenshot = async (name) => {
    const { data } = await send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: true,
    });
    writeFileSync(join(evidence, `${name}.png`), Buffer.from(data, "base64"));
  };
  await send("Page.enable");
  await send("Runtime.enable");
  await send("Page.addScriptToEvaluateOnNewDocument", {
    source: `const originalInterval = window.setInterval.bind(window);
      window.setInterval = (callback, delay, ...args) => {
        if (delay === 30000) window.fixtureHeartbeat = callback;
        return originalInterval(callback, delay, ...args);
      };`,
  });
  await send("Page.navigate", { url: "https://bridge.example.test:19443/" });
  await until('document.getElementById("secret")!==null');
  await until(
    'document.getElementById("status").textContent.includes("Pair this browser")',
  );
  assert.equal(
    await evaluate(
      'document.body.textContent.includes("Return the library book")',
    ),
    false,
  );
  await screenshot("01-unpaired");
  await evaluate(
    `document.getElementById("secret").value=${JSON.stringify(secret)};document.getElementById("pair-form").requestSubmit()`,
  );
  await until('!document.getElementById("workspace").hidden');
  const cookie = await send("Network.getCookies", {
    urls: ["https://bridge.example.test:19443/"],
  });
  assert.ok(
    cookie.cookies.some(
      (c) =>
        c.name === "__Host-arx" &&
        c.httpOnly &&
        c.secure &&
        c.sameSite === "Strict",
    ),
  );
  assert.equal(await evaluate('document.cookie.includes("__Host-arx")'), false);
  assert.equal(
    await evaluate(
      "Object.keys(localStorage).length+Object.keys(sessionStorage).length",
    ),
    0,
  );
  await evaluate(
    '[...document.querySelectorAll("#lists button")].find(b=>b.textContent==="Inbox").click()',
  );
  await until(
    'document.getElementById("reminders").textContent.includes("Return the library book")',
  );
  await enabled();
  await screenshot("02-selected-list");
  await evaluate(
    '[...document.querySelectorAll("#lists button")].find(b=>b.textContent==="Paged fixture").click()',
  );
  await until("!busy && rows.length===100");
  assert.equal(
    await evaluate('document.getElementById("previous").disabled'),
    true,
  );
  await evaluate('document.getElementById("next").click()');
  await until("!busy && rows.length===5");
  assert.equal(
    await evaluate('document.getElementById("next").disabled'),
    true,
  );
  await screenshot("02b-last-page");
  await evaluate('document.getElementById("previous").click()');
  await until("!busy && rows.length===100");
  await evaluate(
    '[...document.querySelectorAll("#lists button")].find(b=>b.textContent==="Inbox").click()',
  );
  await until(
    '!busy && document.getElementById("reminders").textContent.includes("Return the library book")',
  );
  // Every card action button names its reminder (#27).
  assert.ok(
    await evaluate(
      '[...document.querySelectorAll("#reminders article")].every(a=>{const t=a.querySelector("h3").textContent.replace(/^\u2713 /,"");return [...a.querySelectorAll(".actions button")].every(b=>(b.getAttribute("aria-label")||"").endsWith(" "+t));})',
    ),
  );
  // Use the app's own UI to create, edit, complete/reopen and delete fixture data.
  await evaluate('document.getElementById("new").click()');
  await until('!busy && !document.getElementById("editor").hidden');
  await evaluate(
    'document.getElementById("title").value="<img src=x onerror=alert(1)>";document.getElementById("notes").value="Safe text";document.getElementById("edit-form").requestSubmit()',
  );
  await until(
    'document.getElementById("reminders").textContent.includes("<img src=x onerror=alert(1)>")',
  );
  assert.equal(
    await evaluate('document.querySelectorAll("#reminders img").length'),
    0,
  );
  await enabled();
  await screenshot("03-escaped-reminder");
  const findCard =
    '[...document.querySelectorAll("#reminders article")].find(n=>n.textContent.includes("<img src=x onerror=alert(1)>"))';
  await evaluate(`${findCard}.querySelector("button").click()`);
  await until('!document.getElementById("editor").hidden');
  await screenshot("04-editor");
  await evaluate(
    'document.getElementById("notes").value="Edited fixture notes";document.getElementById("edit-form").requestSubmit()',
  );
  await until(
    'document.getElementById("reminders").textContent.includes("Edited fixture notes")',
  );
  assert.equal(
    await evaluate("document.activeElement?.dataset?.action"),
    "edit",
  );
  const clickAction = async (label) => {
    await enabled();
    return evaluate(
      `[...${findCard}.querySelectorAll("button")].find(b=>b.textContent===${JSON.stringify(label)}).click()`,
    );
  };
  await clickAction("Complete");
  await until(`${findCard}.querySelector("h3").textContent.startsWith("✓")`);
  await clickAction("Reopen");
  await until(`!${findCard}.querySelector("h3").textContent.startsWith("✓")`);
  await clickAction("Move");
  await until(
    '!document.getElementById("reminders").textContent.includes("<img src=x onerror=alert(1)>")',
  );
  await evaluate(
    '[...document.querySelectorAll("#lists button")].find(b=>b.textContent==="Weekend").click()',
  );
  await until(
    'document.getElementById("reminders").textContent.includes("Edited fixture notes")',
  );
  await screenshot("05-moved-fixture");
  // A refused save keeps the editor open with the entered values and the reason (#24).
  await clickAction("Edit");
  await until('!document.getElementById("editor").hidden');
  await evaluate(
    'document.getElementById("due-date").value="2027-01-15";document.getElementById("due-time").value="09:00";document.getElementById("timezone").value="Mars/Olympus_Mons";document.getElementById("edit-form").requestSubmit()',
  );
  await until(
    'document.getElementById("editor-error") && !document.getElementById("editor-error").hidden',
  );
  assert.equal(
    await evaluate('document.getElementById("editor").hidden'),
    false,
  );
  assert.equal(
    await evaluate('document.getElementById("title").value'),
    "<img src=x onerror=alert(1)>",
  );
  assert.match(
    await evaluate('document.getElementById("editor-error").textContent'),
    /Nothing was changed/,
  );
  await screenshot("06-refused-keeps-editor");
  await evaluate('document.getElementById("cancel-edit").click()');
  await until('document.getElementById("editor").hidden');
  assert.equal(
    await evaluate("document.activeElement?.dataset?.action"),
    "edit",
  );
  const dialogs = [];
  ws.addEventListener("message", (event) => {
    const m = JSON.parse(event.data);
    if (m.method === "Page.javascriptDialogOpening") {
      dialogs.push(m.params.type);
      send("Page.handleJavaScriptDialog", { accept: false });
    }
  });
  await clickAction("Delete");
  await until('document.querySelector(".dialog-backdrop")');
  // The backdrop covers the live viewport (full-page captures clip fixed layers).
  const cover = await evaluate(
    '(()=>{const r=document.querySelector(".dialog-backdrop").getBoundingClientRect();return {top:r.top,left:r.left,w:r.width,h:r.height,iw:innerWidth,ih:innerHeight};})()',
  );
  assert.equal(cover.top, 0);
  assert.equal(cover.left, 0);
  assert.ok(cover.h >= cover.ih, JSON.stringify(cover));
  // A fixed layer stops at the classic scrollbar track; the strip is browser chrome.
  assert.ok(cover.w >= cover.iw - 20, JSON.stringify(cover));
  await screenshot("07-delete-confirmation");
  // A mistyped confirmation explains itself and deletes nothing (#26).
  await evaluate(
    'document.getElementById("delete-confirmation").value="Wrong title"',
  );
  await evaluate(
    '[...document.querySelectorAll(".dialog-backdrop button")].find(b=>b.textContent==="Delete reminder").click()',
  );
  await until(
    'document.querySelector(".dialog-backdrop .error") && !document.querySelector(".dialog-backdrop .error").hidden',
  );
  await screenshot("08-delete-mismatch");
  assert.ok(
    await evaluate(
      'document.getElementById("reminders").textContent.includes("Edited fixture notes")',
    ),
  );
  // The page behind the modal is inert, Tab wraps inside it, and Cancel
  // returns focus to the Delete button that opened it (#26/#27).
  assert.equal(await evaluate('document.querySelector("main").inert'), true);
  await evaluate(
    '(()=>{const b=[...document.querySelectorAll(".dialog-backdrop button")];b.at(-1).focus();document.querySelector(".dialog-backdrop").dispatchEvent(new KeyboardEvent("keydown",{key:"Tab",bubbles:true}));})()',
  );
  assert.equal(
    await evaluate("document.activeElement?.id"),
    "delete-confirmation",
  );
  await evaluate(
    'document.querySelector(".dialog-backdrop").dispatchEvent(new KeyboardEvent("keydown",{key:"Tab",shiftKey:true,bubbles:true}))',
  );
  assert.equal(
    await evaluate("document.activeElement?.textContent"),
    "Delete reminder",
  );
  await evaluate(
    '[...document.querySelectorAll(".dialog-backdrop button")].find(b=>b.textContent==="Cancel").click()',
  );
  assert.equal(await evaluate('document.querySelector("main").inert'), false);
  assert.equal(
    await evaluate("document.activeElement?.dataset?.action"),
    "delete",
  );
  // The exact title confirms; the textarea represents any title, line breaks included.
  await clickAction("Delete");
  await until('document.querySelector(".dialog-backdrop")');
  await evaluate(
    `document.getElementById("delete-confirmation").value=${JSON.stringify("<img src=x onerror=alert(1)>")}`,
  );
  await evaluate(
    '[...document.querySelectorAll(".dialog-backdrop button")].find(b=>b.textContent==="Delete reminder").click()',
  );
  await until(
    '!document.getElementById("reminders").textContent.includes("Edited fixture notes")',
  );
  assert.equal(await evaluate("document.activeElement?.id"), "new");
  assert.deepEqual(dialogs, []);
  await checkBrowserInput({ evaluate, until, send, screenshot });
  await checkBrowserEdits({ evaluate, until, screenshot });
  await checkBrowserOutcomes({ evaluate, until, screenshot });
  const csrfDenied = await evaluate(
    'fetch("/api/read",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({listID})}).then(r=>r.status)',
  );
  assert.equal(csrfDenied, 403);
  await evaluate('csrf="";api("/api/read",{listID}).catch(()=>{})');
  assert.equal(
    await evaluate('document.getElementById("pairing").hidden'),
    true,
  );
  await evaluate(
    `openEditor(null);el("title").value="Private denied title";el("notes").value="Private denied notes";el("advanced-warning").textContent="Private warning";`,
  );
  await send("Network.clearBrowserCookies");
  await evaluate('api("/api/session").catch(()=>{})');
  await until('document.getElementById("pairing").hidden===false');
  assert.deepEqual(
    await evaluate(
      '({title:el("title").value,notes:el("notes").value,heading:el("list-title").textContent,warning:el("advanced-warning").textContent,editing})',
    ),
    {
      title: "",
      notes: "",
      heading: "Choose a list",
      warning: "",
      editing: null,
    },
  );
  await screenshot("06-denied-cleared");
  const noneSecret = readFileSync(join(temporary, "pairing-none"), "utf8");
  await evaluate(
    `el("secret").value=${JSON.stringify(noneSecret)};el("pair-form").requestSubmit()`,
  );
  await until('!busy && !el("workspace").hidden');
  assert.equal(await evaluate('el("pairing").hidden'), true);
  assert.equal(
    await evaluate('el("list-title").textContent'),
    "No lists shared",
  );
  assert.match(
    await evaluate('el("status").textContent'),
    /No lists or actions/,
  );
  await send("Page.reload");
  await until('document.getElementById("workspace")?.hidden===false');
  assert.equal(await evaluate('el("pairing").hidden'), true);
  assert.match(
    await evaluate('el("status").textContent'),
    /No lists or actions/,
  );
  assert.equal(await evaluate("lists.length"), 0);
  await screenshot("07-paired-no-access");
  await send("Network.clearBrowserCookies");
  await evaluate('api("/api/session").catch(()=>{})');
  await until('el("pairing").hidden===false');
  writeFileSync(
    join(evidence, "results.json"),
    JSON.stringify(
      {
        https: true,
        httpOnlySecureSameSite: true,
        noWebStorage: true,
        selectedList: true,
        pagination: true,
        create: true,
        edit: true,
        move: true,
        complete: true,
        reopen: true,
        delete: true,
        escapedText: true,
        csrfDenied: true,
        denialClearsPrivateUI: true,
      },
      null,
      2,
    ),
  );
  process.stdout.write(
    "HTTPS/browser fixture checks passed. No real account data used.\n",
  );
} catch (error) {
  primaryError = error;
  process.stderr.write(`${String(error)}\n`);
  writeFileSync(
    join(evidence, "failure.txt"),
    `${String(error)}\n${browserLog}${logs}`,
  );
} finally {
  startup?.write(join(evidence, "startup.json"));
  const cleanupFailures = [];
  try {
    if (send && ws?.readyState === WebSocket.OPEN) {
      await requestBrowserClose();
    }
    await stopChild(browser, true);
  } catch (error) {
    cleanupFailures.push(error);
  }
  ws?.close();
  try {
    await stopChild(server);
  } catch (error) {
    cleanupFailures.push(error);
  }
  try {
    if (proxy) {
      const closed = new Promise((resolveClose, rejectClose) =>
        proxy.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      proxy.closeAllConnections();
      await closed;
    }
  } catch (error) {
    cleanupFailures.push(error);
  }
  if (cleanupFailures.length === 0) {
    try {
      rmSync(temporary, {
        recursive: true,
        force: true,
        maxRetries: 10,
        retryDelay: 200,
      });
    } catch (error) {
      cleanupFailures.push(error);
    }
  }
  if (cleanupFailures.length) {
    cleanupError = new AggregateError(
      cleanupFailures,
      "Fixture cleanup failed",
    );
    process.stderr.write(`${String(cleanupError)}\n`);
    writeFileSync(
      join(evidence, "cleanup-failure.txt"),
      cleanupFailures.map(String).join("\n"),
    );
  }
}
if (primaryError && cleanupError) {
  throw new AggregateError(
    [primaryError, cleanupError],
    "Fixture assertion and cleanup both failed",
  );
}
if (cleanupError) {
  throw cleanupError;
}

if (primaryError) {
  throw primaryError;
}
