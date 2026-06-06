#!/usr/bin/env node
/**
 * ourworlds-mcp — MCP server bridging an LLM agent (OpenClaw) to the running
 * OurWorlds game's TCP agent-control API.
 *
 * Transport to the game (see docs/agent-bridge-contract.md):
 *   - Plain TCP stream socket (NOT WebSocket, NOT HTTP).
 *   - Newline-delimited JSON (NDJSON): one JSON object per line, terminated by '\n'.
 *   - UTF-8. 127.0.0.1 : (env OW_AGENT_PORT || 8970). Single client.
 *
 * Request  envelope: {"id": <n>, "tool": "<name>", "args": { ... }}
 * Response envelope: {"id": <n>, "ok": true, "result": {...}}   (success)
 *                or  {"id": <n>, "ok": false, "error": "<reason>"} (failure)
 *
 * This process speaks MCP over STDIO to OpenClaw, and forwards each MCP tool
 * call to the game over ONE persistent, auto-reconnecting TCP socket.
 */

import net from "node:net";

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const HOST = "127.0.0.1";
const PORT = (() => {
  const raw = process.env.OW_AGENT_PORT;
  const n = raw ? Number.parseInt(raw, 10) : NaN;
  return Number.isFinite(n) && n > 0 ? n : 8970;
})();

/** How long to wait for a single tool's response line from the game. */
const REQUEST_TIMEOUT_MS = 15_000;
/** How long an initial connect attempt may take before we give up. */
const CONNECT_TIMEOUT_MS = 4_000;
/** Minimum gap between reconnect attempts (we connect lazily, on demand). */
const RECONNECT_COOLDOWN_MS = 750;

// stderr is safe for logs; stdout is reserved for the MCP JSON-RPC stream.
function log(...args: unknown[]): void {
  console.error("[ourworlds-mcp]", ...args);
}

// ---------------------------------------------------------------------------
// Persistent NDJSON TCP client to the game
// ---------------------------------------------------------------------------

interface Pending {
  resolve: (line: GameResponse) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

/** Shape of a response line from the game (per contract §1.2). */
interface GameResponse {
  id: number | string | null;
  ok?: boolean;
  result?: unknown;
  error?: string;
  // Unsolicited event lines (§7) carry `event` and have no id; ignored here.
  event?: string;
  [k: string]: unknown;
}

class GameClient {
  private socket: net.Socket | null = null;
  private connecting: Promise<net.Socket> | null = null;
  private buffer = ""; // partial trailing bytes between data chunks
  private nextId = 1;
  private pending = new Map<number | string, Pending>();
  private lastConnectAttempt = 0;

  constructor(
    private readonly host: string,
    private readonly port: number,
  ) {}

  /** Allocate a fresh correlation id (numbers wrap well before MAX_SAFE_INTEGER). */
  private allocId(): number {
    const id = this.nextId++;
    if (this.nextId >= Number.MAX_SAFE_INTEGER) this.nextId = 1;
    return id;
  }

  /**
   * Ensure a live socket. Connects lazily and at most one connect runs at a
   * time. A short cooldown avoids hammering when the game is down.
   */
  private async ensureConnected(): Promise<net.Socket> {
    if (this.socket && !this.socket.destroyed) return this.socket;
    if (this.connecting) return this.connecting;

    const since = Date.now() - this.lastConnectAttempt;
    if (since < RECONNECT_COOLDOWN_MS) {
      await new Promise((r) => setTimeout(r, RECONNECT_COOLDOWN_MS - since));
    }
    this.lastConnectAttempt = Date.now();

    this.connecting = new Promise<net.Socket>((resolve, reject) => {
      const sock = new net.Socket();
      let settled = false;

      const onConnectTimeout = setTimeout(() => {
        if (settled) return;
        settled = true;
        sock.destroy();
        reject(
          new Error(
            `timed out connecting to OurWorlds agent bridge at ${this.host}:${this.port} after ${CONNECT_TIMEOUT_MS}ms`,
          ),
        );
      }, CONNECT_TIMEOUT_MS);

      sock.once("error", (err: NodeJS.ErrnoException) => {
        if (settled) return;
        settled = true;
        clearTimeout(onConnectTimeout);
        reject(decorateConnectError(err, this.host, this.port));
      });

      sock.connect(this.port, this.host, () => {
        if (settled) return;
        settled = true;
        clearTimeout(onConnectTimeout);
        sock.setNoDelay(true);
        sock.setEncoding("utf8");
        this.attach(sock);
        this.socket = sock;
        log(`connected to game at ${this.host}:${this.port}`);
        resolve(sock);
      });
    }).finally(() => {
      this.connecting = null;
    });

    return this.connecting;
  }

  /** Wire up data/close/error handling for a freshly connected socket. */
  private attach(sock: net.Socket): void {
    sock.on("data", (chunk: string) => this.onData(chunk));

    const tearDown = (reason: string) => {
      if (this.socket === sock) this.socket = null;
      this.buffer = "";
      // Fail every in-flight request; the caller surfaces a clear error and
      // the next call will transparently reconnect.
      const err = new Error(`connection to game lost (${reason})`);
      for (const [, p] of this.pending) {
        clearTimeout(p.timer);
        p.reject(err);
      }
      this.pending.clear();
    };

    sock.on("close", () => {
      log("game connection closed");
      tearDown("closed");
    });
    sock.on("error", (err) => {
      log("game socket error:", (err as Error).message);
      tearDown((err as Error).message);
    });
  }

  /** Accumulate bytes, split on '\n', dispatch each complete JSON line. */
  private onData(chunk: string): void {
    this.buffer += chunk;
    let nl: number;
    while ((nl = this.buffer.indexOf("\n")) !== -1) {
      const line = this.buffer.slice(0, nl).trim();
      this.buffer = this.buffer.slice(nl + 1);
      if (line.length === 0) continue;
      this.dispatchLine(line);
    }
  }

  private dispatchLine(line: string): void {
    let msg: GameResponse;
    try {
      msg = JSON.parse(line) as GameResponse;
    } catch {
      log("ignoring non-JSON line from game:", line.slice(0, 200));
      return;
    }

    // Unsolicited event lines (§7) have no id and an `event` field. A v1 bridge
    // may ignore any line lacking ok/error; we log and drop them.
    if (msg.id === undefined || msg.id === null) {
      if (typeof msg.event === "string") {
        log("event:", msg.event);
      } else if (msg.ok === false) {
        log("protocol error from game (no id):", msg.error);
      }
      return;
    }

    const key = msg.id as number | string;
    const p = this.pending.get(key);
    if (!p) {
      log("response for unknown id (late/duplicate?):", key);
      return;
    }
    this.pending.delete(key);
    clearTimeout(p.timer);
    p.resolve(msg);
  }

  /**
   * Send one request and await its correlated response. Connects on demand.
   * Resolves with the FULL game response envelope (ok:true or ok:false); only
   * transport-level problems reject.
   */
  async request(tool: string, args: Record<string, unknown>): Promise<GameResponse> {
    const sock = await this.ensureConnected();
    const id = this.allocId();
    const payload = JSON.stringify({ id, tool, args }) + "\n";

    return new Promise<GameResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new Error(
            `timed out waiting for game response to "${tool}" (id ${id}) after ${REQUEST_TIMEOUT_MS}ms`,
          ),
        );
      }, REQUEST_TIMEOUT_MS);

      this.pending.set(id, { resolve, reject, timer });

      sock.write(payload, "utf8", (err) => {
        if (err) {
          this.pending.delete(id);
          clearTimeout(timer);
          reject(new Error(`failed to send "${tool}" to game: ${err.message}`));
        }
      });
    });
  }
}

function decorateConnectError(
  err: NodeJS.ErrnoException,
  host: string,
  port: number,
): Error {
  if (err.code === "ECONNREFUSED") {
    return new Error(
      `cannot reach the OurWorlds agent bridge at ${host}:${port} ` +
        `(connection refused). Is the game running with OW_AGENT_PORT set ` +
        `(default 8970)? Launch OurWorlds, then retry.`,
    );
  }
  return new Error(`error connecting to ${host}:${port}: ${err.message}`);
}

const game = new GameClient(HOST, PORT);

// ---------------------------------------------------------------------------
// MCP server
// ---------------------------------------------------------------------------

const server = new McpServer({
  name: "ourworlds-mcp",
  version: "1.0.0",
});

/** A standard CallToolResult payload. */
type ToolResult = {
  content: { type: "text"; text: string }[];
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};

/**
 * Forward an MCP tool call to the game and translate the NDJSON envelope into
 * an MCP tool result.
 *
 * - Transport failure (game down, timeout) -> MCP error result with guidance.
 * - Game ok:false                          -> MCP error result echoing `error`.
 * - Game ok:true                           -> MCP success; `result` is returned
 *   both as JSON text and as structuredContent so the LLM can read fields.
 */
async function forward(tool: string, args: Record<string, unknown>): Promise<ToolResult> {
  let resp: GameResponse;
  try {
    resp = await game.request(tool, args);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      content: [{ type: "text", text: `Bridge error: ${message}` }],
      structuredContent: { ok: false, error: message, bridge_error: true },
      isError: true,
    };
  }

  if (resp.ok === true) {
    const result =
      resp.result && typeof resp.result === "object"
        ? (resp.result as Record<string, unknown>)
        : { value: resp.result };
    return {
      content: [{ type: "text", text: JSON.stringify(result) }],
      structuredContent: result,
    };
  }

  // ok:false (or malformed). Surface the game's single-line error verbatim.
  const error = typeof resp.error === "string" ? resp.error : "unknown error from game";
  return {
    content: [{ type: "text", text: `Game error: ${error}` }],
    structuredContent: { ok: false, error },
    isError: true,
  };
}

// ---------------------------------------------------------------------------
// Tool input schemas (raw Zod shapes — what registerTool expects in SDK 1.x)
//
// We keep these permissive but typed, mirroring contract §4. The game is the
// source of truth for validation and returns ok:false on bad args; we simply
// pass structured args through.
// ---------------------------------------------------------------------------

const cell = z
  .tuple([z.number().int(), z.number().int(), z.number().int()])
  .describe("Integer voxel cell [x, y, z].");

// 4.1 observe
server.registerTool(
  "observe",
  {
    title: "Observe",
    description:
      "Full situational snapshot: player pos & facing, region, time of day, " +
      "selected block & hotbar, a local terrain heightmap, nearby landmarks, " +
      "and recent actions. The agent's primary perception call.",
    inputSchema: {
      heightmap_size: z
        .number()
        .int()
        .min(2)
        .max(16)
        .optional()
        .describe("Even size of the centered heightmap window (default & max 16)."),
    },
  },
  async (args) => forward("observe", stripUndefined(args)),
);

// 4.2 look
server.registerTool(
  "look",
  {
    title: "Look",
    description:
      "Aim the view: set absolute body yaw and/or look pitch (degrees). Does not " +
      "move the player. Omitted axis is left unchanged.",
    inputSchema: {
      yaw_deg: z
        .number()
        .optional()
        .describe("Absolute yaw in degrees, normalized to [0,360). 0 = facing north (-Z)."),
      pitch_deg: z
        .number()
        .optional()
        .describe("Look pitch in degrees, clamped to [-80, 80]. + = looking up."),
    },
  },
  async (args) => forward("look", stripUndefined(args)),
);

// 4.3 goto
server.registerTool(
  "goto",
  {
    title: "Go To",
    description:
      "Teleport the player to the surface at horizontal (x, z), landing standing " +
      "on the ground. Optional y places exactly at that height instead.",
    inputSchema: {
      x: z.number().int().describe("Target X cell."),
      z: z.number().int().describe("Target Z cell."),
      y: z
        .number()
        .int()
        .optional()
        .describe("Optional exact Y (clamped to [0,95]); omit to land on the surface."),
    },
  },
  async (args) => forward("goto", stripUndefined(args)),
);

// 4.4 scan
server.registerTool(
  "scan",
  {
    title: "Scan",
    description:
      "Compact overview of a square area centered on the player: per-column " +
      "surface height and dominant surface block (down-sampled), block " +
      "histogram, regions present, water fraction, nearby landmarks, and a " +
      "suggested flat build spot. Lets you read terrain without many get_block calls.",
    inputSchema: {
      radius: z
        .number()
        .int()
        .min(1)
        .max(24)
        .optional()
        .describe("Scan radius in blocks (default 8, max 24)."),
    },
  },
  async (args) => forward("scan", stripUndefined(args)),
);

// 4.5 place
server.registerTool(
  "place",
  {
    title: "Place",
    description:
      "Set a set of cells to a block in one atomic batch (single remesh, one " +
      "undo entry). Pass meaningful cell sets (a wall, floor, outline) — not " +
      "single cells streamed one at a time. Use 'air' to clear. Max 4096 cells.",
    inputSchema: {
      block: z
        .string()
        .describe("Block name: English alias or Chinese (case-insensitive). 'air' clears."),
      cells: z
        .array(cell)
        .min(1)
        .max(4096)
        .describe("Array of [x,y,z] cells (max 4096). Out-of-range y is skipped."),
    },
  },
  async (args) => forward("place", args),
);

// 4.6 break
server.registerTool(
  "break",
  {
    title: "Break",
    description:
      "Clear a set of cells to air (convenience alias of place with block=air). " +
      "Max 4096 cells.",
    inputSchema: {
      cells: z
        .array(cell)
        .min(1)
        .max(4096)
        .describe("Array of [x,y,z] cells to set to air (max 4096)."),
    },
  },
  async (args) => forward("break", args),
);

// 4.7 build
server.registerTool(
  "build",
  {
    title: "Build",
    description:
      "Stamp a named build template (the game's own structure geometry) at an " +
      "anchor cell, in one batch. The primary 'construct something' verb — no " +
      "per-coordinate placement. Templates: platform, pillar, arch, wall, stairs, " +
      "room_frame, cabin, campfire, bridge, garden, beacon_tower, signpost. For " +
      "ground structures use y = surface_y(x,z)+1 so the base sits on the ground.",
    inputSchema: {
      template: z
        .string()
        .describe(
          "Template id: platform|pillar|arch|wall|stairs|room_frame|cabin|campfire|bridge|garden|beacon_tower|signpost.",
        ),
      x: z.number().int().describe("Anchor X (structure base/origin cell)."),
      y: z.number().int().describe("Anchor Y (use surface_y+1 for ground builds)."),
      z: z.number().int().describe("Anchor Z."),
      rotation: z
        .number()
        .int()
        .optional()
        .describe("0 or 1 (also accepts 0/90/180/270; even->0, odd->1). 0 = E–W, 1 = N–S."),
    },
  },
  async (args) => forward("build", stripUndefined(args)),
);

// 4.8 get_block
server.registerTool(
  "get_block",
  {
    title: "Get Block",
    description:
      "Read one cell. Returns the block name (alias) and whether it is solid. " +
      "y outside [0,95] reads as 'air'.",
    inputSchema: {
      x: z.number().int().describe("X cell."),
      y: z.number().int().describe("Y cell."),
      z: z.number().int().describe("Z cell."),
    },
  },
  async (args) => forward("get_block", args),
);

// 4.9 say
server.registerTool(
  "say",
  {
    title: "Say",
    description:
      "Show an agent message on the in-game HUD feedback banner (≤120 chars). " +
      "Narrate or announce intent to a human watching the screen.",
    inputSchema: {
      text: z.string().describe("Message to show on-screen (trimmed to 120 chars)."),
    },
  },
  async (args) => forward("say", args),
);

// 4.10 set_goal
server.registerTool(
  "set_goal",
  {
    title: "Set Goal",
    description:
      "Record the agent's current one-line objective in the persistent " +
      "scratchpad (survives across game runs). ≤200 chars.",
    inputSchema: {
      text: z.string().describe("Current goal (≤200 chars)."),
    },
  },
  async (args) => forward("set_goal", args),
);

// 4.11 remember
server.registerTool(
  "remember",
  {
    title: "Remember",
    description:
      "Append a free-form note to the persistent scratchpad (last 50 kept). " +
      "≤280 chars. Use for facts to recall across runs (locations, progress).",
    inputSchema: {
      text: z.string().describe("Note to remember (≤280 chars)."),
    },
  },
  async (args) => forward("remember", args),
);

// 4.12 get_memory
server.registerTool(
  "get_memory",
  {
    title: "Get Memory",
    description:
      "Read the persistent scratchpad: current goal, notes, and last-updated time.",
    inputSchema: {},
  },
  async () => forward("get_memory", {}),
);

/** Drop keys whose value is undefined so optional args aren't serialized as null. */
function stripUndefined(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v !== undefined) out[k] = v;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  log(
    `MCP server ready on STDIO. Forwarding to OurWorlds at ${HOST}:${PORT} ` +
      `(set OW_AGENT_PORT to override).`,
  );
}

main().catch((err) => {
  log("fatal:", err instanceof Error ? err.stack ?? err.message : String(err));
  process.exit(1);
});
