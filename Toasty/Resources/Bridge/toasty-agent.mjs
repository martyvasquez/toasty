// Toasty: bridge between a Claude conversation tab and the Claude Agent SDK.
//
// Deliberately minimal: it starts one SDK query configured to behave like
// the interactive CLI (Claude Code system prompt + tools presets, user /
// project / local settings, the installed `claude` executable) and relays
// JSON lines over stdio. It makes no decisions of its own.
//
// stdin  (from Toasty): start | user | interrupt | permission_response | set_permission_mode | set_model
//                       | remote_control | context_usage | mcp_result
// stdout (to Toasty):   ready | sdk | models | commands | permission_request | permission_cancel | error | end
//                       | remote_control_init | remote_control | context_usage | mcp_call
//
// `node toasty-agent.mjs fork '<json>'` instead forks a saved session with
// the SDK's forkSession ({sessionId, upToMessageId, title, dir}), prints
// {"sessionId": …} or {"error": …} and exits. No query is started.
//
// `node toasty-agent.mjs selftest` loads the SDK, checks the functions this
// bridge calls exist, prints {"ok": …} and exits. No query, no tokens.
//
// The SDK is the bundled copy unless TOASTY_SDK_PATH names another sdk.mjs
// (one Toasty downloaded to match the installed `claude`; see ClaudeSDK.swift).
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";

const out = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");

const sdkPath = process.env.TOASTY_SDK_PATH;
delete process.env.TOASTY_SDK_PATH; // Toasty's own; not for Claude Code.
const { query, forkSession } = await import(sdkPath ? pathToFileURL(sdkPath).href : "./claude-agent-sdk.mjs");

if (process.argv[2] === "selftest") {
  const ok = typeof query === "function" && typeof forkSession === "function";
  out({ ok });
  process.exit(ok ? 0 : 1);
}

if (process.argv[2] === "fork") {
  try {
    const a = JSON.parse(process.argv[3] ?? "{}");
    const r = await forkSession(a.sessionId, { dir: a.dir, upToMessageId: a.upToMessageId, title: a.title });
    out({ sessionId: r.sessionId });
  } catch (e) {
    out({ error: String(e?.message ?? e) });
  }
  process.exit(0);
}

// Streaming input: user messages are queued here and pulled by the SDK.
const inbox = [];
let wake = null;
let closed = false;
async function* prompts() {
  while (true) {
    while (inbox.length) yield inbox.shift();
    if (closed) return;
    await new Promise((r) => (wake = r));
    wake = null;
  }
}
const push = (m) => { inbox.push(m); wake?.(); };

const pending = new Map(); // permission request id -> resolve
let nextId = 1;
let q = null;

async function canUseTool(toolName, input, opts) {
  const id = String(nextId++);
  return new Promise((resolve) => {
    pending.set(id, resolve);
    opts.signal?.addEventListener("abort", () => {
      if (pending.delete(id)) {
        out({ type: "permission_cancel", id });
        resolve({ behavior: "deny", message: "Cancelled", interrupt: true });
      }
    });
    out({
      type: "permission_request", id, toolName, input,
      toolUseID: opts.toolUseID, suggestions: opts.suggestions ?? [],
      decisionReason: opts.decisionReason, blockedPath: opts.blockedPath,
      title: opts.title, description: opts.description, agentID: opts.agentID,
    });
  });
}

// MCP servers Toasty serves itself (the preview browser, only while the
// user has it turned on in Settings; `start` then lists it in `mcpServers`).
// The tools and what they do are Toasty's: this only relays. Each is an
// in-process server for the SDK, speaking the three MCP requests Claude
// Code makes; a tool call goes to Toasty as `mcp_call` and its answer comes
// back as `mcp_result`.
const mcpCalls = new Map(); // call id -> reply
function relayServer(def) {
  const connect = async (transport) => {
    transport.onmessage = (m) => {
      if (m?.id === undefined || m.id === null) return; // a notification
      const reply = (result) => transport.send({ jsonrpc: "2.0", id: m.id, result }).catch(() => {});
      switch (m.method) {
        case "initialize":
          reply({
            protocolVersion: m.params?.protocolVersion ?? "2025-06-18",
            capabilities: { tools: {} },
            serverInfo: { name: def.name, version: "1" },
            ...(def.instructions ? { instructions: def.instructions } : {}),
          });
          break;
        case "tools/list":
          reply({ tools: def.tools ?? [] });
          break;
        case "tools/call": {
          const id = String(nextId++);
          mcpCalls.set(id, reply);
          out({ type: "mcp_call", id, server: def.name, tool: m.params?.name, input: m.params?.arguments ?? {} });
          break;
        }
        case "ping":
          reply({});
          break;
        default:
          transport.send({ jsonrpc: "2.0", id: m.id, error: { code: -32601, message: "Method not found" } }).catch(() => {});
      }
    };
    await transport.start?.();
  };
  return { type: "sdk", name: def.name, instance: { connect } };
}

async function start(msg) {
  const options = {
    cwd: msg.cwd,
    // Behave exactly like the interactive CLI.
    systemPrompt: { type: "preset", preset: "claude_code" },
    tools: { type: "preset", preset: "claude_code" },
    settingSources: ["user", "project", "local"],
    includePartialMessages: true,
    // Like the CLI: a predicted next prompt after each turn (Claude Code
    // honors the user's promptSuggestionEnabled setting).
    promptSuggestions: true,
    canUseTool,
    // Claude Code leaves its Artifact tools out of SDK sessions unless asked
    // (the interactive CLI has them), and without them a claude.ai artifact
    // link can't be read. The user's own environment still decides.
    env: { CLAUDE_CODE_ARTIFACT: "1", ...process.env, CLAUDE_AGENT_SDK_CLIENT_APP: "toasty" },
    stderr: (data) => process.stderr.write(data),
    // Echo user messages on the stream, like `--replay-user-messages`: how
    // messages that didn't come from Toasty's composer (another session's
    // cross-session message, a prompt sent through Remote Control) show up
    // in the transcript where they happened. Output only; nothing changes
    // in what Claude Code does.
    extraArgs: { "replay-user-messages": null },
  };
  if (msg.pathToClaudeCodeExecutable) options.pathToClaudeCodeExecutable = msg.pathToClaudeCodeExecutable;
  if (msg.resume) options.resume = msg.resume;
  if (Array.isArray(msg.plugins) && msg.plugins.length) options.plugins = msg.plugins;
  for (const def of msg.mcpServers ?? []) (options.mcpServers ??= {})[def.name] = relayServer(def);

  q = query({ prompt: prompts(), options });
  out({ type: "ready" });
  // Claude Code's own model list (what /model offers), for the picker.
  // Always answered (empty if it failed): Toasty holds a conversation that
  // starts on another model than Claude Code's default until it arrives.
  q.supportedModels().then((models) => out({ type: "models", models }), () => out({ type: "models", models: [] }));
  // Claude Code's slash commands in this session (what typing / offers).
  q.supportedCommands().then((commands) => out({ type: "commands", commands }), () => {});
  // Whether Claude Code says Remote Control should start with the session
  // (the user's remoteControlAtStartup setting, as the CLI resolves it), so
  // Toasty can do what the interactive CLI does.
  q.initializationResult().then((init) => out({
    type: "remote_control_init",
    autoEnable: init?.remote_control_auto_enable === true,
    available: init?.remote_control_available !== false,
  }), () => {});
  try {
    for await (const m of q) out({ type: "sdk", message: m });
  } catch (e) {
    out({ type: "error", message: String(e?.message ?? e), fatal: true });
  }
  out({ type: "end" });
  process.exit(0);
}

const rl = createInterface({ input: process.stdin });
rl.on("line", async (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  try {
    switch (msg.type) {
      case "start":
        start(msg);
        break;
      case "user": {
        const content = [];
        for (const img of msg.images ?? []) {
          content.push({ type: "image", source: { type: "base64", media_type: img.media_type, data: img.data } });
        }
        if (msg.text) content.push({ type: "text", text: msg.text });
        push({
          type: "user",
          // Toasty's id for the prompt, so it can recognize the echo.
          ...(msg.uuid ? { uuid: msg.uuid } : {}),
          message: { role: "user", content: content.length === 1 && content[0].type === "text" ? msg.text : content },
          parent_tool_use_id: null,
        });
        break;
      }
      case "stop_task":
        await q?.stopTask(msg.taskId);
        break;
      case "interrupt":
        await q?.interrupt();
        break;
      case "permission_response": {
        const resolve = pending.get(msg.id);
        if (resolve) { pending.delete(msg.id); resolve(msg.response); }
        break;
      }
      case "mcp_result": {
        const reply = mcpCalls.get(msg.id);
        if (reply) { mcpCalls.delete(msg.id); reply(msg.result); }
        break;
      }
      case "set_model":
        await q?.setModel(msg.model);
        break;
      case "set_permission_mode":
        await q?.setPermissionMode(msg.mode);
        break;
      case "context_usage": {
        // What /context shows: how full the context window is.
        const usage = await q?.getContextUsage({ detail: "summary" });
        if (usage) {
          out({ type: "context_usage", usage: {
            totalTokens: usage.totalTokens, maxTokens: usage.maxTokens, percentage: usage.percentage,
            model: usage.model,
            categories: (usage.categories ?? []).map((c) => ({ name: c.name, tokens: c.tokens, kind: c.kind })),
          } });
        }
        break;
      }
      case "remote_control": {
        // Same request as /remote-control in the CLI.
        try {
          const r = await q?.enableRemoteControl(msg.enabled === true);
          out({ type: "remote_control", enabled: msg.enabled === true,
                sessionURL: r?.session_url, connectURL: r?.connect_url });
        } catch (e) {
          out({ type: "remote_control", enabled: false, error: String(e?.message ?? e) });
        }
        break;
      }
    }
  } catch (e) {
    out({ type: "error", message: String(e?.message ?? e) });
  }
});
rl.on("close", () => {
  // Toasty closed the tab or quit: end the session cleanly.
  closed = true;
  wake?.();
  for (const resolve of pending.values()) resolve({ behavior: "deny", message: "Cancelled", interrupt: true });
  pending.clear();
  setTimeout(() => process.exit(0), 2000);
});
