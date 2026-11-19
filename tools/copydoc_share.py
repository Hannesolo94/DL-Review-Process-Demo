"""Make, show or revoke a READ-ONLY share link for a copy doc (Nov 19 2026).
Anyone with the link can read the doc (no sign-in, no editing, no History) until it expires or is revoked.
Usage: python -I copydoc_share.py <BRIEF#|doc_id> [--days 7] [--revoke]
A new link replaces the old one (the old link stops working)."""
import sys, re, secrets, pathlib
import psycopg

DSN = pathlib.Path(r'D:/review-canvas/.dsn').read_text().strip()
BASE = 'https://hannesolo94.github.io/DL-Review-Process-Demo/copy/'


def main():
    a = sys.argv[1:]
    if not a: sys.exit(__doc__)
    key = a[0]; days = int(a[a.index('--days') + 1]) if '--days' in a else 7
    with psycopg.connect(DSN, autocommit=True) as c:
        if re.fullmatch(r'[0-9a-f-]{36}', key):
            row = c.execute('select id, brief_number from copy_docs where id=%s', (key,)).fetchone()
        else:
            row = c.execute('select id, brief_number from copy_docs where brief_number=%s and not archived order by updated_at desc limit 1', (key.upper(),)).fetchone()
        if not row: sys.exit(f'No copy doc for {key}')
        doc, brief = row
        if '--revoke' in a:
            # share-only changes keep updated_at (copy_docs_touch), so an open editor tab sees no conflict
            c.execute("update copy_docs set share_token=null, share_expires=null where id=%s", (doc,))
            print(f'{brief}: share link revoked'); return
        tok = secrets.token_urlsafe(24)   # 32 chars
        c.execute("update copy_docs set share_token=%s, share_expires=now() + make_interval(days => %s) where id=%s", (tok, days, doc))
        exp = c.execute('select share_expires from copy_docs where id=%s', (doc,)).fetchone()[0]
        print(f'{brief}: {BASE}?share={tok}  (read-only, expires {exp:%d %b %H:%M} UTC)')


if __name__ == '__main__':
    main()
