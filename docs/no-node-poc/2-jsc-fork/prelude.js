// Toasty translation layer: just enough of Node for the Agent SDK's file
// operations, backed by Swift (`__host`). Anything not provided throws a
// loud, named error when *called*, so a new SDK that needs more fails
// visibly instead of misbehaving.
(function () {
  const H = globalThis.__host;
  const missing = (mod, name) => function () { throw new Error(`toasty-jsc: ${mod}.${String(name)} is not available`); };
  const strict = (mod, obj) => new Proxy(obj, {
    get(t, k) { if (k in t) return t[k]; if (typeof k === "symbol" || k === "then") return undefined; return missing(mod, k); },
  });
  const fsError = (e) => { const err = new Error(e.message); err.code = e.code; err.errno = -1; err.syscall = e.syscall; err.path = e.path; return err; };
  const call = (fn, ...a) => { const r = H[fn](...a); if (r && r.__error) throw fsError(r.__error); return r; };
  const later = (fn) => Promise.resolve().then(fn);

  // ---- globals Node has and JavaScriptCore lacks
  globalThis.global = globalThis;
  globalThis.SharedArrayBuffer ??= ArrayBuffer;
  globalThis.DOMException ??= class DOMException extends Error { constructor(message = "", name = "Error") { super(message); this.name = name; } };
  // Web APIs the SDK references at load time but fork never uses: present
  // (so `class X extends Response` and `typeof fetch` work), loud if used.
  for (const name of ["Blob", "File", "FormData", "Headers", "Request", "Response", "ReadableStream", "WritableStream", "TransformStream", "MessageChannel", "MessagePort", "BroadcastChannel", "WebSocket", "Worker"]) {
    globalThis[name] ??= class { constructor() { throw new Error(`toasty-jsc: ${name} is not available`); } };
  }
  globalThis.fetch ??= () => Promise.reject(new Error("toasty-jsc: fetch is not available"));
  globalThis.navigator ??= { userAgent: "toasty-jsc", hardwareConcurrency: 4 };
  if (typeof URL === "undefined") {
    class URLSearchParams {
      constructor(q = "") { this.p = []; for (const kv of String(q).replace(/^\?/, "").split("&")) if (kv) { const [k, v = ""] = kv.split("="); this.p.push([decodeURIComponent(k), decodeURIComponent(v.replace(/\+/g, " "))]); } }
      get(k) { return this.p.find((x) => x[0] === k)?.[1] ?? null; } getAll(k) { return this.p.filter((x) => x[0] === k).map((x) => x[1]); }
      has(k) { return this.p.some((x) => x[0] === k); } set(k, v) { this.delete(k); this.p.push([k, String(v)]); } append(k, v) { this.p.push([k, String(v)]); }
      delete(k) { this.p = this.p.filter((x) => x[0] !== k); } forEach(f) { this.p.forEach(([k, v]) => f(v, k, this)); } entries() { return this.p[Symbol.iterator](); } [Symbol.iterator]() { return this.entries(); }
      toString() { return this.p.map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v)).join("&"); }
    }
    class URL {
      constructor(u, base) {
        u = String(u);
        if (base !== undefined && !/^[a-z][a-z0-9+.-]*:/i.test(u)) { const b = new URL(base); u = u.startsWith("/") ? `${b.protocol}//${b.host}${u}` : `${b.protocol}//${b.host}${b.pathname.replace(/[^/]*$/, "")}${u}`; }
        const m = /^([a-z][a-z0-9+.-]*:)(?:\/\/(?:([^:@/]*)(?::([^@/]*))?@)?([^:/?#]*)(?::(\d+))?)?([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(u);
        if (!m) throw new TypeError(`Invalid URL: ${u}`);
        this.protocol = m[1].toLowerCase(); this.username = m[2] ?? ""; this.password = m[3] ?? ""; this.hostname = m[4] ?? ""; this.port = m[5] ?? "";
        this.pathname = m[6] || (m[4] !== undefined ? "/" : ""); this.search = m[7] && m[7] !== "?" ? m[7] : ""; this.hash = m[8] && m[8] !== "#" ? m[8] : "";
        this.searchParams = new URLSearchParams(this.search);
      }
      get host() { return this.hostname + (this.port ? ":" + this.port : ""); }
      get origin() { return `${this.protocol}//${this.host}`; }
      get href() { const auth = this.username ? `${this.username}${this.password ? ":" + this.password : ""}@` : ""; const q = this.searchParams.toString(); return `${this.protocol}//${auth}${this.host}${this.pathname}${q ? "?" + q : ""}${this.hash}`; }
      toString() { return this.href; } toJSON() { return this.href; }
      static canParse(u, b) { try { new URL(u, b); return true; } catch { return false; } }
    }
    globalThis.URL = URL; globalThis.URLSearchParams = URLSearchParams;
  }
  globalThis.console = { log: (...a) => H.log(a.map(String).join(" ")), error: (...a) => H.log(a.map(String).join(" ")), warn: (...a) => H.log(a.map(String).join(" ")), info() {}, debug() {} };
  const timers = new Map(); let nextTimer = 1;
  globalThis.setTimeout = (fn, ms, ...a) => { const id = nextTimer++; timers.set(id, true); H.after(ms || 0, () => { if (timers.delete(id)) fn(...a); }); return { id, unref() { return this; }, ref() { return this; }, hasRef: () => false, [Symbol.toPrimitive]: () => id }; };
  globalThis.clearTimeout = (t) => { if (t) timers.delete(typeof t === "object" ? t.id : t); };
  globalThis.setInterval = (fn, ms) => { const h = { id: nextTimer++, unref() { return this; }, ref() { return this; } }; timers.set(h.id, true); const tick = () => H.after(ms, () => { if (timers.has(h.id)) { fn(); tick(); } }); tick(); return h; };
  globalThis.clearInterval = globalThis.clearTimeout;
  globalThis.setImmediate = (fn, ...a) => setTimeout(fn, 0, ...a);
  globalThis.clearImmediate = globalThis.clearTimeout;
  globalThis.performance = globalThis.performance ?? { now: () => H.now(), timeOrigin: Date.now() };
  globalThis.structuredClone = globalThis.structuredClone ?? ((v) => v === undefined ? v : JSON.parse(JSON.stringify(v)));

  class TextEncoder { get encoding() { return "utf-8"; } encode(s = "") { return H.encode(String(s)); } }
  class TextDecoder { constructor(enc = "utf-8") { this.encoding = enc; } decode(u8) { if (!u8) return ""; const v = u8 instanceof Uint8Array ? u8 : new Uint8Array(u8.buffer ?? u8, u8.byteOffset ?? 0, u8.byteLength); return H.decode(v, 0, v.length); } }
  globalThis.TextEncoder = globalThis.TextEncoder ?? TextEncoder;
  globalThis.TextDecoder = globalThis.TextDecoder ?? TextDecoder;

  class Event { constructor(type) { this.type = type; } }
  class EventTarget {
    #l = {};
    addEventListener(t, fn, o) { (this.#l[t] ??= []).push({ fn, once: o?.once }); }
    removeEventListener(t, fn) { this.#l[t] = (this.#l[t] ?? []).filter((x) => x.fn !== fn); }
    dispatchEvent(e) { for (const x of [...(this.#l[e.type] ?? [])]) { if (x.once) this.removeEventListener(e.type, x.fn); x.fn.call(this, e); } return true; }
  }
  class AbortSignal extends EventTarget {
    aborted = false; reason = undefined; onabort = null;
    throwIfAborted() { if (this.aborted) throw this.reason; }
    static abort(r) { const c = new AbortController(); c.abort(r); return c.signal; }
    static timeout() { return new AbortController().signal; }
    static any(signals) { const c = new AbortController(); for (const s of signals) s.addEventListener("abort", () => c.abort(s.reason)); return c.signal; }
  }
  class AbortController {
    signal = new AbortSignal();
    abort(r) { const s = this.signal; if (s.aborted) return; s.aborted = true; s.reason = r ?? Object.assign(new Error("This operation was aborted"), { name: "AbortError" }); s.onabort?.(new Event("abort")); s.dispatchEvent(new Event("abort")); }
  }
  globalThis.Event ??= Event; globalThis.EventTarget ??= EventTarget;
  globalThis.AbortSignal ??= AbortSignal; globalThis.AbortController ??= AbortController;

  // ---- Buffer (the subset of Node's Buffer the SDK uses)
  class Buffer extends Uint8Array {
    static from(v, enc) {
      if (typeof v === "string") { if (enc === "base64") return Buffer.#wrap(H.fromBase64(v)); if (enc === "hex") { const b = new Buffer(v.length / 2); for (let i = 0; i < b.length; i++) b[i] = parseInt(v.substr(i * 2, 2), 16); return b; } return Buffer.#wrap(H.encode(v)); }
      if (v instanceof ArrayBuffer) return new Buffer(v, enc ?? 0, arguments[2] ?? v.byteLength - (enc ?? 0));
      if (ArrayBuffer.isView(v)) return Buffer.#wrap(new Uint8Array(v.buffer, v.byteOffset, v.byteLength).slice());
      if (Array.isArray(v)) { const b = new Buffer(v.length); b.set(v); return b; }
      throw new TypeError("toasty-jsc: Buffer.from unsupported input");
    }
    static #wrap(u8) { return new Buffer(u8.buffer, u8.byteOffset, u8.byteLength); }
    static alloc(n, fill) { const b = new Buffer(n); if (fill !== undefined) b.fill(fill); return b; }
    static allocUnsafe(n) { return new Buffer(n); }
    static isBuffer(b) { return b instanceof Buffer; }
    static byteLength(s, enc) { return typeof s === "string" ? (enc === "base64" ? Math.floor(s.replace(/=+$/, "").length * 3 / 4) : H.utf8Length(s)) : s.byteLength; }
    static concat(list, total) { total ??= list.reduce((n, b) => n + b.length, 0); const out = new Buffer(total); let o = 0; for (const b of list) { out.set(b.subarray(0, Math.min(b.length, total - o)), o); o += b.length; if (o >= total) break; } return out; }
    toString(enc = "utf8", start = 0, end = this.length) {
      start = Math.max(0, start | 0); end = Math.min(this.length, end ?? this.length);
      if (enc === "base64") return H.toBase64(this.subarray(start, end));
      if (enc === "hex") { let s = ""; for (let i = start; i < end; i++) s += this[i].toString(16).padStart(2, "0"); return s; }
      return H.decode(this, start, end);
    }
    subarray(a, b) { const u = Uint8Array.prototype.subarray.call(this, a, b); return new Buffer(u.buffer, u.byteOffset, u.byteLength); }
    slice(a, b) { return this.subarray(a, b); }
    equals(o) { if (o.length !== this.length) return false; for (let i = 0; i < this.length; i++) if (o[i] !== this[i]) return false; return true; }
    write(s, offset = 0) { const e = H.encode(s); this.set(e.subarray(0, this.length - offset), offset); return Math.min(e.length, this.length - offset); }
    indexOf(v, from = 0) { if (typeof v === "number") return Uint8Array.prototype.indexOf.call(this, v, from); const n = typeof v === "string" ? H.encode(v) : v; outer: for (let i = from; i <= this.length - n.length; i++) { for (let j = 0; j < n.length; j++) if (this[i + j] !== n[j]) continue outer; return i; } return -1; }
    lastIndexOf(v, from = this.length - 1) { if (typeof v === "number") return Uint8Array.prototype.lastIndexOf.call(this, v, from); const n = typeof v === "string" ? H.encode(v) : v; for (let i = Math.min(from, this.length - n.length); i >= 0; i--) { let ok = true; for (let j = 0; j < n.length; j++) if (this[i + j] !== n[j]) { ok = false; break; } if (ok) return i; } return -1; }
    includes(v, from) { return this.indexOf(v, from) !== -1; }
    toJSON() { return { type: "Buffer", data: Array.from(this) }; }
  }
  globalThis.Buffer = Buffer;
  globalThis.atob ??= (s) => String.fromCharCode(...Buffer.from(s, "base64"));
  globalThis.btoa ??= (s) => Buffer.from(Array.from(s, (c) => c.charCodeAt(0))).toString("base64");

  // ---- process
  const env = H.env();
  globalThis.process = {
    env, platform: "darwin", arch: H.arch(), pid: 1, ppid: 0, argv: ["node", "sdk"], execArgv: [], execPath: "/usr/local/bin/node",
    version: "v22.19.0", versions: { node: "22.19.0" }, release: { name: "node" }, exitCode: undefined,
    cwd: () => H.cwd(), chdir() {}, umask: () => 0o22, uptime: () => H.now() / 1000,
    hrtime: Object.assign((p) => { const n = H.now(); const s = Math.floor(n / 1000), ns = Math.floor((n % 1000) * 1e6); return p ? [s - p[0], ns - p[1]] : [s, ns]; }, { bigint: () => BigInt(Math.floor(H.now() * 1e6)) }),
    memoryUsage: Object.assign(() => ({ rss: 0, heapTotal: 0, heapUsed: 0, external: 0 }), { rss: () => 0 }),
    nextTick: (fn, ...a) => queueMicrotask(() => fn(...a)),
    on() { return this; }, once() { return this; }, off() { return this; }, addListener() { return this; }, removeListener() { return this; }, removeAllListeners() { return this; }, emit() { return false; }, listeners: () => [], listenerCount: () => 0, setMaxListeners() { return this; },
    emitWarning() {}, exit(c) { throw new Error(`toasty-jsc: process.exit(${c})`); }, kill() { return false; },
    getuid: () => 501, getgid: () => 20, geteuid: () => 501,
    stdout: { write: (s) => (H.log(String(s)), true), isTTY: false, columns: 80, on() {}, once() {} },
    stderr: { write: (s) => (H.log(String(s)), true), isTTY: false, on() {}, once() {} },
    stdin: { isTTY: false, on() {}, once() {} },
    features: {}, config: { variables: {} },
  };

  // ---- path (POSIX)
  const normArray = (parts, abs) => { const out = []; for (const p of parts) { if (!p || p === ".") continue; if (p === "..") { if (out.length && out.at(-1) !== "..") out.pop(); else if (!abs) out.push(".."); } else out.push(p); } return out; };
  const path = {
    sep: "/", delimiter: ":",
    isAbsolute: (p) => p.startsWith("/"),
    normalize(p) { if (p === "") return "."; const abs = p.startsWith("/"), trail = p.endsWith("/"); let r = normArray(p.split("/"), abs).join("/"); if (!r && !abs) r = "."; if (r && trail) r += "/"; return (abs ? "/" : "") + r; },
    join: (...a) => { const j = a.filter((x) => x !== "").join("/"); return j ? path.normalize(j) : "."; },
    resolve(...a) { let r = ""; for (let i = a.length - 1; i >= 0 && !r.startsWith("/"); i--) if (a[i]) r = a[i] + (r ? "/" + r : ""); if (!r.startsWith("/")) r = H.cwd() + (r ? "/" + r : ""); const n = "/" + normArray(r.split("/"), true).join("/"); return n; },
    dirname(p) { if (!p) return "."; const s = p.replace(/\/+$/, ""); const i = s.lastIndexOf("/"); if (i === -1) return "."; if (i === 0) return "/"; return s.slice(0, i); },
    basename(p, ext) { let b = p.replace(/\/+$/, ""); b = b.slice(b.lastIndexOf("/") + 1); if (ext && b.endsWith(ext) && b !== ext) b = b.slice(0, -ext.length); return b; },
    extname(p) { const b = path.basename(p); const i = b.lastIndexOf("."); return i <= 0 ? "" : b.slice(i); },
    relative(from, to) { const f = path.resolve(from).split("/").filter(Boolean), t = path.resolve(to).split("/").filter(Boolean); let i = 0; while (i < f.length && i < t.length && f[i] === t[i]) i++; return [...Array(f.length - i).fill(".."), ...t.slice(i)].join("/"); },
    parse(p) { const root = p.startsWith("/") ? "/" : ""; const base = path.basename(p), ext = path.extname(p); return { root, dir: path.dirname(p), base, ext, name: ext ? base.slice(0, -ext.length) : base }; },
    format: (o) => (o.dir ? o.dir + "/" : o.root ?? "") + (o.base ?? (o.name ?? "") + (o.ext ?? "")),
    toNamespacedPath: (p) => p,
  };
  path.posix = path;
  path.win32 = path;

  // ---- events
  class EventEmitter {
    _e = {};
    on(t, f) { (this._e[t] ??= []).push(f); return this; }
    addListener(t, f) { return this.on(t, f); }
    prependListener(t, f) { (this._e[t] ??= []).unshift(f); return this; }
    once(t, f) { const w = (...a) => { this.off(t, w); f(...a); }; w.f = f; return this.on(t, w); }
    off(t, f) { this._e[t] = (this._e[t] ?? []).filter((x) => x !== f && x.f !== f); return this; }
    removeListener(t, f) { return this.off(t, f); }
    removeAllListeners(t) { if (t) delete this._e[t]; else this._e = {}; return this; }
    emit(t, ...a) { const l = this._e[t]; if (!l?.length) { if (t === "error") throw a[0]; return false; } for (const f of [...l]) f.apply(this, a); return true; }
    listeners(t) { return [...(this._e[t] ?? [])]; }
    listenerCount(t) { return (this._e[t] ?? []).length; }
    setMaxListeners() { return this; } getMaxListeners() { return 10; }
  }
  const once = (em, name) => new Promise((res, rej) => { em.once(name, (...a) => res(a)); if (name !== "error") em.once("error", rej); });
  const events = Object.assign(EventEmitter, { EventEmitter, once, default: EventEmitter, setMaxListeners() {}, on: missing("events", "on") });

  // ---- fs
  const statObj = (s) => s && ({ ...s, mtime: new Date(s.mtimeMs), ctime: new Date(s.ctimeMs ?? s.mtimeMs), atime: new Date(s.mtimeMs), birthtime: new Date(s.birthtimeMs ?? s.mtimeMs), isFile: () => s.kind === "file", isDirectory: () => s.kind === "dir", isSymbolicLink: () => s.kind === "link", isFIFO: () => false, isSocket: () => false, isBlockDevice: () => false, isCharacterDevice: () => false });
  const dirent = (d, parent) => ({ name: d.name, parentPath: parent, path: parent, isFile: () => d.kind === "file", isDirectory: () => d.kind === "dir", isSymbolicLink: () => d.kind === "link", isFIFO: () => false, isSocket: () => false, isBlockDevice: () => false, isCharacterDevice: () => false });
  const toPath = (p) => typeof p === "string" ? p : p instanceof URL ? p.pathname : p?.href ? decodeURIComponent(new URL(p.href).pathname) : String(p);
  const enc = (o) => typeof o === "string" ? o : o?.encoding;
  const dataOf = (d) => typeof d === "string" ? H.encode(d) : d instanceof Uint8Array ? d : new Uint8Array(d.buffer ?? d, d.byteOffset ?? 0, d.byteLength);
  const sync = {
    readFileSync(p, o) { const b = call("readBytes", toPath(p)); const buf = new Buffer(b.buffer, b.byteOffset, b.byteLength); const e = enc(o); return e ? buf.toString(e) : buf; },
    writeFileSync(p, d, o) { call("writeBytes", toPath(p), dataOf(d), typeof o === "object" && o?.flag === "a"); },
    appendFileSync(p, d) { call("writeBytes", toPath(p), dataOf(d), true); },
    existsSync(p) { return !!H.stat(toPath(p), true) && !H.stat(toPath(p), true).__error; },
    statSync(p, o) { const s = H.stat(toPath(p), true); if (s.__error) { if (o?.throwIfNoEntry === false) return undefined; throw fsError(s.__error); } return statObj(s); },
    lstatSync(p, o) { const s = H.stat(toPath(p), false); if (s.__error) { if (o?.throwIfNoEntry === false) return undefined; throw fsError(s.__error); } return statObj(s); },
    readdirSync(p, o) { const l = call("readdir", toPath(p)); return o?.withFileTypes ? l.map((d) => dirent(d, toPath(p))) : l.map((d) => d.name); },
    mkdirSync(p, o) { call("mkdir", toPath(p), !!o?.recursive); },
    realpathSync: Object.assign((p) => call("realpath", toPath(p)), { native: (p) => call("realpath", toPath(p)) }),
    readlinkSync(p) { return call("readlink", toPath(p)); },
    renameSync(a, b) { call("rename", toPath(a), toPath(b)); },
    unlinkSync(p) { call("unlink", toPath(p)); },
    rmSync(p) { call("unlink", toPath(p)); },
    accessSync(p) { const s = H.stat(toPath(p), true); if (s.__error) throw fsError(s.__error); },
  };
  const promises = {
    readFile: async (p, o) => sync.readFileSync(p, o),
    writeFile: async (p, d, o) => sync.writeFileSync(p, d, o),
    appendFile: async (p, d) => sync.appendFileSync(p, d),
    stat: async (p) => sync.statSync(p), lstat: async (p) => sync.lstatSync(p),
    readdir: async (p, o) => sync.readdirSync(p, o),
    mkdir: async (p, o) => sync.mkdirSync(p, o),
    realpath: async (p) => sync.realpathSync(p),
    readlink: async (p) => sync.readlinkSync(p),
    rename: async (a, b) => sync.renameSync(a, b),
    unlink: async (p) => sync.unlinkSync(p), rm: async (p) => sync.rmSync(p),
    access: async (p) => sync.accessSync(p),
    open: async (p, flags = "r") => {
      const file = toPath(p);
      if (flags !== "r") throw new Error(`toasty-jsc: fs.open flags ${flags} not available`);
      const all = sync.readFileSync(file);
      return {
        fd: 3,
        stat: async () => sync.statSync(file),
        read: async (buf, off = 0, len, pos) => { if (typeof buf === "object" && !ArrayBuffer.isView(buf)) ({ buffer: buf, offset: off = 0, length: len, position: pos } = buf); len ??= buf.length - off; const start = pos ?? 0; const chunk = all.subarray(start, start + len); buf.set(chunk, off); return { bytesRead: chunk.length, buffer: buf }; },
        readFile: async (o) => (enc(o) ? all.toString(enc(o)) : all),
        close: async () => {},
      };
    },
    constants: { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 },
  };
  class WriteStream extends EventEmitter {
    constructor(p, o) { super(); this.path = toPath(p); this.flags = o?.flags ?? "w"; this.chunks = []; this.writable = true; }
    write(d, e, cb) { this.chunks.push(dataOf(d)); if (typeof e === "function") e(); else cb?.(); return true; }
    end(d, cb) { if (typeof d === "function") { cb = d; d = undefined; } if (d) this.write(d); this.writable = false; later(() => { try { call("writeBytes", this.path, Buffer.concat(this.chunks), this.flags === "a"); this.emit("finish"); this.emit("close"); cb?.(); } catch (e) { this.emit("error", e); } }); return this; }
    destroy(e) { this.writable = false; if (e) later(() => this.emit("error", e)); return this; }
  }
  const fs = { ...sync, promises, constants: promises.constants, createWriteStream: (p, o) => new WriteStream(p, o) };

  // ---- crypto, os, util, misc
  const crypto = {
    randomUUID: () => H.uuid(),
    randomBytes: (n) => { const b = Buffer.from(H.randomBytes(n)); return b; },
    getRandomValues: (a) => { a.set(H.randomBytes(a.byteLength)); return a; },
    createHash: (alg) => { const parts = []; const h = { update(d, e) { parts.push(typeof d === "string" ? H.encode(d) : d); return h; }, digest(e) { const out = Buffer.from(H.hash(alg, Buffer.concat(parts))); return e ? out.toString(e) : out; } }; return h; },
  };
  crypto.webcrypto = { randomUUID: crypto.randomUUID, getRandomValues: crypto.getRandomValues };
  globalThis.crypto ??= crypto.webcrypto;
  const os = { homedir: () => H.home(), tmpdir: () => H.tmp(), platform: () => "darwin", type: () => "Darwin", release: () => H.osRelease(), arch: () => H.arch(), EOL: "\n", hostname: () => "localhost", cpus: () => [{}], totalmem: () => 0, freemem: () => 0, userInfo: () => ({ username: "user", homedir: H.home() }), constants: { signals: {} }, availableParallelism: () => 4 };
  const util = {
    promisify: (fn) => (...a) => new Promise((res, rej) => fn(...a, (e, v) => (e ? rej(e) : res(v)))),
    inspect: Object.assign((v) => { try { return typeof v === "string" ? v : JSON.stringify(v); } catch { return String(v); } }, { custom: Symbol.for("nodejs.util.inspect.custom") }),
    format: (...a) => a.map(String).join(" "),
    types: { isPromise: (p) => p instanceof Promise, isDate: (d) => d instanceof Date, isRegExp: (r) => r instanceof RegExp, isNativeError: (e) => e instanceof Error },
    isDeepStrictEqual: (a, b) => JSON.stringify(a) === JSON.stringify(b),
    deprecate: (f) => f, inherits(c, p) { Object.setPrototypeOf(c.prototype, p.prototype); },
    TextDecoder, TextEncoder,
    stripVTControlCharacters: (s) => s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, ""),
  };
  class AsyncLocalStorage { #s; getStore() { return this.#s; } run(s, fn, ...a) { const p = this.#s; this.#s = s; try { return fn(...a); } finally { this.#s = p; } } enterWith(s) { this.#s = s; } disable() {} }
  class StringDecoder { constructor() { this.pending = new Uint8Array(0); } write(b) { const all = new Uint8Array(this.pending.length + b.length); all.set(this.pending); all.set(b, this.pending.length); let end = all.length, i = end - 1, back = 0; while (i >= 0 && back < 4 && (all[i] & 0xc0) === 0x80) { i--; back++; } if (i >= 0) { const c = all[i]; const need = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc0 ? 2 : 1; if (end - i < need) end = i; } this.pending = all.slice(end); return H.decode(all, 0, end); } end(b) { let s = b ? this.write(b) : ""; if (this.pending.length) s += H.decode(this.pending, 0, this.pending.length); this.pending = new Uint8Array(0); return s; } }
  const url = { fileURLToPath: (u) => decodeURIComponent((typeof u === "string" ? u : u.href).replace(/^file:\/\//, "")), pathToFileURL: (p) => ({ href: "file://" + encodeURI(path.resolve(p)), pathname: path.resolve(p), protocol: "file:", toString() { return this.href; } }), URL: globalThis.URL };
  const moduleMod = { createRequire: () => Object.assign((id) => { throw new Error(`toasty-jsc: require(${id}) is not available`); }, { resolve: missing("module", "require.resolve") }), builtinModules: [] };

  const modules = {
    path, fs, "fs/promises": promises, crypto, os, util, events, url, module: moduleMod, buffer: { Buffer },
    async_hooks: { AsyncLocalStorage, AsyncResource: class { runInAsyncScope(fn, t, ...a) { return fn.apply(t, a); } static bind(f) { return f; } } },
    string_decoder: { StringDecoder }, process: globalThis.process,
    child_process: {}, net: {}, readline: {},
  };
  globalThis.__node = (name) => {
    const m = modules[name.replace(/^node:/, "")];
    if (!m) throw new Error(`toasty-jsc: module ${name} is not available`);
    return strict(name, m);
  };
})();
