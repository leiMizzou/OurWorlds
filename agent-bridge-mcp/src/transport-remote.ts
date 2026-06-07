/**
 * transport-remote.ts — WebSocket transport for ourworlds-mcp.
 *
 * Exports `connectRemote(url, token, name?)` which:
 *  - opens a ws:// / wss:// WebSocket;
 *  - sends auth frame first (id:0, tool:"auth") and awaits its ok response;
 *  - returns a client with `call(tool, args) => Promise<envelope>`;
 *  - auto-reconnects on drop and re-sends auth on each reconnect.
 *
 * Wire contract is identical to the TCP transport:
 *   Request  envelope: {"id": <n>, "tool": "<name>", "args": { … }}
 *   Response envelope: {"id": <n>, "ok": true,  "result": {…}}
 *                   or {"id": <n>, "ok": false, "error": "<reason>"}
 */

import WebSocket from "ws";

// ---------------------------------------------------------------------------
// Constants (mirror the TCP transport values)
// ---------------------------------------------------------------------------

const REQUEST_TIMEOUT_MS = 15_000;
const CONNECT_TIMEOUT_MS = 4_000;
const RECONNECT_COOLDOWN_MS = 750;

// stderr only — stdout is the MCP JSON-RPC channel.
function log(...args: unknown[]): void {
  console.error("[ourworlds-mcp/remote]", ...args);
}

// ---------------------------------------------------------------------------
// Shared envelope types
// ---------------------------------------------------------------------------

export interface RemoteEnvelope {
  id: number | string | null;
  ok?: boolean;
  result?: unknown;
  error?: string;
  event?: string;
  [k: string]: unknown;
}

interface Pending {
  resolve: (env: RemoteEnvelope) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

// ---------------------------------------------------------------------------
// RemoteClient
// ---------------------------------------------------------------------------

export interface RemoteClient {
  /** Send one tool call and await its correlated response. */
  call(tool: string, args: Record<string, unknown>): Promise<RemoteEnvelope>;
}

class RemoteClientImpl implements RemoteClient {
  private ws: WebSocket | null = null;
  private connecting: Promise<WebSocket> | null = null;
  /** nextId starts at 1 (0 is reserved for the auth frame) */
  private nextId = 1;
  private pending = new Map<number | string, Pending>();
  private lastConnectAttempt = 0;

  constructor(
    private readonly url: string,
    private readonly token: string,
    private readonly name: string | undefined,
  ) {}

  private allocId(): number {
    const id = this.nextId++;
    if (this.nextId >= Number.MAX_SAFE_INTEGER) this.nextId = 1;
    return id;
  }

  /**
   * Ensure a live, authenticated WebSocket.
   * Only one connect attempt runs at a time; auth happens inside before resolving.
   */
  private async ensureConnected(): Promise<WebSocket> {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return this.ws;
    if (this.connecting) return this.connecting;

    const since = Date.now() - this.lastConnectAttempt;
    if (since < RECONNECT_COOLDOWN_MS) {
      await new Promise<void>((r) => setTimeout(r, RECONNECT_COOLDOWN_MS - since));
    }
    this.lastConnectAttempt = Date.now();

    this.connecting = this.openAndAuth().finally(() => {
      this.connecting = null;
    });

    return this.connecting;
  }

  /**
   * Open a new WebSocket, wire up message/close/error handlers,
   * and perform the auth handshake before resolving.
   */
  private openAndAuth(): Promise<WebSocket> {
    return new Promise<WebSocket>((resolve, reject) => {
      let settled = false;

      const connectTimer = setTimeout(() => {
        if (settled) return;
        settled = true;
        ws.terminate();
        reject(new Error(`timed out connecting to ${this.url} after ${CONNECT_TIMEOUT_MS}ms`));
      }, CONNECT_TIMEOUT_MS);

      const ws = new WebSocket(this.url);

      ws.once("error", (err) => {
        if (settled) return;
        settled = true;
        clearTimeout(connectTimer);
        reject(new Error(`WebSocket error connecting to ${this.url}: ${(err as Error).message}`));
      });

      ws.once("open", () => {
        // Don't clear connectTimer yet — we must also await auth.
        // Wire up the persistent message / close / error handlers first.
        this.attach(ws);

        // Send the auth frame (id: 0).
        const authPayload = JSON.stringify({
          id: 0,
          tool: "auth",
          args: { token: this.token, ...(this.name !== undefined ? { name: this.name } : {}) },
        });

        // Register a one-time pending entry for the auth response.
        const authTimer = setTimeout(() => {
          this.pending.delete(0);
          if (settled) return;
          settled = true;
          clearTimeout(connectTimer);
          ws.terminate();
          reject(new Error(`timed out waiting for auth response from ${this.url}`));
        }, REQUEST_TIMEOUT_MS);

        this.pending.set(0, {
          resolve: (env) => {
            clearTimeout(authTimer);
            clearTimeout(connectTimer);
            if (settled) return;
            settled = true;
            if (env.ok === false) {
              ws.terminate();
              reject(new Error(`auth rejected by ${this.url}: ${env.error ?? "unknown"}`));
            } else {
              this.ws = ws;
              // Unref the underlying socket so the WebSocket does not prevent
              // Node from exiting when no other work is pending (e.g. in tests).
              // Active requests keep a timer ref so in-flight calls still await.
              (ws as unknown as { _socket?: { unref?(): void } })._socket?.unref?.();
              log(`connected & authenticated to ${this.url}`);
              resolve(ws);
            }
          },
          reject: (err) => {
            clearTimeout(authTimer);
            clearTimeout(connectTimer);
            if (settled) return;
            settled = true;
            reject(err);
          },
          timer: authTimer,
        });

        ws.send(authPayload);
      });
    });
  }

  /** Wire persistent data / close / error handlers onto an open socket. */
  private attach(ws: WebSocket): void {
    ws.on("message", (raw) => {
      const line = raw.toString("utf8").trim();
      if (!line) return;
      let msg: RemoteEnvelope;
      try {
        msg = JSON.parse(line) as RemoteEnvelope;
      } catch {
        log("ignoring non-JSON message:", line.slice(0, 200));
        return;
      }

      if (msg.id === undefined || msg.id === null) {
        if (typeof msg.event === "string") {
          log("event:", msg.event);
        } else if (msg.ok === false) {
          log("protocol error (no id):", msg.error);
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
    });

    const tearDown = (reason: string) => {
      if (this.ws === ws) this.ws = null;
      const err = new Error(`remote connection lost (${reason})`);
      for (const [, p] of this.pending) {
        clearTimeout(p.timer);
        p.reject(err);
      }
      this.pending.clear();
    };

    ws.on("close", () => {
      log("remote connection closed");
      tearDown("closed");
    });

    ws.on("error", (err) => {
      log("remote socket error:", (err as Error).message);
      tearDown((err as Error).message);
    });
  }

  async call(tool: string, args: Record<string, unknown>): Promise<RemoteEnvelope> {
    const ws = await this.ensureConnected();
    const id = this.allocId();
    const payload = JSON.stringify({ id, tool, args });

    return new Promise<RemoteEnvelope>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new Error(
            `timed out waiting for remote response to "${tool}" (id ${id}) after ${REQUEST_TIMEOUT_MS}ms`,
          ),
        );
      }, REQUEST_TIMEOUT_MS);

      this.pending.set(id, { resolve, reject, timer });

      ws.send(payload, (err) => {
        if (err) {
          this.pending.delete(id);
          clearTimeout(timer);
          reject(new Error(`failed to send "${tool}" to remote: ${(err as Error).message}`));
        }
      });
    });
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Open a WebSocket to `url`, authenticate with `token` (and optional `name`),
 * and return a client whose `call(tool, args)` relays NDJSON envelopes.
 *
 * Resolves only after the auth handshake succeeds. Subsequent connection drops
 * are handled transparently: the next `call()` will reconnect and re-auth.
 */
export async function connectRemote(
  url: string,
  token: string,
  name?: string,
): Promise<RemoteClient> {
  const client = new RemoteClientImpl(url, token, name);
  // Trigger the initial connect + auth eagerly.
  // We access the private method via a cast to ensure the first connect
  // (and auth) completes before we hand the client to the caller.
  await (client as unknown as { ensureConnected(): Promise<WebSocket> }).ensureConnected();
  return client;
}
