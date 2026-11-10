import json, re, sys, glob, os
J = sys.argv[1]
node = json.load(open(f"{J}/node-result.json")); jsc = json.load(open(f"{J}/jsc-result.json"))
UU = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
TS = re.compile(r'"timestamp":"[^"]+"|"ts":"[^"]+"')
def load(run, sid):
    f = glob.glob(f"{J}/{run}/projects/*/{sid}.jsonl")[0]
    text = open(f).read()
    src_ids = set()
    return text, os.path.getsize(f)
def normalize(text, fork_id, source_ids):
    # Fresh ids (not present in the source transcript) → F1, F2… by first appearance.
    m = {}
    def sub(mt):
        u = mt.group(0)
        if u in source_ids: return u
        m.setdefault(u, f"NEW{len(m)}")
        return m[u]
    t = UU.sub(sub, text)
    return TS.sub(lambda mt: mt.group(0) if mt.group(0) in src_ts else "\"timestamp\":\"NEW\"", t)
allok = True
for name in sorted(node):
    a, b = node[name], jsc[name]
    if "error" in a or "error" in b: print(f"{name}: node={a} jsc={b}"); allok=False; continue
    srcid = [c for c in json.load(open(f"{J}/cases.json")) if c["name"]==name][0]["sessionId"]
    src = open(glob.glob(f"{J}/base/projects/*/{srcid}.jsonl")[0]).read()
    source_ids = set(UU.findall(src)); global src_ts; src_ts = set(TS.findall(src))
    ta, sa = load("run-node", a["sessionId"]); tb, sb = load("run-jsc", b["sessionId"])
    na, nb = normalize(ta, a["sessionId"], source_ids), normalize(tb, b["sessionId"], source_ids)
    la, lb = na.splitlines(), nb.splitlines()
    same = na == nb
    allok &= same
    # what timestamps differ besides the expected "now" on the last entry
    print(f"{'IDENTICAL' if same else 'DIFFERENT'}  {name:28s} {len(la):5d} lines  {sa/1e6:6.1f} MB  node {a['ms']}ms / jsc {b['ms']}ms")
    if not same:
        for i,(x,y) in enumerate(zip(la,lb)):
            if x!=y: print("   first diff line", i, "\n   node:", x[:300], "\n   jsc: ", y[:300]); break
        if len(la)!=len(lb): print("   line counts differ", len(la), len(lb))
print("ALL IDENTICAL" if allok else "MISMATCHES FOUND")
