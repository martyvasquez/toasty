// Toasty: bridge between a Claude conversation tab and the Claude Agent SDK.
//
// Deliberately minimal: it starts one SDK query configured to behave like
// the interactive CLI (Claude Code system prompt + tools presets, user /
// project / local settings, the installed `claude` executable) and relays
// JSON lines over stdio. It makes no decisions of its own.
//
// stdin  (from Toasty): start | user | interrupt | permission_response | set_permission_mode | set_model
//                       | remote_control
// stdout (to Toasty):   ready | sdk | models | permission_request | permission_cancel | error | end
//                       | remote_control_init | remote_control
import { createInterface } from "node:readline";
import { query } from "./claude-agent-sdk.mjs";

const out = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");

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

async function start(msg) {
  const options = {
    cwd: msg.cwd,
    // Behave exactly like the interactive CLI.
    systemPrompt: { type: "preset", preset: "claude_code" },
    tools: { type: "preset", preset: "claude_code" },
    settingSources: ["user", "project", "local"],
    includePartialMessages: true,
    canUseTool,
    env: { ...process.env, CLAUDE_AGENT_SDK_CLIENT_APP: "toasty" },
    stderr: (data) => process.stderr.write(data),
  };
  if (msg.pathToClaudeCodeExecutable) options.pathToClaudeCodeExecutable = msg.pathToClaudeCodeExecutable;
  if (msg.resume) options.resume = msg.resume;
  if (Array.isArray(msg.plugins) && msg.plugins.length) options.plugins = msg.plugins;

  q = query({ prompt: prompts(), options });
  out({ type: "ready" });
  // Claude Code's own model list (what /model offers), for the picker.
  q.supportedModels().then((models) => out({ type: "models", models }), () => {});
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
          message: { role: "user", content: content.length === 1 && content[0].type === "text" ? msg.text : content },
          parent_tool_use_id: null,
        });
        break;
      }
      case "interrupt":
        await q?.interrupt();
        break;
      case "permission_response": {
        const resolve = pending.get(msg.id);
        if (resolve) { pending.delete(msg.id); resolve(msg.response); }
        break;
      }
      case "set_model":
        await q?.setModel(msg.model);
        break;
      case "set_permission_mode":
        await q?.setPermissionMode(msg.mode);
        break;
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
