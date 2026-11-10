import Foundation

/// The JavaScript the preview puts in a page.
enum PreviewScripts {
    /// Message handler names (`window.webkit.messageHandlers.<name>`).
    static let consoleHandler = "toastyConsole"
    static let pickerHandler = "toastyPicker"

    /// Runs in the page's own world before its scripts: copies console
    /// output, uncaught errors, failed resource loads and failed requests to
    /// Toasty. The page's console still gets everything.
    static let console = #"""
    (() => {
      if (window.__toastyConsole) return;
      window.__toastyConsole = true;
      const handler = window.webkit?.messageHandlers?.toastyConsole;
      if (!handler) return;
      const fmt = (v) => {
        if (typeof v === "string") return v;
        if (v instanceof Error) return v.stack || String(v);
        if (v instanceof Element) return v.outerHTML.slice(0, 200);
        try {
          const seen = new WeakSet();
          const s = JSON.stringify(v, (k, x) => {
            if (typeof x === "object" && x !== null) { if (seen.has(x)) return "[circular]"; seen.add(x); }
            if (typeof x === "function") return "[function]";
            if (typeof x === "bigint") return String(x);
            return x;
          });
          return s === undefined ? String(v) : s;
        } catch { return String(v); }
      };
      const post = (level, parts) => {
        try { handler.postMessage({ level, text: parts.map(fmt).join(" ").slice(0, 4000) }); } catch {}
      };
      for (const level of ["log", "info", "warn", "error", "debug"]) {
        const original = console[level];
        console[level] = function (...args) { post(level, args); return original.apply(this, args); };
      }
      addEventListener("error", (e) => {
        const t = e.target;
        if (t && t !== window && (t.src || t.href)) post("error", ["Failed to load " + (t.src || t.href)]);
        else post("error", [(e.message || "Error") + (e.filename ? ` (${e.filename}:${e.lineno}:${e.colno})` : "")]);
      }, true);
      addEventListener("unhandledrejection", (e) => post("error", ["Unhandled promise rejection: " + fmt(e.reason)]));
      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = async function (input, init) {
          const url = typeof input === "string" ? input : (input && input.url) || String(input);
          const method = (init && init.method) || (input && input.method) || "GET";
          try {
            const response = await originalFetch.apply(this, arguments);
            if (!response.ok) post("error", [`${method} ${url} answered ${response.status}`]);
            return response;
          } catch (err) {
            post("error", [`${method} ${url} failed: ${(err && err.message) || err}`]);
            throw err;
          }
        };
      }
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.addEventListener("loadend", () => {
          if (this.status === 0) post("error", [`${method} ${url} failed`]);
          else if (this.status >= 400) post("error", [`${method} ${url} answered ${this.status}`]);
        });
        return open.apply(this, arguments);
      };
    })();
    """#

    /// Runs in a world of Toasty's own (the page can't see or break it):
    /// while commenting, the element under the pointer is outlined; a click
    /// picks it, a drag picks an area, Esc leaves. The pick stays outlined
    /// (so it shows in the screenshot) until `resume()` or `stop()`.
    static let picker = #"""
    (() => {
      if (window.__toastyPicker) return;
      const post = (m) => { try { window.webkit.messageHandlers.toastyPicker.postMessage(m); } catch {} };
      const ACCENT = "#0A84FF";
      let box = null, style = null, active = false, frozen = false;
      let down = null, dragging = false, hovered = null;

      const ensureBox = () => {
        if (box && box.isConnected) return box;
        box = document.createElement("div");
        box.setAttribute("data-toasty-preview", "");
        Object.assign(box.style, {
          position: "fixed", zIndex: "2147483647", pointerEvents: "none", boxSizing: "border-box",
          border: `2px solid ${ACCENT}`, background: "rgba(10,132,255,0.12)", borderRadius: "3px",
          display: "none", margin: "0", padding: "0", transition: "none",
        });
        document.documentElement.appendChild(box);
        return box;
      };
      const show = (r) => {
        const b = ensureBox();
        Object.assign(b.style, { display: "block", left: r.x + "px", top: r.y + "px", width: r.width + "px", height: r.height + "px" });
      };
      const hide = () => { if (box) box.style.display = "none"; };

      const unique = (sel) => { try { return document.querySelectorAll(sel).length === 1; } catch { return false; } };
      const esc = (s) => CSS.escape(s);
      const step = (el) => {
        const tag = el.tagName.toLowerCase();
        const classes = [...el.classList].filter((c) => /^[A-Za-z_-][\w-]*$/.test(c)).slice(0, 2);
        return tag + classes.map((c) => "." + esc(c)).join("");
      };
      const selector = (el) => {
        if (!(el instanceof Element)) return "";
        if (el.id && unique("#" + esc(el.id))) return "#" + esc(el.id);
        const test = el.getAttribute("data-testid");
        if (test && unique(`[data-testid="${test}"]`)) return `[data-testid="${test}"]`;
        const parts = [];
        let node = el;
        for (let depth = 0; node && node !== document.documentElement && depth < 5; depth++) {
          let part = step(node);
          const parent = node.parentElement;
          if (parent) {
            const same = [...parent.children].filter((c) => c.tagName === node.tagName);
            if (same.length > 1 && !unique([part, ...parts].join(" > "))) part += `:nth-of-type(${same.indexOf(node) + 1})`;
          }
          parts.unshift(part);
          const candidate = parts.join(" > ");
          if (unique(candidate)) return candidate;
          if (parent && parent.id && unique("#" + esc(parent.id))) return "#" + esc(parent.id) + " > " + candidate;
          node = parent;
        }
        return parts.join(" > ");
      };
      const label = (el) => {
        const text = (el.innerText || el.getAttribute("aria-label") || el.getAttribute("alt")
          || el.getAttribute("placeholder") || el.value || "").replace(/\s+/g, " ").trim();
        return text.length > 60 ? text.slice(0, 57) + "…" : text;
      };
      const describe = (el, rect, kind) => ({
        kind,
        selector: selector(el),
        tag: el.tagName.toLowerCase(),
        text: label(el),
        rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
        viewport: { width: innerWidth, height: innerHeight },
        url: location.href,
      });
      const under = (x, y) => {
        const el = document.elementFromPoint(x, y);
        return el && !el.hasAttribute("data-toasty-preview") ? el : null;
      };
      const swallow = (e) => { e.preventDefault(); e.stopImmediatePropagation(); };

      const onMove = (e) => {
        if (!active) return;
        swallow(e);
        if (frozen) return;
        if (down && (dragging || Math.hypot(e.clientX - down.x, e.clientY - down.y) > 6)) {
          dragging = true;
          show({ x: Math.min(down.x, e.clientX), y: Math.min(down.y, e.clientY),
                 width: Math.abs(e.clientX - down.x), height: Math.abs(e.clientY - down.y) });
          return;
        }
        hovered = under(e.clientX, e.clientY);
        if (hovered) show(hovered.getBoundingClientRect()); else hide();
      };
      const onDown = (e) => {
        if (!active) return;
        swallow(e);
        if (frozen || e.button !== 0) return;
        down = { x: e.clientX, y: e.clientY };
        dragging = false;
      };
      const onUp = (e) => {
        if (!active) return;
        swallow(e);
        if (frozen || !down) return;
        const start = down;
        down = null;
        if (dragging) {
          dragging = false;
          const rect = { x: Math.min(start.x, e.clientX), y: Math.min(start.y, e.clientY),
                         width: Math.abs(e.clientX - start.x), height: Math.abs(e.clientY - start.y) };
          const el = under(rect.x + rect.width / 2, rect.y + rect.height / 2) || document.body;
          frozen = true;
          show(rect);
          post(describe(el, rect, "area"));
          return;
        }
        const el = under(e.clientX, e.clientY);
        if (!el) return;
        const rect = el.getBoundingClientRect();
        frozen = true;
        show(rect);
        post(describe(el, rect, "element"));
      };
      const onKey = (e) => {
        if (!active) return;
        if (e.key === "Escape") { swallow(e); post({ kind: "cancel" }); }
      };
      // Pointer events do the work: cancelling pointerdown (which keeps the
      // page from reacting) also keeps the mouse events from being sent.
      const block = (e) => { if (active) swallow(e); };
      const events = { pointermove: onMove, pointerdown: onDown, pointerup: onUp, keydown: onKey,
                       mousemove: block, mousedown: block, mouseup: block, click: block, dblclick: block,
                       contextmenu: block };

      window.__toastyPicker = {
        start() {
          if (active) { this.resume(); return; }
          active = true; frozen = false; down = null; dragging = false;
          for (const [name, fn] of Object.entries(events)) addEventListener(name, fn, true);
          style = document.createElement("style");
          style.setAttribute("data-toasty-preview", "");
          style.textContent = "* { cursor: crosshair !important; }";
          document.documentElement.appendChild(style);
        },
        resume() { frozen = false; down = null; dragging = false; hide(); },
        stop() {
          active = false; frozen = false;
          for (const [name, fn] of Object.entries(events)) removeEventListener(name, fn, true);
          if (style) { style.remove(); style = null; }
          if (box) { box.remove(); box = null; }
        },
      };
    })();
    """#

    /// A click the page's own handlers see as real as a script's can be.
    /// Body of an async function with `selector`.
    static let click = #"""
    const el = document.querySelector(selector);
    if (!el) throw new Error("No element matches " + selector);
    el.scrollIntoView({ block: "center", inline: "center" });
    const r = el.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, view: window, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2, button: 0 };
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup"]) {
      el.dispatchEvent(new (type.startsWith("pointer") ? PointerEvent : MouseEvent)(type, at));
    }
    if (typeof el.focus === "function") el.focus();
    el.click();
    return el.tagName.toLowerCase();
    """#

    /// Fills a field the way frameworks notice (the native value setter,
    /// then input and change). Body of an async function with `selector`,
    /// `text` and `enter`.
    static let type = #"""
    const el = document.querySelector(selector);
    if (!el) throw new Error("No element matches " + selector);
    el.scrollIntoView({ block: "center", inline: "center" });
    el.focus();
    if (el.isContentEditable) {
      el.textContent = text;
      el.dispatchEvent(new InputEvent("input", { bubbles: true, data: text, inputType: "insertText" }));
    } else if ("value" in el) {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
        : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
      if (setter) setter.call(el, text); else el.value = text;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    } else {
      throw new Error(selector + " isn't a field that takes text");
    }
    if (enter) {
      const key = { bubbles: true, cancelable: true, key: "Enter", code: "Enter", keyCode: 13, which: 13 };
      const went = el.dispatchEvent(new KeyboardEvent("keydown", key));
      el.dispatchEvent(new KeyboardEvent("keyup", key));
      if (went && el.form) el.form.requestSubmit();
    }
    return el.tagName.toLowerCase();
    """#
}
