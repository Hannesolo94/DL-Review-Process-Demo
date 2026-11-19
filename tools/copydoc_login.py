"""Mint a one-time sign-in link for DL Copy Docs (Nov 19 2026).
Usage: python copydoc_login.py [base_url] [email]
Prints <base>?login=<token_hash>. Single use, expires in 1 hour. Never paste it anywhere shared."""
import json, sys, urllib.request, pathlib
env = dict(l.split('=', 1) for l in pathlib.Path(r'D:/review-canvas/.env').read_text().splitlines() if '=' in l)
base = sys.argv[1] if len(sys.argv) > 1 else 'https://hannesolo94.github.io/DL-Review-Process-Demo/copy/'
email = sys.argv[2] if len(sys.argv) > 2 else 'hannes@dlmedia.org'
S = env['SUPABASE_SECRET_KEY'].strip()
req = urllib.request.Request(env['SUPABASE_URL'].strip() + '/auth/v1/admin/generate_link', method='POST',
    data=json.dumps({'type': 'magiclink', 'email': email}).encode(),
    headers={'apikey': S, 'Authorization': 'Bearer ' + S, 'Content-Type': 'application/json'})
d = json.load(urllib.request.urlopen(req))
h = d.get('hashed_token') or d.get('properties', {}).get('hashed_token')
print(base + ('&' if '?' in base else '?') + 'login=' + h)
