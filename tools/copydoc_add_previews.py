"""Add a linkPreview block after every block that holds a link with no preview yet (COPY DOCS v1.1, Nov 19 2026).
Same rule as the editor's Previews button. Keeps every edit; saves a version first.
Usage: python copydoc_add_previews.py <copy_doc_id> [--dry]"""
import json, re, sys, uuid, pathlib
import psycopg

DSN = pathlib.Path(r'D:/review-canvas/.dsn').read_text().strip()
SKIP = re.compile(r'^https?://([\w-]+\.)?notion\.(so|com|site)/')   # the Notion original needs Notion's own login
URL_RE = re.compile(r'https?://[^\s)<>"]+')


def links(block):
    out = []
    def walk(ic):
        for n in ic if isinstance(ic, list) else []:
            if n.get('type') == 'link' and str(n.get('href', '')).startswith('http'):
                out.append((n['href'], ''.join(t.get('text', '') for t in n.get('content', []))))
            elif n.get('type') == 'text':
                out.extend((u, '') for u in URL_RE.findall(n.get('text', '')))
    c = block.get('content')
    if isinstance(c, list): walk(c)
    elif isinstance(c, dict) and c.get('type') == 'tableContent':
        for r in c.get('rows', []):
            for cell in r.get('cells', []): walk(cell if isinstance(cell, list) else cell.get('content', []))
    return out


def add(blocks):
    have = set()
    def scan(bs):
        for b in bs:
            if b.get('type') == 'linkPreview': have.add(b.get('props', {}).get('url'))
            scan(b.get('children', []))
    scan(blocks)
    n = 0
    def walk(bs):
        nonlocal n
        out = []
        for b in bs:
            if b.get('children'): b['children'] = walk(b['children'])
            out.append(b)
            if b.get('type') == 'linkPreview': continue
            for url, text in links(b):
                if url in have or SKIP.search(url): continue
                have.add(url); n += 1
                out.append({'id': str(uuid.uuid4()), 'type': 'linkPreview', 'props': {'url': url, 'title': text if text and text != url else '', 'mode': 'preview'}, 'children': []})
        return out
    return walk(blocks), n


if __name__ == '__main__':
    doc = sys.argv[1]
    with psycopg.connect(DSN, autocommit=True) as c:
        title, content, upd = c.execute('select title, content, updated_at from copy_docs where id=%s', (doc,)).fetchone()
        new, n = add(content)
        print(f'{n} previews to add (doc updated {upd})')
        if n and '--dry' not in sys.argv:
            c.execute("insert into copy_doc_versions (doc_id, title, content, label, created_by) values (%s,%s,%s,'before previews','copydoc_add_previews')", (doc, title, json.dumps(content)))
            c.execute('update copy_docs set content=%s where id=%s and updated_at=%s', (json.dumps(new), doc, upd))
            print('saved')
