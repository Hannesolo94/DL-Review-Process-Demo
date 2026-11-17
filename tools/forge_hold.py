"""Put a FORGE board on hold, or take it off (Nov 17 2026).

    python -I tools/forge_hold.py set   <slug> "<why>" [--by NAME]
    python -I tools/forge_hold.py clear <slug>
    python -I tools/forge_hold.py show  <slug>

A held board shows an amber "NOT READY: being fixed (<why>)" bar on forge.html and its cards dim. Only the critic
(Inquisitor) or Magnus sets and clears it. The script reads the row first and backs it up to backups/forge_hold/,
then changes data.hold and nothing else (one jsonb_set / jsonb minus, updated_at untouched), and checks that the rest
of data is unchanged afterwards.
"""
import argparse
import datetime as dt
import json
import pathlib
import sys

import psycopg

ROOT = pathlib.Path(__file__).resolve().parent.parent
BACKUP = ROOT / 'backups' / 'forge_hold'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('action', choices=['set', 'clear', 'show'])
    ap.add_argument('slug')
    ap.add_argument('why', nargs='?', default='')
    ap.add_argument('--by', default='Magnus')
    a = ap.parse_args()
    if not a.slug.startswith('FORGE-'):
        sys.exit('only FORGE boards (slug FORGE-...)')
    if a.action == 'set' and not a.why.strip():
        sys.exit('set needs a why')
    dsn = (ROOT / '.dsn').read_text().strip()
    with psycopg.connect(dsn) as c:
        row = c.execute('select id, data from briefs where slug = %s for update', (a.slug,)).fetchone()
        if not row:
            sys.exit(f'no board {a.slug}')
        bid, data = row
        if a.action == 'show':
            print(json.dumps(data.get('hold'), ensure_ascii=False))
            return
        if (data or {}).get('type') != 'forge':
            sys.exit(f'{a.slug} is not a FORGE board')
        BACKUP.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now().strftime('%Y%m%d_%H%M%S')
        (BACKUP / f'{a.slug}_{stamp}.json').write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
        if a.action == 'set':
            hold = {'by': a.by, 'why': a.why.strip(), 'since': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')}
            c.execute("update briefs set data = jsonb_set(data, '{hold}', %s::jsonb, true) where id = %s",
                      (json.dumps(hold, ensure_ascii=False), bid))
        else:
            if 'hold' not in data:
                print(f'{a.slug}: no hold to clear')
                return
            c.execute("update briefs set data = data - 'hold' where id = %s", (bid,))
        after = c.execute('select data from briefs where id = %s', (bid,)).fetchone()[0]
        rest = lambda d: {k: v for k, v in d.items() if k != 'hold'}
        if rest(after) != rest(data):
            c.rollback()
            sys.exit(f'{a.slug}: something other than hold changed, rolled back')
        c.commit()
        print(f"{a.slug}: hold {'set' if a.action == 'set' else 'cleared'}" + (f" ({after['hold']['why']})" if a.action == 'set' else ''))


if __name__ == '__main__':
    main()
