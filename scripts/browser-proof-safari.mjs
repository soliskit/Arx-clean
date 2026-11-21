// Fixture-only Safari/WebDriver qualification. No real Reminders or tunnel account.
// Requires: safaridriver --enable (CI does it with sudo) and a hosts entry mapping
// bridge.example.test to 127.0.0.1. Mirrors the core Chrome fixture proof through
// the W3C WebDriver protocol instead of CDP.
import { spawn, execFileSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  writeFileSync,
  existsSync,
  mkdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import https from "node:https";
import http from "node:http";
import assert from "node:assert/strict";
import { checkBrowserOutcomes } from "./browser-outcomes.mjs";
import { checkBrowserEdits } from "./browser-edits.mjs";

const temporary = mkdtempSync(join(tmpdir(), "arx-safari-fixture-"));
const evidence = resolve(process.argv[3] || "safari-evidence");
mkdirSync(evidence, { recursive: true });
const driverPort = 4444;
let proxy, server, driver, sessionID, primaryError;
let logs = "";
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const poll = async (check, attempts = 150) => {
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
const stopChild = async (child) => {
  if (!child || child.pid === undefined || exited(child)) {
    return;
  }
  child.kill("SIGTERM");
  if (await waitForExit(child, 3000)) {
    return;
  }
  child.kill("SIGKILL");
  await waitForExit(child, 3000);
};
const command = async (method, path, body) => {
  const response = await fetch(`http://127.0.0.1:${driverPort}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let result;
  try {
    result = JSON.parse(text);
  } catch {
    throw Error(`WebDriver HTTP ${response.status}: ${text.slice(0, 200)}`);
  }
  // The protocol boundary is the HTTP status: errors are non-2xx, and a
  // 200 value is script data even when the page returns an object with its
  // own error field.
  if (!response.ok) {
    throw Error(JSON.stringify(result.value));
  }
  return result.value;
};
// execute/async so promise-returning expressions (api/load/run) settle before
// returning, and multi-statement programs fall back from expression form.
const executeAsync = (wrapped) =>
  command("POST", `/session/${sessionID}/execute/async`, {
    script: `const done = arguments[arguments.length - 1];
Promise.resolve(${wrapped}).then(done, (error) => done({ __arxError: String((error && error.stack) || error) }));`,
    args: [],
  });
const evaluate = async (expression) => {
  let value;
  try {
    value = await executeAsync(`(async () => { return (${expression}\n); })()`);
  } catch (error) {
    // A multi-statement program breaks the expression wrap; safaridriver
    // reports the parse failure as a javascript error naming the token,
    // not as a SyntaxError, so match the driver's wording too.
    if (!/SyntaxError|Unexpected token|Parse error/.test(String(error))) {
      throw error;
    }
    value = await executeAsync(`(async () => { ${expression}\n; })()`);
  }
  if (value && typeof value === "object" && value.__arxError) {
    throw Error(value.__arxError);
  }
  return value;
};
const until = async (expression) => {
  if (!(await poll(() => evaluate(expression).catch(() => false)))) {
    throw Error(`Safari condition timed out: ${expression}`);
  }
};
const screenshot = async (name) => {
  const data = await command("GET", `/session/${sessionID}/screenshot`);
  writeFileSync(join(evidence, `${name}.png`), Buffer.from(data, "base64"));
};
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
    ["https://bridge.example.test:19443", temporary, "18767"],
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
          port: 18767,
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
  driver = spawn("safaridriver", ["-p", String(driverPort)], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  driver.stdout.on("data", (x) => {
    logs += x;
  });
  driver.stderr.on("data", (x) => {
    logs += x;
  });
  await poll(() => {
    if (driver.exitCode !== null) {
      throw Error(`safaridriver exited: ${logs}`);
    }
    return fetch(`http://127.0.0.1:${driverPort}/status`)
      .then((r) => r.ok)
      .catch(() => false);
  });
  sessionID = (
    await command("POST", "/session", {
      capabilities: {
        alwaysMatch: { browserName: "safari", acceptInsecureCerts: true },
      },
    })
  ).sessionId;
  await command("POST", `/session/${sessionID}/url`, {
    url: "https://bridge.example.test:19443/",
  });
  await until('document.getElementById("secret")!==null');
  // Collect page errors for the failure evidence; classic WebDriver has no
  // console stream, and the fixture server logs only at critical level.
  await evaluate(
    'window.__arxErrors=[];window.addEventListener("error",(event)=>{window.__arxErrors.push(String(event.message));});window.addEventListener("unhandledrejection",(event)=>{window.__arxErrors.push(String((event.reason&&event.reason.stack)||event.reason));});',
  );
  await until(
    'document.getElementById("status").textContent.includes("Pair this browser")',
  );
  assert.equal(
    await evaluate(
      'document.body.textContent.includes("Return the library book")',
    ),
    false,
  );
  await screenshot("safari-01-unpaired");
  await evaluate(
    `document.getElementById("secret").value=${JSON.stringify(secret)};document.getElementById("pair-form").requestSubmit()`,
  );
  await until('!document.getElementById("workspace").hidden');
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
  // Every card action button names its reminder (#27), in Safari's engine too.
  assert.ok(
    await evaluate(
      '[...document.querySelectorAll("#reminders article")].every(a=>{const t=a.querySelector("h3").textContent.replace(/^✓ /,"");return [...a.querySelectorAll(".actions button")].every(b=>(b.getAttribute("aria-label")||"").endsWith(" "+t));})',
    ),
  );
  await screenshot("safari-02-selected-list");
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
  await screenshot("safari-03-escaped-reminder");
  const findCard =
    '[...document.querySelectorAll("#reminders article")].find(n=>n.textContent.includes("<img src=x onerror=alert(1)>"))';
  // A refused save keeps the editor open with the entered values and the reason (#24).
  await evaluate(`${findCard}.querySelector("button").click()`);
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
  assert.match(
    await evaluate('document.getElementById("editor-error").textContent'),
    /Nothing was changed/,
  );
  await screenshot("safari-04-refused-keeps-editor");
  await evaluate('document.getElementById("cancel-edit").click()');
  await until('document.getElementById("editor").hidden');
  // The delete dialog rejects a mistyped confirmation and accepts the exact title (#26).
  await evaluate(
    `[...${findCard}.querySelectorAll("button")].find(b=>b.textContent==="Delete").click()`,
  );
  await until('document.querySelector(".dialog-backdrop")');
  assert.equal(await evaluate('document.querySelector("main").inert'), true);
  await evaluate(
    'document.getElementById("delete-confirmation").value="Wrong title"',
  );
  await evaluate(
    '[...document.querySelectorAll(".dialog-backdrop button")].find(b=>b.textContent==="Delete reminder").click()',
  );
  await until(
    'document.querySelector(".dialog-backdrop .error") && !document.querySelector(".dialog-backdrop .error").hidden',
  );
  assert.ok(
    await evaluate(
      'document.getElementById("reminders").textContent.includes("<img src=x onerror=alert(1)>")',
    ),
  );
  await screenshot("safari-05-delete-mismatch");
  await evaluate(
    `document.getElementById("delete-confirmation").value=${JSON.stringify("<img src=x onerror=alert(1)>")}`,
  );
  await evaluate(
    '[...document.querySelectorAll(".dialog-backdrop button")].find(b=>b.textContent==="Delete reminder").click()',
  );
  await until(
    '!document.getElementById("reminders").textContent.includes("<img src=x onerror=alert(1)>")',
  );
  assert.equal(await evaluate("document.activeElement?.id"), "new");
  // Count submit events at the page level so a failed edits suite shows
  // whether requestSubmit ever dispatched (versus a handler that ran but
  // whose fetch the suite's wrapper could not observe).
  await evaluate(
    'window.__arxSubmitCount=0;document.getElementById("edit-form").addEventListener("submit",()=>{window.__arxSubmitCount++;});',
  );
  // The shared error-path and edit suites run under Safari unchanged.
  await checkBrowserEdits({ evaluate, until, screenshot });
  await checkBrowserOutcomes({ evaluate, until, screenshot });
  await command("DELETE", `/session/${sessionID}/cookie`);
  await evaluate('api("/api/session").catch(()=>{})');
  await until('document.getElementById("pairing").hidden===false');
  assert.deepEqual(
    await evaluate(
      '({title:el("title").value,heading:el("list-title").textContent,editing})',
    ),
    { title: "", heading: "Choose a list", editing: null },
  );
  await screenshot("safari-06-denied-cleared");
  writeFileSync(
    join(evidence, "results.json"),
    JSON.stringify(
      {
        browser: "safari",
        paired: true,
        httpOnlyCookie: true,
        noWebStorage: true,
        escapedText: true,
        refusedSaveKeepsEditor: true,
        deleteConfirmation: true,
        editAndOutcomeSuites: true,
        denialClearsPrivateUI: true,
      },
      null,
      2,
    ),
  );
  process.stdout.write(
    "Safari/WebDriver fixture checks passed. No real account data used.\n",
  );
} catch (error) {
  primaryError = error;
  process.stderr.write(`${String(error)}\n`);
  // Best-effort page state so a failed run names the actual page condition.
  // Each probe is isolated: one failing field records its error and the
  // rest still report.
  let pageState = "";
  if (sessionID) {
    const probes = {
      status: 'el("status")&&el("status").textContent',
      busy: 'typeof busy==="undefined"?"<undef>":busy',
      editing:
        'typeof editing==="undefined"?"<undef>":editing===null?null:(editing.fields?editing.fields.title:"<no fields>")',
      editorOpen: 'el("editor")?!el("editor").hidden:"<no editor>"',
      priorityValue: 'el("priority")?el("priority").value:"<no priority>"',
      commandActions:
        'window.editFixture?JSON.stringify(window.editFixture.commands.map((c)=>({action:c.action,priority:c.fields?c.fields.priority:null}))):"<no fixture>"',
      uncertain:
        'typeof uncertainWrites==="undefined"?"<undef>":JSON.stringify(uncertainWrites)',
      pageErrors: "JSON.stringify(window.__arxErrors||null)",
      url: "location.href",
      submitCount:
        'window.__arxSubmitCount==null?"<not installed>":window.__arxSubmitCount',
      mainInert:
        'document.querySelector("main")?document.querySelector("main").inert:"<no main>"',
      formValid: 'el("edit-form")?el("edit-form").checkValidity():"<no form>"',
      invalidControls:
        'el("edit-form")?JSON.stringify([...el("edit-form").elements].filter((c)=>typeof c.checkValidity==="function"&&!c.checkValidity()).map((c)=>c.id)):"<no form>"',
      editorError:
        'document.getElementById("editor-error")?document.getElementById("editor-error").textContent:null',
      dueDateState:
        'el("due-date")?JSON.stringify({value:el("due-date").value,validity:{valueMissing:el("due-date").validity.valueMissing,badInput:el("due-date").validity.badInput,typeMismatch:el("due-date").validity.typeMismatch,stepMismatch:el("due-date").validity.stepMismatch,rangeUnderflow:el("due-date").validity.rangeUnderflow,rangeOverflow:el("due-date").validity.rangeOverflow,customError:el("due-date").validity.customError,valid:el("due-date").validity.valid}}):"<no due-date>"',
      dueTimeState:
        'el("due-time")?JSON.stringify({value:el("due-time").value,validity:{valueMissing:el("due-time").validity.valueMissing,badInput:el("due-time").validity.badInput,typeMismatch:el("due-time").validity.typeMismatch,stepMismatch:el("due-time").validity.stepMismatch,rangeUnderflow:el("due-time").validity.rangeUnderflow,rangeOverflow:el("due-time").validity.rangeOverflow,customError:el("due-time").validity.customError,valid:el("due-time").validity.valid}}):"<no due-time>"',
      startDateState:
        'el("start-date")?JSON.stringify({value:el("start-date").value,valid:el("start-date").validity.valid}):"<no start-date>"',
      savedReminder:
        'typeof rows==="undefined"?"<undef>":JSON.stringify(rows.filter((r)=>r.fields.title&&r.fields.title.indexOf("Line one")>=0).map((r)=>({id:r.id,priority:r.fields.priority})))',
    };
    // Sequential probes deliberately reuse the one WebDriver session.
    await Object.entries(probes).reduce(
      (prior, [name, expression]) =>
        prior.then(async () => {
          try {
            pageState += `${name}: ${JSON.stringify(await evaluate(expression))}\n`;
          } catch (probeError) {
            pageState += `${name}: <probe failed: ${String(probeError).slice(0, 300)}>\n`;
          }
        }),
      Promise.resolve(),
    );
    // Remedy check on the still-open editor: if the date/time controls are
    // invalid only because WebKit kept their state after one programmatic
    // clear, clearing again restores validity and lets the submit dispatch.
    // This verifies the externally reported workaround in the actual failing
    // page before any product change is proposed.
    try {
      const remedy = await evaluate(`(() => {
        const out = { before: { dateValid: el("due-date").validity.valid, timeValid: el("due-time").validity.valid, formValid: el("edit-form").checkValidity(), submits: window.__arxSubmitCount ?? null } };
        el("due-date").value = ""; el("due-date").value = "";
        el("due-time").value = ""; el("due-time").value = "";
        out.after = { dateValid: el("due-date").validity.valid, timeValid: el("due-time").validity.valid, formValid: el("edit-form").checkValidity() };
        el("edit-form").requestSubmit();
        out.submitsAfter = window.__arxSubmitCount ?? null;
        return JSON.stringify(out);
      })()`);
      pageState += `remedyExperiment: ${remedy}
`;
    } catch (remedyError) {
      pageState += `remedyExperiment: <failed: ${String(remedyError).slice(0, 300)}>
`;
    }
  }
  writeFileSync(
    join(evidence, "failure.txt"),
    `${String(error)}\n${pageState}${logs}`,
  );
} finally {
  try {
    if (sessionID) {
      await command("DELETE", `/session/${sessionID}`).catch(() => {});
    }
    await stopChild(driver);
    await stopChild(server);
    proxy?.close();
  } finally {
    if (primaryError) {
      process.exitCode = 1;
    }
  }
}
