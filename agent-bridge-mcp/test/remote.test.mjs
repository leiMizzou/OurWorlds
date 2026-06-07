// node --test test/remote.test.mjs   (after npm run build)
import { test } from "node:test";
import assert from "node:assert";
import { WebSocketServer } from "ws";
import { connectRemote } from "../dist/transport-remote.js";

test("remote transport: sends auth frame first, relays envelopes", async () => {
  const wss = new WebSocketServer({ port: 0 });
  const port = wss.address().port;
  const frames = [];
  wss.on("connection", (ws) => {
    ws.on("message", (m) => {
      const env = JSON.parse(m.toString());
      frames.push(env);
      if (env.tool === "auth") ws.send(JSON.stringify({ id: env.id, ok: true, result: { eid: "agent-1" } }));
      else ws.send(JSON.stringify({ id: env.id, ok: true, result: { echoed: env.tool } }));
    });
  });
  const client = await connectRemote(`ws://127.0.0.1:${port}`, "tok", "Bot");
  const r = await client.call("observe", {});
  assert.equal(r.ok, true);
  assert.equal(frames[0].tool, "auth");           // auth first
  assert.equal(frames[0].args.token, "tok");
  assert.equal(frames[1].tool, "observe");
  client.close();
  for (const c of wss.clients) c.terminate();
  await new Promise((res) => wss.close(res));
});
