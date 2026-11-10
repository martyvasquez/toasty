import { readFileSync } from "node:fs";
const { forkSession } = await import(process.argv[2]);
const cases = JSON.parse(readFileSync(process.argv[3], "utf8"));
const out = {};
for (const c of cases) {
  const t = performance.now();
  try { const r = await forkSession(c.sessionId, { dir: c.dir, upToMessageId: c.upToMessageId, title: "POC fork" }); out[c.name] = { sessionId: r.sessionId, ms: Math.round(performance.now() - t) }; }
  catch (e) { out[c.name] = { error: String(e?.message ?? e) }; }
}
console.log(JSON.stringify(out, null, 1));
