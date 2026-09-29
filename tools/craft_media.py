"""CRAFT private media: upload creative to the private `creative` bucket and mint signed URLs.

Live client ads never go in the public repo. They sit in Supabase Storage (private bucket) and the
brief's asset `src` is a signed URL that expires. `refresh` re-signs every asset of every brief, so
run it before the links get near expiry (a daily keep-alive can call it). Built Sep 29 2026.

  python tools/craft_media.py upload <local file> <key>      e.g. atp0370/A_Nobody_9x16.mp4
  python tools/craft_media.py sign <key> [days]
  python tools/craft_media.py refresh [days]                  re-sign all brief assets in place
  python tools/craft_media.py video <in> <out>                re-encode for the web (h.264, faststart)

Reads SUPABASE_URL and SUPABASE_SECRET_KEY from D:/review-canvas/.env (gitignored).
"""
import json
import mimetypes
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV = dict(l.split("=", 1) for l in (ROOT / ".env").read_text().splitlines() if "=" in l and not l.startswith("#"))
URL = ENV["SUPABASE_URL"].rstrip("/")
KEY = ENV["SUPABASE_SECRET_KEY"]
BUCKET = "creative"
DEFAULT_DAYS = 180


def _req(method, path, data=None, ctype="application/json", extra=None):
    h = {"apikey": KEY, "Authorization": f"Bearer {KEY}", "Content-Type": ctype}
    h.update(extra or {})
    r = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    with urllib.request.urlopen(r, timeout=600) as resp:
        body = resp.read()
    return json.loads(body) if body else {}


def upload(local, key):
    local = Path(local)
    ctype = mimetypes.guess_type(local.name)[0] or "application/octet-stream"
    _req("POST", f"/storage/v1/object/{BUCKET}/{key}", local.read_bytes(), ctype, {"x-upsert": "true"})
    return key


def sign(key, days=DEFAULT_DAYS):
    j = _req("POST", f"/storage/v1/object/sign/{BUCKET}/{key}", json.dumps({"expiresIn": int(days * 86400)}).encode())
    return URL + "/storage/v1" + j["signedURL"]


def key_from_src(src):
    marker = f"/object/sign/{BUCKET}/"
    return src.split(marker, 1)[1].split("?", 1)[0] if marker in (src or "") else None


def refresh(days=DEFAULT_DAYS):
    import psycopg
    dsn = (ROOT / ".dsn").read_text().strip()
    with psycopg.connect(dsn, autocommit=True) as c:
        rows = c.execute("select id, slug, data from public.briefs").fetchall()
        n = 0
        for bid, slug, data in rows:
            changed = False
            for a in data.get("assets", []):
                k = key_from_src(a.get("src"))
                if k:
                    a["src"] = sign(k, days)
                    changed = True
                    n += 1
            if changed:
                c.execute("update public.briefs set data = %s, updated_at = now() where id = %s", (json.dumps(data), bid))
    return n


def video(src, out):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-c:v", "libx264", "-crf", "23", "-preset", "slow",
                    "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-c:a", "aac", "-b:a", "128k", out], check=True)
    return out


if __name__ == "__main__":
    cmd, *a = sys.argv[1:] or ["help"]
    if cmd == "upload":
        print(upload(a[0], a[1]))
    elif cmd == "sign":
        print(sign(a[0], float(a[1]) if len(a) > 1 else DEFAULT_DAYS))
    elif cmd == "refresh":
        print("re-signed", refresh(float(a[0]) if a else DEFAULT_DAYS), "assets")
    elif cmd == "video":
        print(video(a[0], a[1]))
    else:
        print(__doc__)
