"""CRAFT QA: check every brief page the way a reviewer would get it. Built Sep 29 2026 after ATP0372
shipped with two videos sharing one truncated asset id (the second upload overwrote the first).

  python tools/craft_qa.py            all briefs
  python tools/craft_qa.py ATP0372    one or more slugs

Checks, through the same public RPC a reviewer's browser uses (publishable key + the brief's token):
  - the brief loads, has a title, a `testing` line, headline and primary text
  - asset ids are unique (duplicate ids overwrite each other in storage and on the page)
  - no two assets point at the same storage file
  - every asset has a landing page, a title and a kind
  - every src answers 200 with the right content type and a non-trivial size
  - videos are faststart (moov before mdat), or timestamped notes break
  - signed URLs have more than 30 days left
Exit code 1 if anything fails.
"""
import base64
import json
import sys
import time
import urllib.request
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parent.parent
ENV = dict(l.split("=", 1) for l in (ROOT / ".env").read_text().splitlines() if "=" in l and not l.startswith("#"))
URL = ENV["SUPABASE_URL"].rstrip("/")
PUB = ENV["SUPABASE_PUBLISHABLE_KEY"]


def rpc(fn, body):
    r = urllib.request.Request(f"{URL}/rest/v1/rpc/{fn}", data=json.dumps(body).encode(), method="POST",
                               headers={"apikey": PUB, "Authorization": f"Bearer {PUB}", "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read() or b"null")


def head(src, n=65536):
    r = urllib.request.Request(src, headers={"Range": f"bytes=0-{n - 1}"})
    with urllib.request.urlopen(r, timeout=60) as resp:
        total = resp.headers.get("Content-Range", "").split("/")[-1]
        return resp.status, resp.headers.get("Content-Type", ""), int(total or 0), resp.read()


def faststart(first_bytes):
    i = 0
    while i + 8 <= len(first_bytes):
        size = int.from_bytes(first_bytes[i:i + 4], "big")
        kind = first_bytes[i + 4:i + 8]
        if kind == b"moov":
            return True
        if kind == b"mdat":
            return False
        if size < 8:
            return False
        i += size
    return False


def days_left(src):
    try:
        tok = src.split("token=", 1)[1].split("&")[0]
        payload = tok.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return (json.loads(base64.urlsafe_b64decode(payload))["exp"] - time.time()) / 86400
    except Exception:
        return None


def qa(slug, token):
    probs = []
    b = rpc("get_brief", {"p_token": token})
    if not b:
        return ["brief does not load with its token"]
    d = b["data"]
    for k, v in [("title", b.get("title")), ("testing line", d.get("testing")),
                 ("headline", d.get("copy", {}).get("headline")), ("primary text", d.get("copy", {}).get("primary"))]:
        if not v:
            probs.append(f"missing {k}")
    assets = d.get("assets", [])
    if not assets:
        probs.append("no assets")
    ids = [a.get("id") for a in assets]
    if len(set(ids)) != len(ids):
        probs.append(f"duplicate asset ids: {sorted({i for i in ids if ids.count(i) > 1})}")
    keys = [a.get("src", "").split("?")[0] for a in assets]
    if len(set(keys)) != len(keys):
        probs.append("two assets share one storage file")
    for a in assets:
        tag = a.get("id")
        for k in ("lp", "title", "kind", "src"):
            if not a.get(k):
                probs.append(f"{tag}: missing {k}")
        if not a.get("src"):
            continue
        try:
            status, ctype, size, first = head(a["src"])
        except Exception as e:
            probs.append(f"{tag}: src does not load ({e})")
            continue
        want = "video/" if a.get("kind") == "video" else "image/"
        if status not in (200, 206) or not ctype.startswith(want):
            probs.append(f"{tag}: status {status}, type {ctype}")
        if size < 20000:
            probs.append(f"{tag}: suspiciously small file ({size} bytes)")
        if a.get("kind") == "video" and not faststart(first):
            probs.append(f"{tag}: video is not faststart")
        left = days_left(a["src"])
        if left is not None and left < 30:
            probs.append(f"{tag}: signed URL expires in {left:.0f} days, run craft_media.py refresh")
    return probs


def main(slugs):
    dsn = (ROOT / ".dsn").read_text().strip()
    with psycopg.connect(dsn) as c:
        rows = c.execute("select slug, creator_token from public.briefs order by slug").fetchall()
    rows = [r for r in rows if not slugs or r[0] in slugs]
    bad = 0
    for slug, token in rows:
        p = qa(slug, token)
        bad += bool(p)
        print(("FAIL " if p else "ok   ") + slug + ("".join("\n     - " + x for x in p)))
    print(f"\n{len(rows) - bad}/{len(rows)} briefs pass")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(set(sys.argv[1:])))
