"""Invite / list / revoke COPY DOCS editors (Nov 19 2026). No Supabase dashboard needed.
  python -I copydoc_invite.py invite <email> --docs ODDS0001,ODDS0002 [--days 30] [--open ODDS0001]
  python -I copydoc_invite.py invite <email> --all [--days 30]          (every doc, can make new docs)
  python -I copydoc_invite.py invite <email> --keep                    (fresh link, same docs as now)
  python -I copydoc_invite.py list
  python -I copydoc_invite.py revoke <email>            (invite link stops working; their signed-in browsers keep working)
  python -I copydoc_invite.py remove <email>            (revoke + take editor access away + sign them out everywhere)
The invite link is personal: tied to one email, works up to 20 times for 30 days, survives Slack's &amp; and link
preview bots (it's redeemed only by the page's own code). A new invite for the same email cancels the older ones.
Never post an invite link in a shared channel: anyone holding it can sign in as that person until it's revoked."""
import sys, json, hashlib, secrets, pathlib, urllib.request
import psycopg

ROOT = pathlib.Path(r'D:/review-canvas')
ENV = dict(l.split('=', 1) for l in (ROOT / '.env').read_text().splitlines() if '=' in l)
U, S = ENV['SUPABASE_URL'].strip(), ENV['SUPABASE_SECRET_KEY'].strip()
DSN = (ROOT / '.dsn').read_text().strip()
BASE = 'https://hannesolo94.github.io/DL-Review-Process-Demo/copy/'


def admin(path, body=None, method='POST'):
    r = urllib.request.Request(U + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                               headers={'apikey': S, 'Authorization': 'Bearer ' + S, 'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(r, timeout=30).read() or 'null')


def arg(a, k, d=None): return a[a.index(k) + 1] if k in a else d


def invite(c, email, a, by='copydoc_invite'):
    email = email.strip().lower()
    row = c.execute('select id from auth.users where lower(email)=%s', (email,)).fetchone()
    uid = str(row[0]) if row else admin('/auth/v1/admin/users', {'email': email, 'email_confirm': True})['id']
    cur = c.execute('select doc_ids from copy_doc_editors where user_id=%s', (uid,)).fetchone()
    if '--all' in a: ids = None
    elif '--keep' in a and cur: ids = cur[0]   # same docs as now (hub MAKE LINK)
    elif '--keep' in a: sys.exit('not an editor yet: say which docs with --docs')
    else:
        briefs = [b.strip().upper() for b in (arg(a, '--docs') or '').split(',') if b.strip()]
        if not briefs: sys.exit('say which docs: --docs ODDS0001,ODDS0002  (or --all)')
        rows = c.execute('select id, brief_number from copy_docs where brief_number = any(%s) and not archived', (briefs,)).fetchall()
        missing = set(briefs) - {r[1] for r in rows}
        if missing: sys.exit('no copy doc for: ' + ', '.join(sorted(missing)))
        ids = [r[0] for r in rows]
    c.execute('insert into copy_doc_editors (user_id, email, doc_ids) values (%s,%s,%s) on conflict (user_id) do update set email=excluded.email, doc_ids=excluded.doc_ids', (uid, email, ids))
    c.execute('update copy_doc_invites set revoked_at=now() where lower(email)=%s and revoked_at is null', (email,))
    c.execute('update copy_doc_link_requests set handled_at=now() where email=%s and handled_at is null', (email,))
    tok = secrets.token_urlsafe(24)   # 32 chars
    days = int(arg(a, '--days', '30'))
    c.execute("insert into copy_doc_invites (user_id, email, token_sha256, expires_at, created_by) values (%s,%s,%s, now() + make_interval(days => %s), %s)",
              (uid, email, hashlib.sha256(tok.encode()).hexdigest(), days, by))
    opn = arg(a, '--open')
    return BASE + '?invite=' + tok + ('&brief=' + opn.upper() if opn else ''), ('all docs' if ids is None else f'{len(ids)} doc(s)'), days


def main():
    a = sys.argv[1:]
    if not a: sys.exit(__doc__)
    with psycopg.connect(DSN, autocommit=True) as c:
        if a[0] == 'invite':
            link, scope, days = invite(c, a[1], a)
            print(f'{a[1]}: editor for {scope}. Personal sign-in link (30 days max, {days} set, revocable):\n{link}')
        elif a[0] == 'list':
            for r in c.execute("""select e.email, case when e.doc_ids is null then 'ALL' else (select string_agg(d.brief_number, ',') from copy_docs d where d.id = any(e.doc_ids)) end,
                       (select count(*) from copy_doc_invites i where i.user_id=e.user_id and i.revoked_at is null and i.expires_at>now()),
                       (select max(i.last_used_at) from copy_doc_invites i where i.user_id=e.user_id),
                       (select count(*) from auth.sessions s where s.user_id=e.user_id)
                       from copy_doc_editors e order by e.added_at""").fetchall():
                print(f'{r[0]:32} docs={r[1]}  live_invites={r[2]}  invite_last_used={r[3]}  signed_in_browsers={r[4]}')
            req = c.execute('select email, created_at from copy_doc_link_requests where handled_at is null order by created_at').fetchall()
            if req: print('link requests waiting:', req)
        elif a[0] in ('revoke', 'remove'):
            email = a[1].strip().lower()
            n = c.execute('update copy_doc_invites set revoked_at=now() where lower(email)=%s and revoked_at is null', (email,)).rowcount
            print(f'{email}: {n} invite link(s) revoked')
            if a[0] == 'remove':
                row = c.execute('select user_id from copy_doc_editors where lower(email)=%s', (email,)).fetchone()
                if row:
                    c.execute('delete from copy_doc_editors where user_id=%s', (row[0],))
                    s = c.execute('delete from auth.sessions where user_id=%s', (row[0],)).rowcount
                    print(f'{email}: editor access removed, signed out of {s} browser(s)')
        else:
            sys.exit(__doc__)


if __name__ == '__main__':
    main()
