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
    """Every block that holds links gets a preview for each of them directly under it (Nov 19 09:35: a link used in
    two places gets a preview in both). Previews already sitting right after the block count; nothing is removed."""
    n = 0
    def walk(bs):
        nonlocal n
        out, i = [], 0
        while i < len(bs):
            b = bs[i]
            if b.get('children'): b['children'] = walk(b['children'])
            out.append(b); i += 1
            if b.get('type') == 'linkPreview': continue
            attached = set()
            while i < len(bs) and bs[i].get('type') == 'linkPreview':   # previews already under this block
                attached.add(bs[i].get('props', {}).get('url')); out.append(bs[i]); i += 1
            for url, text in links(b):
                if url in attached or SKIP.search(url): continue
                attached.add(url); n += 1
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
