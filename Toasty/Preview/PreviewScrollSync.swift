import AppKit
import WebKit

/// Scroll sync (experiment, the user 2026-11-21): in side by side, scrolling
/// either page scrolls the other to the same place. Not by percentage (a
/// phone layout is much taller): the page scrolled reports the element at
/// its reading line, as a path of child indices (and tags) from the body or
/// from the nearest element with an id, with how far into it the line is,
/// and the same for each of its ancestors. The other page finds the deepest
/// of those that it has and shows, and scrolls so the same point of it is
/// at its own reading line. Inner scrolling areas (a div with overflow)
/// work the same way: the other page scrolls the same area, or, if its
/// layout scrolls something else there, whatever does scroll around the
/// element. The top and the bottom of a page map to the top and bottom.
///
/// Everything lives in this file, in a content world of its own; the
/// session only installs it on both web views and forwards messages.
@MainActor
final class PreviewScrollSync {
    static let handler = "toastyScroll"
    static let world = WKContentWorld.world(name: "ToastyScrollSync")
    static let enabledKey = "PreviewScrollSync"

    weak var main: WKWebView?
    weak var twin: WKWebView?
    /// Which page the user is scrolling, and when it last moved: the other
    /// page's scrolling is ours (an echo) until it has been still a moment.
    private var leader: ObjectIdentifier?
    private var leaderAt = Date.distantPast
    /// Whether the scroll going on now syncs: always with the footer's lock
    /// on; otherwise while ⌘ is held as it starts. Decided when scrolling starts and kept until it
    /// has stopped a moment, so letting go of ⌘ mid-flick doesn't cut the
    /// momentum off.
    private var gestureSyncs = false
    private var lastScrollAt = Date.distantPast

    /// Puts the script and its message handler on a web view's configuration.
    static func install(on configuration: WKWebViewConfiguration, relay: WKScriptMessageHandler) {
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: world))
        content.add(relay, contentWorld: world, name: handler)
    }

    /// A page scrolled (by the user, or as the other page's echo).
    func scrolled(in web: WKWebView, _ body: Any, syncOn: Bool) {
        guard let main, let twin else { return }
        if (body as? [String: Any])?["kind"] as? String == "layout" { scheduleRebuild(); return }
        let id = ObjectIdentifier(web)
        let now = Date()
        if now.timeIntervalSince(lastScrollAt) > 0.25 {
            gestureSyncs = syncOn || NSEvent.modifierFlags.contains(.command)
        }
        lastScrollAt = now
        guard gestureSyncs else { return }
        if let leader, leader != id, now.timeIntervalSince(leaderAt) < 0.12 { return }
        leader = id
        leaderAt = now
        let other = web === main ? twin : main
        if (body as? [String: Any])?["kind"] as? String == "map" {
            other.callAsyncJavaScript("window.__toastyScroll?.follow(s)", arguments: ["s": body], in: nil,
                                      in: Self.world, completionHandler: nil)
        } else {
            apply(body, to: other)
        }
    }

    // MARK: The position map

    /// A page loaded or its layout changed: rebuild both pages' maps, once
    /// things have settled a moment.
    private var rebuild: DispatchWorkItem?
    func scheduleRebuild() {
        rebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rebuildMaps() } }
        rebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Each page describes its layout (the blocks it shows and where);
    /// each is handed the other's and works out its own map from the two.
    private func rebuildMaps() {
        guard let main, let twin else { return }
        Task { @MainActor [weak main, weak twin] in
            guard let main, let twin,
                  let a = try? await main.callAsyncJavaScript("return window.__toastyScroll?.describe()", contentWorld: Self.world),
                  let b = try? await twin.callAsyncJavaScript("return window.__toastyScroll?.describe()", contentWorld: Self.world),
                  !(a is NSNull), !(b is NSNull) else { return }
            _ = try? await main.callAsyncJavaScript("window.__toastyScroll?.setMap(o)", arguments: ["o": b], contentWorld: Self.world)
            _ = try? await twin.callAsyncJavaScript("window.__toastyScroll?.setMap(o)", arguments: ["o": a], contentWorld: Self.world)
        }
    }

    /// Puts the twin where the main page is (side by side or sync just
    /// turned on, or the twin finished loading).
    func syncTwinToMain() {
        guard let main, let twin else { return }
        leader = ObjectIdentifier(main)
        leaderAt = Date()
        main.callAsyncJavaScript("return window.__toastyScroll?.state()", arguments: [:], in: nil,
                                 in: Self.world) { [weak self, weak twin] result in
            guard let self, let twin, case .success(let state) = result, !(state is NSNull) else { return }
            self.scheduleRebuild()
            twin.callAsyncJavaScript("window.__toastyScroll?.instant(s)", arguments: ["s": state], in: nil,
                                     in: Self.world, completionHandler: nil)
        }
    }

    private func apply(_ state: Any, to web: WKWebView) {
        web.callAsyncJavaScript("window.__toastyScroll?.apply(s)", arguments: ["s": state], in: nil,
                                in: Self.world, completionHandler: nil)
    }

    static let script = #"""
    (() => {
      if (window.__toastyScroll) return;
      const handler = window.webkit?.messageHandlers?.toastyScroll;
      if (!handler) return;
      const LINE = 0.3;           // the reading line, as a fraction of the visible height
      const DEPTH = 24;           // ancestors reported, at most
      let muteUntil = 0, queued = null, pending = false;

      const rootScroller = () => document.scrollingElement || document.documentElement;
      const isRoot = (el) => !el || el === document || el === document.documentElement || el === document.body || el === rootScroller();
      const scrollable = (el) => {
        if (isRoot(el)) return true;
        if (el.scrollHeight <= el.clientHeight + 1) return false;
        const o = getComputedStyle(el).overflowY;
        return o === "auto" || o === "scroll" || o === "overlay";
      };
      // The visible band of a scroller, in viewport coordinates.
      const band = (sc) => {
        if (isRoot(sc)) return { top: 0, height: innerHeight };
        const r = sc.getBoundingClientRect();
        const top = Math.max(0, r.top + sc.clientTop);
        const bottom = Math.min(innerHeight, r.top + sc.clientTop + sc.clientHeight);
        return { top, height: Math.max(1, bottom - top) };
      };
      const metrics = (sc) => isRoot(sc)
        ? { top: rootScroller().scrollTop, max: rootScroller().scrollHeight - innerHeight }
        : { top: sc.scrollTop, max: sc.scrollHeight - sc.clientHeight };

      // Path from the body, or from the nearest element with a unique id:
      // steps are {i, t} (child index, tag) or {id}.
      const uniqueId = (el) => el.id && document.querySelectorAll("#" + CSS.escape(el.id)).length === 1;
      const pathOf = (el) => {
        const steps = [];
        while (el && el !== document.body && el !== document.documentElement) {
          if (uniqueId(el)) { steps.unshift({ id: el.id }); return steps; }
          const p = el.parentElement;
          if (!p) break;
          steps.unshift({ i: Array.prototype.indexOf.call(p.children, el), t: el.tagName });
          el = p;
        }
        return steps;
      };
      // Every element along a path, as far as it matches here.
      const walk = (steps) => {
        const found = [];
        let el = document.body;
        for (const s of steps) {
          if (s.id !== undefined) el = document.getElementById(s.id);
          else { el = el && el.children[s.i]; if (el && el.tagName !== s.t) el = null; }
          if (!el) break;
          found.push(el);
        }
        return found;
      };
      const pinned = (el, sc) => {
        for (let e = el; e && e !== sc && e !== document.body; e = e.parentElement) {
          const p = getComputedStyle(e).position;
          if (p === "fixed" || p === "sticky") return true;
        }
        return false;
      };
      const shown = (el) => { const r = el.getBoundingClientRect(); return r.height > 0 && r.width > 0; };

      // The element at the reading line, tried at a few points along it.
      // Of what's hit, the first in reading order that contains none of the
      // others (a point between columns hits only their container; in a
      // row of cards, the row's first card, as a one-column phone reads it).
      // Fixed and sticky things (headers) don't count.
      // Things side by side on the line (a row of cards): each lifted to
      // the child of their common ancestor, so it's the cards, not what in
      // them was hit. A one-column phone stacks them; the row's span maps to
      // their span there, so it moves through all of them as this page
      // moves through the row, instead of jumping at the row's end.
      const rowOf = (leaves) => {
        if (leaves.length < 2) return null;
        let common = leaves[0].parentElement;
        while (common && !leaves.every((l) => common.contains(l))) common = common.parentElement;
        if (!common || common === document.body || common === document.documentElement) return null;
        const cards = [];
        for (const l of leaves) {
          let c = l;
          while (c.parentElement !== common) c = c.parentElement;
          if (!cards.includes(c)) cards.push(c);
        }
        return cards.length > 1 ? cards : null;
      };
      const span = (els) => {
        let top = Infinity, bottom = -Infinity;
        for (const e of els) { const r = e.getBoundingClientRect(); top = Math.min(top, r.top); bottom = Math.max(bottom, r.bottom); }
        return { top, height: Math.max(1, bottom - top) };
      };

      const anchorAt = (sc, b) => {
        const left = isRoot(sc) ? 0 : Math.max(0, sc.getBoundingClientRect().left);
        const width = isRoot(sc) ? innerWidth : Math.min(innerWidth, sc.getBoundingClientRect().right) - left;
        for (const fy of [LINE, LINE + 0.15, LINE - 0.15, 0.6]) {
          const y = b.top + fy * b.height;
          const hits = [];
          for (const fx of [0.1, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9]) {
            let el = document.elementFromPoint(left + fx * width, y);
            if (!el || el === document.body || el === document.documentElement) continue;
            if ((!isRoot(sc) && (!sc.contains(el) || el === sc)) || pinned(el, sc)) continue;
            while (el && el.getBoundingClientRect().height < 4 && el.parentElement) el = el.parentElement;
            if (!hits.includes(el)) hits.push(el);
          }
          let leaves = hits.filter((h) => !hits.some((o) => o !== h && h.contains(o)));
          // Something taller than the view (a sidebar) only if nothing else.
          const fits = leaves.filter((h) => h.getBoundingClientRect().height <= b.height);
          if (fits.length) leaves = fits;
          leaves.sort((p, q) => (p.compareDocumentPosition(q) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1);
          if (leaves.length) return { el: leaves[0], y, row: rowOf(leaves) };
        }
        return null;
      };

      const state = (sc) => {
        sc = sc || rootScroller();
        const m = metrics(sc);
        const scroller = isRoot(sc) ? null : pathOf(sc);
        if (m.max <= 1 || m.top <= 1) return { scroller, edge: "top" };
        if (m.top >= m.max - 1) return { scroller, edge: "bottom" };
        const b = band(sc);
        const a = anchorAt(sc, b);
        if (!a) return { scroller, fraction: m.top / m.max };
        const line = (a.y - b.top) / b.height;
        // Ratios for the anchor and each ancestor up to the scroller.
        const ratios = [];
        for (let e = a.el, n = 0; e && n < DEPTH; e = e.parentElement, n++) {
          if (e === document.body || e === document.documentElement || (!isRoot(sc) && e === sc)) break;
          const r = e.getBoundingClientRect();
          ratios.push(r.height > 0 ? (a.y - r.top) / r.height : 0);
        }
        let row = null;
        if (a.row) { const r = span(a.row); row = { paths: a.row.map(pathOf), ratio: (a.y - r.top) / r.height }; }
        return { scroller, path: pathOf(a.el), ratios, row, line, fraction: m.top / m.max };
      };

      const jump = (sc, y) => {
        if (isRoot(sc)) window.scrollTo({ top: y, behavior: "instant" });
        else sc.scrollTo({ top: y, behavior: "instant" });
      };
      // Glide toward where the other page says to be, on a critically
      // damped spring that also takes on the other page's speed: it eases
      // in and out, and keeps pace with a steady scroll instead of trailing
      // and catching up.
      const W = 32;               // stiffness (rad/s): settles in about 0.15 s
      let glide = null;
      const glideTo = (sc, y) => {
        const m = metrics(sc);
        y = Math.max(0, Math.min(m.max, y));
        const now = performance.now();
        if (glide && glide.sc === sc) {
          const dt = (now - glide.goalAt) / 1000;
          if (dt > 0.004) {
            const v = (y - glide.goal) / dt;
            glide.gv = dt < 0.1 ? glide.gv * 0.4 + v * 0.6 : 0;
            glide.goal = y; glide.goalAt = now;
          } else glide.goal = y;
          return;
        }
        glide = { sc, goal: y, goalAt: now, gv: 0, pos: m.top, v: 0, last: now };
        requestAnimationFrame(step);
      };
      const step = () => {
        const g = glide;
        if (!g) return;
        const now = performance.now();
        const dt = Math.min(1 / 30, Math.max(0.001, (now - g.last) / 1000));
        g.last = now;
        const age = (now - g.goalAt) / 1000;
        // The other page's speed, fading as its news gets old (it may have
        // stopped): held, it would carry this page past where it stopped.
        const gv = g.gv * Math.exp(-age / 0.025);
        g.v += (W * W * (g.goal - g.pos) + 2 * W * (gv - g.v)) * dt;
        g.pos += g.v * dt;
        const max = metrics(g.sc).max;
        if (g.pos < 0 || g.pos > max) { g.pos = Math.max(0, Math.min(max, g.pos)); g.v = 0; }
        muteUntil = now + 120;
        if (Math.abs(g.goal - g.pos) < 1 && Math.abs(g.v) < 20 && age > 0.05) {
          jump(g.sc, g.goal); glide = null; return;
        }
        jump(g.sc, g.pos);
        requestAnimationFrame(step);
      };
      const scrollerAround = (el) => {
        for (let e = el?.parentElement; e && !isRoot(e); e = e.parentElement) if (scrollable(e)) return e;
        return rootScroller();
      };

      const apply = (s) => {
        if (!s) return;
        muteUntil = performance.now() + 120;
        // The same scrolling area, if it scrolls here too.
        let sc = rootScroller();
        if (s.scroller) {
          const found = walk(s.scroller);
          const el = found.length === s.scroller.length ? found[found.length - 1] : null;
          if (el && scrollable(el)) sc = el;
        }
        let target = null, ratio = 0;
        if (s.path) {
          const found = walk(s.path);
          // ratios run from the anchor up; found runs from the top down.
          for (let k = found.length - 1; k >= 0; k--) {
            const up = s.path.length - 1 - k;
            if (up >= s.ratios.length) break;
            if (shown(found[k])) { target = found[k]; ratio = s.ratios[up]; break; }
          }
          // That area isn't what scrolls here: whatever scrolls around the element.
          if (target) {
            if (!isRoot(sc) && !sc.contains(target)) sc = scrollerAround(target);
            else if (isRoot(sc) && (s.scroller || metrics(sc).max <= 1)) sc = scrollerAround(target);
          }
        }
        // The page doesn't scroll here (an app layout): its biggest scrolling area.
        if (!target && isRoot(sc) && metrics(sc).max <= 1) {
          let area = 0;
          for (const el of document.body.querySelectorAll("*")) {
            const a = el.clientWidth * el.clientHeight;
            if (a > area && scrollable(el)) { sc = el; area = a; }
          }
        }
        if (glide && glide.sc !== sc) glide = null;
        if (s.edge === "top") return glideTo(sc, 0);
        if (s.edge === "bottom") return glideTo(sc, metrics(sc).max);
        if (!target) return glideTo(sc, (s.fraction || 0) * metrics(sc).max);
        const b = band(sc);
        let point;
        const cards = s.row ? s.row.paths.map((p) => { const f = walk(p); return f.length === p.length ? f[f.length - 1] : null; })
          .filter((e) => e && shown(e)) : [];
        if (cards.length > 1) { const r = span(cards); point = r.top + s.row.ratio * r.height; }
        else { const r = target.getBoundingClientRect(); point = r.top + ratio * r.height; }
        glideTo(sc, metrics(sc).top + point - (b.top + s.line * b.height));
      };

      // The position map. Each page describes the blocks it shows (by
      // child index and tag, the same in both: it's one page) and where they
      // are in its main scrolling area. Two pages' descriptions give pairs
      // of positions that are the same place: each block's top and bottom.
      // Blocks side by side (in either layout) count as one, from the
      // first one's top to the lowest bottom, so a desktop row maps to its
      // cards stacked on a phone. Between pairs it's a straight line, so
      // the other page moves evenly, never jumps, and never goes back.
      let map = null, mapSc = null;
      const mainScroller = () => {
        const r = rootScroller();
        if (r.scrollHeight - innerHeight > 1) return r;
        let best = r, area = 0;
        for (const el of document.body.querySelectorAll("*")) {
          const a = el.clientWidth * el.clientHeight;
          if (a > area && scrollable(el)) { best = el; area = a; }
        }
        return best;
      };
      const describe = () => {
        const sc = mainScroller();
        const b = band(sc), m = metrics(sc);
        const off = m.top - b.top;
        let count = 0;
        const blocks = (el, depth) => {
          const out = [];
          if (depth > 16) return out;
          for (let i = 0; i < el.children.length && count < 6000; i++) {
            const c = el.children[i];
            const cs = getComputedStyle(c);
            if (cs.display === "none" || cs.position === "fixed" || cs.position === "sticky") continue;
            const r = c.getBoundingClientRect();
            if (r.height <= 0 || r.width <= 0) continue;
            count++;
            const n = { k: i + c.tagName, t: r.top + off, b: r.bottom + off };
            // Inside another scrolling area, places move with it: not in the map.
            if (!scrollable(c)) n.c = blocks(c, depth + 1);
            out.push(n);
          }
          return out;
        };
        const d = { href: location.origin + location.pathname, h: m.max + b.height,
                    c: blocks(isRoot(sc) ? document.body : sc, 0) };
        mapSc = sc;
        return d;
      };
      const setMap = (other) => {
        const mine = describe();
        map = null;
        if (!other || other.href !== mine.href) return;
        const pts = [[0, 0], [mine.h, other.h]];
        const match = (ac, bc) => {
          const bi = new Map(bc.map((n) => [n.k, n]));
          let run = [], aBot = -Infinity, bBot = -Infinity;
          const flush = () => {
            if (run.length === 1) {
              const [x, y] = run[0];
              pts.push([x.t, y.t], [x.b, y.b]);
              if (x.c && y.c) match(x.c, y.c);
            } else if (run.length) {
              let at = Infinity, ab = -Infinity, bt = Infinity, bb = -Infinity;
              for (const [x, y] of run) {
                at = Math.min(at, x.t); ab = Math.max(ab, x.b); bt = Math.min(bt, y.t); bb = Math.max(bb, y.b);
              }
              pts.push([at, bt], [ab, bb]);
            }
            run = []; aBot = -Infinity; bBot = -Infinity;
          };
          for (const x of ac) {
            const y = bi.get(x.k);
            if (!y) continue;
            // Starts above the run's bottom, in either layout: side by side.
            if (!(run.length && (x.t < aBot - 1 || y.t < bBot - 1))) flush();
            run.push([x, y]);
            aBot = Math.max(aBot, x.b); bBot = Math.max(bBot, y.b);
          }
          flush();
        };
        match(mine.c, other.c);
        pts.sort((p, q) => p[0] - q[0] || p[1] - q[1]);
        const out = [];
        for (const [x, y] of pts) {
          if (x < 0 || x > mine.h) continue;
          const last = out[out.length - 1];
          if (last && x - last[0] < 0.5) continue;
          out.push([x, Math.min(other.h, Math.max(y, last ? last[1] : 0))]);
        }
        map = out;
      };
      const lookup = (x) => {
        let lo = 0, hi = map.length - 1;
        if (x <= map[0][0]) return map[0][1];
        if (x >= map[hi][0]) return map[hi][1];
        while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (map[mid][0] <= x) lo = mid; else hi = mid; }
        const [x0, y0] = map[lo], [x1, y1] = map[hi];
        return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
      };
      // The reading line slides from the top of the view to its bottom as
      // the page scrolls from top to bottom: the top and the bottom of one
      // page are the top and bottom of the other, with nothing in between.
      const mapState = () => {
        const m = metrics(mapSc), b = band(mapSc);
        const f = m.max > 0 ? Math.max(0, Math.min(1, m.top / m.max)) : 0;
        return { kind: "map", y: lookup(m.top + f * b.height), f };
      };
      const follow = (s) => {
        if (!map || !mapSc) return;
        glideTo(mapSc, s.y - s.f * band(mapSc).height);
      };
      const onMapScroller = (sc) => mapSc && (sc ? sc === mapSc : isRoot(mapSc));

      // The layout changed (loaded, resized, content added): the map is redone.
      let layoutTimer = 0;
      const layoutChanged = () => {
        clearTimeout(layoutTimer);
        layoutTimer = setTimeout(() => { try { handler.postMessage({ kind: "layout" }); } catch {} }, 200);
      };
      new ResizeObserver(layoutChanged).observe(document.documentElement);
      if (document.body) {
        new ResizeObserver(layoutChanged).observe(document.body);
        new MutationObserver(layoutChanged).observe(document.body, { childList: true, subtree: true });
      }
      addEventListener("load", layoutChanged);

      // The user taking hold of this page (wheel, trackpad, keys) ends a glide.
      for (const type of ["wheel", "keydown", "mousedown", "touchstart"])
        addEventListener(type, () => { if (glide) { glide = null; muteUntil = 0; } }, { capture: true, passive: true });

      document.addEventListener("scroll", (e) => {
        if (performance.now() < muteUntil) return;
        const sc = e.target === document ? null : e.target;
        if (map && onMapScroller(sc)) {
          try { handler.postMessage(mapState()); } catch {}
          return;
        }
        queued = sc;
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => {
          const target = queued; pending = false;
          if (performance.now() < muteUntil) return;
          try { handler.postMessage(state(target)); } catch {}
        });
      }, { capture: true, passive: true });

      window.__toastyScroll = { state: () => map ? mapState() : state(null), describe, setMap, follow,
        apply: (s) => s && s.kind === "map" ? follow(s) : apply(s), instant: (s) => { (s && s.kind === "map" ? follow : apply)(s); if (glide) { jump(glide.sc, glide.goal); glide = null; } } };
    })();
    """#
}

/// Whether ⌘ is down, for the footer's Sync Scrolling button (blue while
/// held: scrolling now syncs). Watches Toasty's own key events; letting go
/// in another app is missed, so leaving Toasty counts as letting go.
@MainActor
final class PreviewCommandKey: ObservableObject {
    static let shared = PreviewCommandKey()
    @Published private(set) var held = false
    private var monitor: Any?
    private var resign: NSObjectProtocol?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let down = event.modifierFlags.contains(.command)
            if self?.held != down { self?.held = down }
            return event
        }
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.held == true { self?.held = false } }
        }
    }
}
