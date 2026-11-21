// Real browser input during a held fixture heartbeat, with the real fixture server.
import assert from "node:assert/strict";

export async function checkBrowserInput({ evaluate, until, send, screenshot }) {
  await evaluate(`window.inputFixture = { originalFetch: window.fetch.bind(window), commands: [] };
    window.fetch = async (path, options) => {
      const fixture = window.inputFixture;
      if (path === "/api/session" && fixture.hold) {
        return new Promise(resolve => { fixture.release = () => resolve(fixture.originalFetch(path, options)); });
      }
      if (path === "/api/mutate") fixture.commands.push(JSON.parse(options.body));
      return fixture.originalFetch(path, options);
    };`);
  try {
    const submitDuringHeartbeat = async (method) => {
      const title = `Heartbeat ${method} fixture`;
      await evaluate(
        `openEditor(null);el("title").value=${JSON.stringify(title)};window.inputFixture.hold=true;window.fixtureHeartbeat();`,
      );
      await until("typeof window.inputFixture.release==='function'");
      assert.equal(await evaluate('el("save").disabled'), false);
      if (method === "enter") {
        await send("Input.dispatchKeyEvent", {
          type: "keyDown",
          text: "\r",
          unmodifiedText: "\r",
          key: "Enter",
          code: "Enter",
          windowsVirtualKeyCode: 13,
        });
        await send("Input.dispatchKeyEvent", {
          type: "keyUp",
          key: "Enter",
          code: "Enter",
          windowsVirtualKeyCode: 13,
        });
      } else {
        await evaluate('el("save").scrollIntoView({block:"center"})');
        const point = await evaluate(
          '(()=>{const r=el("save").getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()',
        );
        await send("Input.dispatchMouseEvent", {
          type: "mousePressed",
          button: "left",
          clickCount: 1,
          ...point,
        });
        await send("Input.dispatchMouseEvent", {
          type: "mouseReleased",
          button: "left",
          clickCount: 1,
          ...point,
        });
      }
      await until(
        `!busy && rows.some(row=>row.fields.title===${JSON.stringify(title)})`,
      );
      assert.equal(
        await evaluate(
          `window.inputFixture.commands.filter(command=>command.fields?.title===${JSON.stringify(title)}).length`,
        ),
        1,
      );
      await evaluate(
        "window.inputFixture.hold=false;window.inputFixture.release();delete window.inputFixture.release;",
      );
    };
    await submitDuringHeartbeat("enter");
    await submitDuringHeartbeat("pointer");
    await screenshot("05b-heartbeat-real-input");
  } catch (error) {
    error.message += ` Input fixture state: ${JSON.stringify(await evaluate('({busy,status:el("status").textContent,active:document.activeElement.id,valid:el("edit-form").checkValidity(),commands:window.inputFixture.commands,rows:rows.map(row=>row.fields.title)})'))}`;
    await screenshot("05b-input-failure");
    throw error;
  } finally {
    await evaluate(
      "window.inputFixture.hold=false;window.inputFixture.release?.();window.fetch=window.inputFixture.originalFetch;delete window.inputFixture;",
    );
  }
}
