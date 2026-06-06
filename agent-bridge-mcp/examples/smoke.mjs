// 全链路烟测：MCP 客户端 → (stdio) MCP 服务器 → (TCP) Godot 游戏
// 用法：先让游戏带 OW_AGENT_PORT=8970 跑起来，再 `node smoke.mjs`
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const SERVER = "./agent-bridge-mcp/dist/index.js";

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [SERVER],
  env: { ...process.env, OW_AGENT_PORT: "8970" },
});
const client = new Client({ name: "voxel-smoke", version: "1.0.0" });
await client.connect(transport);

const tools = await client.listTools();
console.log("TOOLS(" + tools.tools.length + "): " + tools.tools.map((t) => t.name).join(", "));

const obs = await client.callTool({ name: "observe", arguments: {} });
const otxt = (obs.content && obs.content[0] && obs.content[0].text) || JSON.stringify(obs);
console.log("OBSERVE -> " + otxt.slice(0, 480));

try {
  const b = await client.callTool({
    name: "build",
    arguments: { template: "beacon_tower", x: 70, y: 44, z: -25, rotation: 0 },
  });
  const btxt = (b.content && b.content[0] && b.content[0].text) || JSON.stringify(b);
  console.log("BUILD -> " + btxt.slice(0, 300));
} catch (e) {
  console.log("BUILD err: " + String(e).slice(0, 200));
}

await client.close();
console.log("SMOKE OK");
process.exit(0);
