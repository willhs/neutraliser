#!/usr/bin/env python3 -I
"""Join the NAS library's records into the counts in library-baseline-2026-10.md.

Usage: library-baseline-2026-10.py RAW_DIR
RAW_DIR holds (copied off the NAS, read-only runs):
  v1-tv.tsv v1-movies.tsv v2.tsv usb.tsv   `neutraliser report PATH --format=tsv` per root
  cli-manifests.tsv                        every .neutraliser-run-manifest.jsonl: <folder>\t<json line>
  manifest.jsonl manifest-usb3-2*.jsonl    media-server neutralise.sh manifests
"""
import json, os, re, sys, collections, glob

raw = sys.argv[1]
C = collections.Counter

def tsv(name):
    p = os.path.join(raw, name)
    if not os.path.exists(p):
        return []
    with open(p, encoding="utf-8", errors="replace") as f:
        rows = [l.rstrip("\n").split("\t") for l in f]
    head = rows[0]
    return [dict(zip(head, r + [""] * (len(head) - len(r)))) for r in rows[1:]]

def rel(path):
    m = re.search(r"/(tv|movies|TV Shows|Movies)/(.*)$", path)
    return (m.group(1).lower().replace("tv shows", "tv"), m.group(2)) if m else None

current = {}   # (root, kind, relpath) -> row
for root, name in [("v1", "v1-tv.tsv"), ("v1", "v1-movies.tsv"), ("v2", "v2.tsv"), ("usb", "usb.tsv")]:
    for r in tsv(name):
        k = rel(r["file"])
        if k:
            current[(root,) + k] = r

print("== current state by root/kind (report stamps)")
by = collections.defaultdict(C)
for (root, kind, _), r in current.items():
    by[(root, kind)][r["state"]] += 1
for k in sorted(by):
    print(k, sum(by[k].values()), dict(by[k]))
print("total", len(current), dict(C(r["state"] for r in current.values())))
print("stamp profiles", dict(C(r["profile"] for r in current.values() if r["profile"])))
print("stamp versions", dict(C(r["version"] for r in current.values() if r["version"])))

# ---- Aug CLI run (volume1 only). Per file: its last `done` record if it has one (a retry
# can follow a failure), else its last record. `records` keeps every line for the raw counts.
last, records = {}, C()
for line in open(os.path.join(raw, "cli-manifests.tsv"), encoding="utf-8", errors="replace"):
    _, _, js = line.partition("\t")
    try:
        d = json.loads(js)
    except ValueError:
        continue
    if not d["timestamp"].startswith("2026-08") or d["status"] == "queued":
        continue
    k = rel(d["file"])
    if not k or d["file"].startswith("/mnt/nas/media/#Recycle"):
        continue
    key = ("v1",) + k
    records[d["status"] + ("/" + d["normalization_type"] if d.get("normalization_type") else "")] += 1
    if key not in last or d["status"] == "done" or last[key]["status"] != "done":
        last[key] = d

print("\n== Aug CLI run, every record (volume1)", dict(records))
def failure_class(msg):
    m = (msg or "").replace("\n", " ")
    if re.search(r"not writable|Permission denied|Operation not permitted|Read-only", m, re.I): return "permission (not_writable)"
    if re.search(r"imed out|timeout", m, re.I): return "timeout"
    if re.search(r"subtitle|webvtt|S_TEXT|codec none|Subtitle codec", m, re.I): return "subtitle"
    if re.search(r"No such file", m): return "file missing"
    return "other: " + m[:70]

print("== Aug CLI run, one status per file (volume1)")
print(dict(C(d["status"] for d in last.values())))
done = {k: d for k, d in last.items() if d["status"] == "done"}
print("done by type", dict(C(d.get("normalization_type") for d in done.values())))
print("done by type x kind", dict(C((d.get("normalization_type"), k[1]) for k, d in done.items())))
fails = {k: d for k, d in last.items() if d["status"] == "failed"}
print("failed by class", dict(C(failure_class(d.get("message")) for d in fails.values())))
print("failed by class x kind", dict(C((failure_class(d.get("message")), k[1]) for k, d in fails.items())))
fshow = C(k[2].split("/")[0] for k, d in fails.items() if failure_class(d.get("message")).startswith("permission"))
print("permission failures by show (top 15)", fshow.most_common(15))
tshow = C(k[2].split("/")[0] for k, d in fails.items() if failure_class(d.get("message")) == "timeout")
print("timeout failures by show/film (top 10)", tshow.most_common(10))

print("\n== Aug done -> now")
for typ in ("Dynamic", "Linear"):
    ks = [k for k, d in done.items() if d.get("normalization_type") == typ]
    now = C((current[k]["state"] if k in current else "file gone/replaced") for k in ks)
    print(typ, len(ks), dict(now))
print("Aug failed -> now", dict(C((current[k]["state"] if k in current else "gone") for k in fails)))
print("Aug skipped -> now", dict(C((current[k]["state"] if k in current else "gone") for k, d in last.items() if d["status"] == "skipped"))
)

dyn_open = [k for k, d in done.items() if d.get("normalization_type") == "Dynamic" and k in current and current[k]["state"] == "untouched"]
print("Dynamic still on disk with no stamp:", len(dyn_open))
dshow = C(k[2].split("/")[0] if k[1] == "tv" else "(movies)" for k in dyn_open)
print("  top shows", dshow.most_common(25))

obj = re.compile(r"atmos|truehd|dts[-. ]?x|dts[-. ]?hd[-. ]?ma|\bddp?\b.*atmos", re.I)
print("\n== Aug done files whose name hints Atmos/TrueHD/DTS:X")
for k, d in sorted(done.items()):
    if re.search(r"atmos|truehd|dts[-. ]?x", k[2], re.I):
        print(" ", d.get("normalization_type"), k[1], k[2], "| now:", current[k]["state"] if k in current else "gone")

# ---- media-server shell manifests (paths relative to the root)
print("\n== neutralise.sh manifests")
sh = {}
for name, root in [("manifest.jsonl", "v1")] + [(os.path.basename(p), "usb") for p in sorted(glob.glob(os.path.join(raw, "manifest-usb3-2*.jsonl")))]:
    for line in open(os.path.join(raw, name)):
        try: d = json.loads(line)
        except ValueError: continue
        k = rel("/" + d["file"]) if root == "v1" else rel("/" + d["file"])
        sh[(root, name, d["file"])] = d
print("rows", len(sh))
agg = C()
for (root, name, f), d in sh.items():
    agg[(name, d["status"], d.get("mode", "-"))] += 1
for k, v in sorted(agg.items()): print(" ", k, v)
v1m = {}
for (root, name, f), d in sh.items():
    if name == "manifest.jsonl":
        k = rel("/" + f)
        if k: v1m[("v1",) + k] = d          # later lines win
print("v1 shell final status", dict(C((d["status"], d.get("mode", "-")) for d in v1m.values())))
print("v1 shell 'done' no mode (before mode recorded):", sum(1 for d in v1m.values() if d["status"] == "done" and "mode" not in d))
print("   of which file present now:", sum(1 for k, d in v1m.items() if d["status"] == "done" and "mode" not in d and k in current))
print("v1 shell done (all) present now:", sum(1 for k, d in v1m.items() if d["status"] == "done" and k in current), "of", sum(1 for d in v1m.values() if d["status"] == "done"))
print("v1 shell done -> now state", dict(C(current[k]["state"] if k in current else "gone" for k, d in v1m.items() if d["status"] == "done")))
for k, d in v1m.items():
    if d["status"] == "skip_object_audio": print("object audio skip:", k, d)
tp = [(k, d) for k, d in v1m.items() if d["status"] == "skip_tp_capped"]
print("skip_tp_capped", len(tp), "shows", C(k[2].split("/")[0] for k, d in tp).most_common(10))
print("fail_measure", [k[2] for k, d in v1m.items() if d["status"] == "fail_measure"])

# ---- lists for read-only ffprobe checks on the NAS
out = os.path.join(raw, "..")
with open(os.path.join(out, "tagcheck.lst"), "w") as f:      # shell 'done' files still on disk
    for k, d in sorted(v1m.items()):
        if d["status"] == "done" and k in current:
            f.write("/volume1/media/%s/%s\n" % (k[1], k[2]))
with open(os.path.join(out, "atmoscheck.lst"), "w") as f:
    for k in sorted(done):
        if re.search(r"atmos|truehd|dts[-. ]?x", k[2], re.I) and k in current:
            f.write("/volume1/media/%s/%s\n" % (k[1], k[2]))
    f.write("/volume1/media/movies/Forrest Gump (1994)\n")

# ---- what has any record at all (volume1): a file no engine has ever looked at
print("\n== volume1 files by what recorded them")
aug = {k: d for k, d in last.items()}
cat = C()
for k, r in current.items():
    if k[0] != "v1": continue
    a = aug.get(k, {}).get("status")
    a = ("aug-" + (aug[k].get("normalization_type") or a)) if a == "done" else ("aug-" + a if a else None)
    s = v1m.get(k)
    s = ("shell-" + s["status"] + ("/" + s["mode"] if s.get("mode") else "")) if s else None
    if r["state"] != "untouched": cat[("stamped " + r["state"], k[1])] += 1
    else: cat[(a or "-", s or "-", k[1])] += 1
for k, v in sorted(cat.items(), key=lambda x: -x[1]): print(" ", v, k)
