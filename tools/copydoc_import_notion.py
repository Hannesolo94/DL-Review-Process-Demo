"""READ-ONLY import of a Notion page into a DL Copy Doc (Nov 19 2026).
Only GETs Notion. Never writes back to Notion.
Usage: python copydoc_import_notion.py <notion_page_id> <BRIEF_NUMBER> [--replace <copy_doc_id>]
Images are downloaded and re-uploaded to the private copy-doc-images bucket (Notion file URLs expire)."""
import json, os, re, sys, time, uuid, pathlib, urllib.request, urllib.error, mimetypes
import psycopg

HOME = os.path.expanduser('~')
ENV = dict(l.split('=', 1) for l in pathlib.Path(r'D:/review-canvas/.env').read_text().splitlines() if '=' in l)
SB_URL, SB_SECRET = ENV['SUPABASE_URL'].strip(), ENV['SUPABASE_SECRET_KEY'].strip()
DSN = pathlib.Path(r'D:/review-canvas/.dsn').read_text().strip()


def ntoken():
    cfg = json.load(open(os.path.join(HOME, '.claude', 'mcp_notion.json')))
    return re.search(r'(secret_[A-Za-z0-9]+|ntn_[A-Za-z0-9_-]+)', json.dumps(cfg)).group(1)


def nget(path):
    for i in range(4):
        req = urllib.request.Request('https://api.notion.com/v1' + path, headers={
            'Authorization': 'Bearer ' + ntoken(), 'Notion-Version': '2022-06-28'})
        try:
            return json.load(urllib.request.urlopen(req, timeout=30))
        except urllib.error.HTTPError as e:
            if e.code == 429: time.sleep(2 + i * 2); continue
            raise


def children(bid):
    out, cur = [], None
    while True:
        d = nget(f'/blocks/{bid}/children?page_size=100' + (f'&start_cursor={cur}' if cur else ''))
        out += d['results']
        if not d.get('has_more'): return out
        cur = d['next_cursor']


DOC_ID = None


def upload_image(url):
    data = urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'copydoc-import'}), timeout=60).read()
    ctype = mimetypes.guess_type(url.split('?')[0])[0] or 'image/png'
    if ctype not in ('image/png', 'image/jpeg', 'image/webp', 'image/gif'): ctype = 'image/png'
    path = f'{DOC_ID}/notion-{uuid.uuid4().hex[:10]}.{ctype.split("/")[1].replace("jpeg", "jpg")}'
    req = urllib.request.Request(f'{SB_URL}/storage/v1/object/copy-doc-images/{path}', data=data, method='POST',
        headers={'apikey': SB_SECRET, 'Authorization': 'Bearer ' + SB_SECRET, 'Content-Type': ctype})
    urllib.request.urlopen(req, timeout=60).read()
    return 'sbimg://' + path


COLORS = {'gray', 'brown', 'red', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink'}


def rich(rt):
    out = []
    for r in rt or []:
        a = r.get('annotations', {})
        styles = {k: True for k, n in (('bold', 'bold'), ('italic', 'italic'), ('underline', 'underline'), ('strike', 'strikethrough'), ('code', 'code')) if a.get(n)}
        col = a.get('color', 'default')
        if col.endswith('_background') and col[:-11] in COLORS: styles['backgroundColor'] = col[:-11]
        elif col in COLORS: styles['textColor'] = col
        text = r.get('plain_text', '')
        href = r.get('href')
        if r.get('type') == 'mention' and not href:
            m = r['mention']
            if m.get('type') == 'page': href = 'https://www.notion.so/' + m['page']['id'].replace('-', '')
        node = {'type': 'text', 'text': text, 'styles': styles}
        out.append({'type': 'link', 'href': href, 'content': [node]} if href else node)
    return out


stats = {}
SKIPPED = []


def conv(b):
    t = b['type']; v = b.get(t, {}); stats[t] = stats.get(t, 0) + 1
    kids = []
    if b.get('has_children') and t not in ('child_page', 'child_database', 'table'):
        kids = convall(children(b['id']))
    if t in ('column_list', 'column', 'synced_block'):
        return kids
    props = {}
    if v.get('color', 'default') not in ('default', None):
        c = v['color']
        if c.endswith('_background') and c[:-11] in COLORS: props['backgroundColor'] = c[:-11]
        elif c in COLORS: props['textColor'] = c
    if t == 'paragraph': blk = {'type': 'paragraph', 'content': rich(v['rich_text'])}
    elif t in ('heading_1', 'heading_2', 'heading_3'):
        props['level'] = int(t[-1])
        if v.get('is_toggleable'): props['isToggleable'] = True
        blk = {'type': 'heading', 'content': rich(v['rich_text'])}
    elif t == 'bulleted_list_item': blk = {'type': 'bulletListItem', 'content': rich(v['rich_text'])}
    elif t == 'numbered_list_item': blk = {'type': 'numberedListItem', 'content': rich(v['rich_text'])}
    elif t == 'to_do': props['checked'] = bool(v.get('checked')); blk = {'type': 'checkListItem', 'content': rich(v['rich_text'])}
    elif t == 'toggle': blk = {'type': 'toggleListItem', 'content': rich(v['rich_text'])}
    elif t == 'quote': blk = {'type': 'quote', 'content': rich(v['rich_text'])}
    elif t == 'callout':
        icon = (v.get('icon') or {}).get('emoji', '')
        props.setdefault('backgroundColor', 'yellow' if not props.get('backgroundColor') else props['backgroundColor'])
        props.pop('textColor', None)
        blk = {'type': 'quote', 'content': ([{'type': 'text', 'text': icon + ' ', 'styles': {}}] if icon else []) + rich(v['rich_text'])}
    elif t == 'divider': blk = {'type': 'divider'}
    elif t == 'code': props['language'] = (v.get('language') or 'text').lower(); blk = {'type': 'codeBlock', 'content': ''.join(r['plain_text'] for r in v['rich_text'])}
    elif t == 'image':
        # Nov 19 rule: media stays in Drive; never copy into Supabase. Notion-hosted files can't preview (their URLs
        # expire), so they're listed and left out; external image URLs stay as a plain image block.
        cap = ''.join(r['plain_text'] for r in v.get('caption', []))
        if v.get('type') == 'external':
            props.update({'url': v['external']['url'], 'caption': cap}); blk = {'type': 'image'}
        else:
            name = (v.get('file', {}).get('url', '').split('?')[0].rsplit('/', 1)[-1]) or 'image'
            SKIPPED.append(f'Notion-hosted image "{cap or name}" (block {b["id"]})')
            blk = {'type': 'paragraph', 'content': [{'type': 'text', 'text': f'[Image stayed in Notion, not imported: {cap or name}. Put it in Drive and paste the Drive link here.]', 'styles': {'italic': True, 'textColor': 'gray'}}]}
    elif t == 'table':
        rows = [{'cells': [rich(c) for c in r['table_row']['cells']]} for r in children(b['id'])]
        blk = {'type': 'table', 'content': {'type': 'tableContent', 'rows': rows}}
    elif t in ('bookmark', 'embed', 'link_preview', 'video', 'file', 'pdf'):
        u = v.get('url') or v.get('external', {}).get('url') or v.get('file', {}).get('url', '')
        if v.get('type') == 'file': SKIPPED.append(f'Notion-hosted {t} (block {b["id"]}): link expires')
        label = ''.join(r['plain_text'] for r in v.get('caption', [])) or u
        blk = {'type': 'paragraph', 'content': [{'type': 'link', 'href': u, 'content': [{'type': 'text', 'text': '🔗 ' + label, 'styles': {}}]}]}
    elif t == 'child_page':
        blk = {'type': 'paragraph', 'content': [{'type': 'link', 'href': 'https://www.notion.so/' + b['id'].replace('-', ''), 'content': [{'type': 'text', 'text': '📄 ' + v.get('title', 'Page'), 'styles': {}}]}]}
    elif t == 'child_database':
        blk = {'type': 'paragraph', 'content': [{'type': 'link', 'href': 'https://www.notion.so/' + b['id'].replace('-', ''), 'content': [{'type': 'text', 'text': '🗂 ' + v.get('title', 'Database') + ' (Notion database, not imported)', 'styles': {}}]}]}
    else:
        SKIPPED.append(f'{t} block {b["id"]}')
        blk = {'type': 'paragraph', 'content': [{'type': 'text', 'text': f'[Notion {t} block not imported]', 'styles': {'italic': True}}]}
    if props: blk['props'] = props
    if kids: blk['children'] = kids
    blk['id'] = str(uuid.uuid4())   # stable ids: toggle open/closed state is stored per block id
    return [blk]


def convall(bs):
    out = []
    for b in bs: out += conv(b)
    return out


def main():
    global DOC_ID
    pid, brief = sys.argv[1], sys.argv[2].upper()
    replace = sys.argv[sys.argv.index('--replace') + 1] if '--replace' in sys.argv else None
    page = nget(f'/pages/{pid}')
    title = ''.join(r['plain_text'] for p in page['properties'].values() if p['type'] == 'title' for r in p['title']) or brief
    DOC_ID = replace or str(uuid.uuid4())
    blocks = [{'id': str(uuid.uuid4()), 'type': 'quote', 'props': {'backgroundColor': 'gray'}, 'content': [
        {'type': 'text', 'text': 'Imported read-only from Notion on ' + time.strftime('%d %b %Y %H:%M') + '. ', 'styles': {}},
        {'type': 'link', 'href': page['url'], 'content': [{'type': 'text', 'text': 'Original in Notion', 'styles': {}}]}]}]
    blocks += convall(children(pid))
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from copydoc_add_previews import add as add_previews   # v1.1: every original gets an in-doc preview
    blocks, _ = add_previews(blocks)
    brand = re.match(r'[A-Z]+', brief).group(0)
    with psycopg.connect(DSN, autocommit=True) as c:
        if replace:
            c.execute('update copy_docs set content=%s, title=%s where id=%s', (json.dumps(blocks), title, DOC_ID))
        else:
            c.execute('insert into copy_docs (id, brief_number, brand, title, content, source, updated_by) values (%s,%s,%s,%s,%s,%s,%s)',
                      (DOC_ID, brief, brand, title, json.dumps(blocks), 'notion-import:' + pid, 'notion-import'))
        c.execute("insert into copy_doc_versions (doc_id, title, content, label, created_by) values (%s,%s,%s,'import','notion-import')",
                  (DOC_ID, title, json.dumps(blocks)))
    print(json.dumps({'doc_id': DOC_ID, 'title': title, 'top_blocks': len(blocks), 'notion_block_types': stats, 'not_imported': SKIPPED}))


if __name__ == '__main__':
    main()
