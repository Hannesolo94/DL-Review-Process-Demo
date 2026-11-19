"""Import a markdown file into a DL Copy Doc (Nov 19 2026), for briefs with no Notion card (ODDS etc.).
Usage: python -I copydoc_import_md.py <file.md> --brief ODDS0001 --title "..." [--dry]

Markdown handled: # / ## / ### headings, paragraphs, - * + bullets (indent nests), 1. numbered, - [ ] to-dos,
> quotes, --- dividers, ``` code, **bold** *italic* _italic_ ~~strike~~ `code`, [text](url) and bare URLs.
Toggles: <details><summary>Title</summary> ... </details> becomes a toggle with the inner lines nested;
"## > Title" (a heading starting with "> ") becomes a toggleable heading with everything under it nested
until the next heading of the same or higher level. The page opens every toggle by default.
Every link gets a linkPreview block under its paragraph (same rule as copydoc_add_previews.py).
No images are uploaded: ![alt](url) becomes a plain link (paste Drive links; they preview).
Re-running for a brief that already has a doc: the current content is saved as a version
("before md import") first, then replaced, and a new "md-import" version is written. Nothing is lost."""
import json, re, sys, os, uuid, pathlib, time
import psycopg

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from copydoc_add_previews import add as add_previews

DSN = pathlib.Path(r'D:/review-canvas/.dsn').read_text().strip()
INLINE = re.compile(r'(\*\*(?P<b>.+?)\*\*|__(?P<b2>.+?)__|~~(?P<s>.+?)~~|`(?P<c>[^`]+)`|'
                    r'!?\[(?P<lt>[^\]]*)\]\((?P<lu>[^)\s]+)\)|(?<![\w*])\*(?P<i>[^*\s][^*]*?)\*(?!\*)|'
                    r'(?<![\w])_(?P<i2>[^_\s][^_]*?)_(?![\w])|(?P<url>https?://[^\s)<>"]+))')


def bid(): return str(uuid.uuid4())


def inline(text, styles=None):
    styles = dict(styles or {})
    out, pos = [], 0
    for m in INLINE.finditer(text):
        if m.start() > pos: out.append({'type': 'text', 'text': text[pos:m.start()], 'styles': dict(styles)})
        g = m.groupdict()
        if g['b'] or g['b2']: out += inline(g['b'] or g['b2'], {**styles, 'bold': True})
        elif g['s']: out += inline(g['s'], {**styles, 'strike': True})
        elif g['c']: out.append({'type': 'text', 'text': g['c'], 'styles': {**styles, 'code': True}})
        elif g['lu']:
            out.append({'type': 'link', 'href': g['lu'], 'content': inline(g['lt'] or g['lu'], styles) or [{'type': 'text', 'text': g['lu'], 'styles': dict(styles)}]})
        elif g['i'] or g['i2']: out += inline(g['i'] or g['i2'], {**styles, 'italic': True})
        elif g['url']:
            u = g['url'].rstrip('.,;:!?')
            out.append({'type': 'link', 'href': u, 'content': [{'type': 'text', 'text': u, 'styles': dict(styles)}]})
            if len(u) < len(g['url']): out.append({'type': 'text', 'text': g['url'][len(u):], 'styles': dict(styles)})
        pos = m.end()
    if pos < len(text): out.append({'type': 'text', 'text': text[pos:], 'styles': dict(styles)})
    return out


def blk(t, content=None, props=None, children=None):
    b = {'id': bid(), 'type': t}
    if content is not None: b['content'] = content
    if props: b['props'] = props
    b['children'] = children or []
    return b


LIST = re.compile(r'^(?P<ind>\s*)(?P<m>[-*+]|\d+[.)])\s+(?P<rest>.*)$')


def parse(lines):
    """lines -> list of blocks (recursive for <details> and toggle headings)."""
    out, para, i = [], [], 0
    stack = []   # (indent, block) for nested lists

    def flush():
        if para:
            out.append(blk('paragraph', inline(' '.join(s.strip() for s in para))))
            para.clear()

    while i < len(lines):
        ln = lines[i]; s = ln.strip()
        if not s:
            flush(); stack.clear(); i += 1; continue
        if s.startswith('```'):
            flush(); stack.clear(); lang = s[3:].strip() or 'text'; code = []; i += 1
            while i < len(lines) and not lines[i].strip().startswith('```'): code.append(lines[i]); i += 1
            out.append(blk('codeBlock', '\n'.join(code), {'language': lang})); i += 1; continue
        if re.match(r'^<details', s, re.I):
            flush(); stack.clear()
            m = re.search(r'<summary>(.*?)</summary>', s, re.I); j = i
            if not m:
                j += 1
                while j < len(lines) and not re.search(r'<summary>', lines[j], re.I): j += 1
                m = re.search(r'<summary>(.*?)</summary>', lines[j] if j < len(lines) else '', re.I)
            inner, depth, k = [], 1, j + 1
            while k < len(lines):
                t = lines[k].strip()
                if re.match(r'^<details', t, re.I): depth += 1
                if re.match(r'^</details>', t, re.I):
                    depth -= 1
                    if depth == 0: break
                inner.append(lines[k]); k += 1
            out.append(blk('toggleListItem', inline(m.group(1).strip() if m else 'Details'), children=parse(inner)))
            i = k + 1; continue
        h = re.match(r'^(#{1,6})\s+(.*)$', s)
        if h:
            flush(); stack.clear(); level = min(len(h.group(1)), 3); text = h.group(2).strip()
            if text.startswith('> '):   # toggle heading: nest everything until next heading of same/higher level
                k = i + 1; inner = []
                while k < len(lines):
                    hh = re.match(r'^(#{1,6})\s', lines[k].strip())
                    if hh and min(len(hh.group(1)), 3) <= level: break
                    inner.append(lines[k]); k += 1
                out.append(blk('heading', inline(text[2:].strip()), {'level': level, 'isToggleable': True}, parse(inner)))
                i = k; continue
            out.append(blk('heading', inline(text), {'level': level})); i += 1; continue
        if re.match(r'^(-{3,}|\*{3,}|_{3,})$', s):
            flush(); stack.clear(); out.append(blk('divider')); i += 1; continue
        if s.startswith('>'):
            flush(); stack.clear(); q = []
            while i < len(lines) and lines[i].strip().startswith('>'): q.append(lines[i].strip()[1:].strip()); i += 1
            out.append(blk('quote', inline(' '.join(q)))); continue
        m = LIST.match(ln)
        if m:
            flush(); ind = len(m.group('ind').expandtabs(4)); rest = m.group('rest')
            cb = re.match(r'^\[( |x|X)\]\s+(.*)$', rest)
            if cb: b = blk('checkListItem', inline(cb.group(2)), {'checked': cb.group(1).lower() == 'x'})
            elif m.group('m')[0].isdigit(): b = blk('numberedListItem', inline(rest))
            else: b = blk('bulletListItem', inline(rest))
            while stack and stack[-1][0] >= ind: stack.pop()
            (stack[-1][1]['children'] if stack else out).append(b)
            stack.append((ind, b)); i += 1; continue
        if stack and ln[:1] in (' ', '\t'):   # continuation line of a list item
            stack[-1][1]['content'] += inline(' ' + s); i += 1; continue
        stack.clear(); para.append(ln); i += 1
    flush()
    return out


def main():
    a = sys.argv[1:]
    if not a or '--brief' not in a or '--title' not in a:
        sys.exit(__doc__)
    path = a[0]; brief = a[a.index('--brief') + 1].strip().upper(); title = a[a.index('--title') + 1].strip()
    text = pathlib.Path(path).read_text(encoding='utf-8-sig')
    blocks = [blk('quote', [{'type': 'text', 'text': f'Imported from {pathlib.Path(path).name} on ' + time.strftime('%d %b %Y %H:%M') + '.', 'styles': {}}], {'backgroundColor': 'gray'})]
    blocks += parse(text.splitlines())
    blocks, n_prev = add_previews(blocks)
    brand = (re.match(r'[A-Z]+', brief) or re.match(r'.*', 'X')).group(0)
    if '--dry' in a:
        print(json.dumps({'brief': brief, 'top_blocks': len(blocks), 'previews': n_prev, 'blocks': blocks}, indent=1)[:6000]); return
    with psycopg.connect(DSN, autocommit=True) as c:
        row = c.execute('select id, title, content, updated_at from copy_docs where brief_number=%s and archived=false order by updated_at desc limit 1', (brief,)).fetchone()
        if row:
            doc, old_title, old_content, upd = row; doc = str(doc)
            c.execute("insert into copy_doc_versions (doc_id, title, content, label, created_by) values (%s,%s,%s,'before md import','copydoc_import_md')", (doc, old_title, json.dumps(old_content)))
            r = c.execute('update copy_docs set content=%s, title=%s, source=%s, updated_by=%s where id=%s and updated_at=%s',
                          (json.dumps(blocks), title, 'md-import:' + pathlib.Path(path).name, 'md-import', doc, upd))
            if r.rowcount != 1: sys.exit('The doc changed while importing; nothing replaced. Run again.')
            mode = 'replaced (previous content saved as version "before md import")'
        else:
            doc = str(uuid.uuid4())
            c.execute('insert into copy_docs (id, brief_number, brand, title, content, source, updated_by) values (%s,%s,%s,%s,%s,%s,%s)',
                      (doc, brief, brand, title, json.dumps(blocks), 'md-import:' + pathlib.Path(path).name, 'md-import'))
            mode = 'created'
        c.execute("insert into copy_doc_versions (doc_id, title, content, label, created_by) values (%s,%s,%s,'md-import','copydoc_import_md')", (doc, title, json.dumps(blocks)))
    print(json.dumps({'doc_id': doc, 'brief': brief, 'mode': mode, 'top_blocks': len(blocks), 'previews': n_prev,
                      'url': f'https://hannesolo94.github.io/DL-Review-Process-Demo/copy/?brief={brief}'}))


if __name__ == '__main__':
    main()
