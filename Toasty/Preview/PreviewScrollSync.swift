import Foundation
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

    /// Puts the script and its message handler on a web view's configuration.
    static func install(on configuration: WKWebViewConfiguration, relay: WKScriptMessageHandler) {
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: world))
        content.add(relay, contentWorld: world, name: handler)
    }

    /// A page scrolled (by the user, or as the other page's echo).
    func scrolled(in web: WKWebView, _ body: Any) {
        guard let main, let twin else { return }
        let id = ObjectIdentifier(web)
        let now = Date()
        if let leader, leader != id, now.timeIntervalSince(leaderAt) < 0.12 { return }
        leader = id
        leaderAt = now
        apply(body, to: web === main ? twin : main)
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
            self.apply(state, to: twin)
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
          if (leaves.length) return { el: leaves[0], y };
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
        return { scroller, path: pathOf(a.el), ratios, line, fraction: m.top / m.max };
      };

      const scrollBy = (sc, dy) => {
        if (isRoot(sc)) window.scrollBy({ top: dy, behavior: "instant" });
        else sc.scrollBy({ top: dy, behavior: "instant" });
      };
      const scrollTo = (sc, y) => {
        if (isRoot(sc)) window.scrollTo({ top: y, behavior: "instant" });
        else sc.scrollTo({ top: y, behavior: "instant" });
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
        if (s.edge === "top") return scrollTo(sc, 0);
        if (s.edge === "bottom") { const m = metrics(sc); return scrollTo(sc, m.max + 10); }
        if (!target) { const m = metrics(sc); return scrollTo(sc, (s.fraction || 0) * m.max); }
        const b = band(sc);
        const r = target.getBoundingClientRect();
        scrollBy(sc, (r.top + ratio * r.height) - (b.top + s.line * b.height));
      };

      document.addEventListener("scroll", (e) => {
        if (performance.now() < muteUntil) return;
        const sc = e.target === document ? null : e.target;
        queued = sc;
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => {
          const target = queued; pending = false;
          if (performance.now() < muteUntil) return;
          try { handler.postMessage(state(target)); } catch {}
        });
      }, { capture: true, passive: true });

      window.__toastyScroll = { state: () => state(null), apply };
    })();
    """#
}
