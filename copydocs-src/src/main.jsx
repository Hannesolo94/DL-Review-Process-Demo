import React, { useEffect, useMemo, useRef, useState, useCallback } from 'react';
import { createRoot } from 'react-dom/client';
import { useCreateBlockNote, SuggestionMenuController, getDefaultReactSlashMenuItems } from '@blocknote/react';
import { BlockNoteSchema, defaultBlockSpecs, filterSuggestionItems, insertOrUpdateBlockForSlashMenu } from '@blocknote/core';
import { LinkPreview, addPreviews } from './preview.jsx';

const schema = BlockNoteSchema.create({ blockSpecs: { ...defaultBlockSpecs, linkPreview: LinkPreview() } });
import { BlockNoteView } from '@blocknote/mantine';
import '@blocknote/core/fonts/inter.css';
import '@blocknote/mantine/style.css';
import './app.css';
import { sb, resolveFileUrl, makeUploader } from './sb.js';

const qs = () => new URLSearchParams(location.search);
const go = (params) => { const u = new URL(location.href); u.search = new URLSearchParams(params).toString(); u.hash = ''; history.pushState({}, '', u); window.dispatchEvent(new Event('cd-nav')); };
const fmt = (t) => { if (!t) return ''; const d = new Date(t); const now = new Date(); const same = d.toDateString() === now.toDateString();
  return same ? d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : d.toLocaleDateString([], { day: 'numeric', month: 'short' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); };
const canon = (v) => JSON.stringify(v, (k, x) => (x && typeof x === 'object' && !Array.isArray(x) ? Object.keys(x).sort().reduce((o, kk) => { o[kk] = x[kk]; return o; }, {}) : x));
const IMG_MSG = 'Images live in Drive: paste the Drive link and it previews here.';
function toast(msg) {
  let t = document.getElementById('cd-toast');
  if (!t) { t = document.createElement('div'); t.id = 'cd-toast'; t.setAttribute('role', 'status'); document.body.appendChild(t); }
  t.textContent = msg; t.className = 'on'; clearTimeout(t._h); t._h = setTimeout(() => { t.className = ''; }, 4500);
}
// image files dropped anywhere on the page: blocked (capture phase, before the editor sees them)
window.addEventListener('drop', (e) => { const fs = e.dataTransfer && [...e.dataTransfer.files]; if (fs && fs.some((f) => f.type.startsWith('image/'))) { e.preventDefault(); e.stopPropagation(); toast(IMG_MSG); } }, true);
window.addEventListener('dragover', (e) => { if (e.dataTransfer && [...e.dataTransfer.items || []].some((i) => i.kind === 'file')) e.preventDefault(); }, true);
const brandOf = (bn) => ((bn || '').match(/^[A-Za-z]+/) || [''])[0].toUpperCase();

/* ---------------- auth ---------------- */
function useSession() {
  const [state, setState] = useState({ loading: true, session: null, editor: false, err: '' });
  useEffect(() => {
    let alive = true;
    (async () => {
      const p = qs(); const hash = p.get('login');
      if (hash) {
        const { error } = await sb.auth.verifyOtp({ token_hash: hash, type: 'magiclink' });
        p.delete('login'); const u = new URL(location.href); u.search = p.toString(); history.replaceState({}, '', u);
        if (error && alive) setState((s) => ({ ...s, err: 'That sign-in link has expired or was already used. Open a fresh one from the hub.' }));
      }
      const { data } = await sb.auth.getSession();
      let editor = false;
      if (data.session) { const r = await sb.rpc('is_copy_editor'); editor = r.data === true; }
      if (alive) setState((s) => ({ ...s, loading: false, session: data.session, editor }));
    })();
    const { data: sub } = sb.auth.onAuthStateChange((_e, session) => { if (!session) setState((s) => ({ ...s, session: null, editor: false })); });
    return () => { alive = false; sub.subscription.unsubscribe(); };
  }, []);
  return state;
}

function Gate({ err, signedInButNotEditor }) {
  return (
    <div className="gate">
      <div className="gate-card">
        <div className="logo">DL <span>COPY DOCS</span></div>
        {signedInButNotEditor
          ? <p>This account can't open copy docs.</p>
          : <p>These are internal DL Media briefs. Sign in from the hub: <b>CRAFT → COPY DOCS → OPEN</b>. On your phone, do the same in the hub on your phone. After that, this browser stays signed in and brief links open straight away.</p>}
        {err && <p className="err">{err}</p>}
        {signedInButNotEditor && <button className="btn" onClick={() => sb.auth.signOut().then(() => location.reload())}>Sign out</button>}
      </div>
    </div>
  );
}

/* ---------------- list ---------------- */
function DocList() {
  const [docs, setDocs] = useState(null); const [q, setQ] = useState(''); const [err, setErr] = useState('');
  useEffect(() => { sb.from('copy_docs').select('id,brief_number,brand,title,updated_at,updated_by,source').eq('archived', false).order('updated_at', { ascending: false })
    .then(({ data, error }) => { if (error) setErr(error.message); setDocs(data || []); }); }, []);
  const create = async () => {
    const bn = (prompt('Brief number (e.g. PLT0213). Leave empty if none:') || '').trim().toUpperCase();
    const title = (prompt('Title:', bn ? `${bn} - Copy Doc` : 'Untitled copy doc') || '').trim() || 'Untitled copy doc';
    const { data, error } = await sb.from('copy_docs').insert({ brief_number: bn || null, brand: brandOf(bn) || null, title,
      content: [{ type: 'heading', props: { level: 1 }, content: title }, { type: 'paragraph' }] }).select('id').single();
    if (error) return alert(error.message);
    go({ doc: data.id });
  };
  const shown = (docs || []).filter((d) => !q || `${d.brief_number} ${d.brand} ${d.title}`.toLowerCase().includes(q.toLowerCase()));
  return (
    <div className="list">
      <header className="top">
        <div className="logo">DL <span>COPY DOCS</span></div>
        <div className="grow" />
        <button className="btn ghost" onClick={() => sb.auth.signOut().then(() => location.reload())}>Sign out</button>
      </header>
      <div className="list-tools">
        <input className="search" placeholder="Search brief, brand or title" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className="btn primary" onClick={create}>+ New copy doc</button>
      </div>
      {err && <p className="err">{err}</p>}
      {docs === null ? <p className="muted pad">Loading…</p> : shown.length === 0 ? <p className="muted pad">No copy docs yet.</p> : (
        <div className="rows">
          {shown.map((d) => (
            <a key={d.id} className="row" href={`?doc=${d.id}`} onClick={(e) => { if (e.metaKey || e.ctrlKey) return; e.preventDefault(); go({ doc: d.id }); }}>
              <span className="pill">{d.brief_number || '—'}</span>
              <span className="row-title">{d.title}</span>
              <span className="muted small">{fmt(d.updated_at)}</span>
            </a>
          ))}
        </div>
      )}
    </div>
  );
}

/* ---------------- doc ---------------- */
// Toggles open by default (Nov 19 09:46): BlockNote keeps each toggle's state in localStorage as toggle-<block id> and
// treats "no entry" as closed, so a fresh viewer saw an almost empty doc. Seed "open" for every toggle this browser has
// no state for; a toggle he closes stays closed.
function openTogglesByDefault(blocks) {
  const walk = (bs) => (bs || []).forEach((b) => {
    if (b && b.id && (b.type === 'toggleListItem' || (b.type === 'heading' && b.props && b.props.isToggleable))) {
      try { if (localStorage.getItem('toggle-' + b.id) === null) localStorage.setItem('toggle-' + b.id, 'true'); } catch (_) {}
    }
    walk(b && b.children);
  });
  walk(blocks);
}

function DocPage({ id }) {
  const [doc, setDoc] = useState(null); const [err, setErr] = useState('');
  useEffect(() => { sb.from('copy_docs').select('*').eq('id', id).maybeSingle().then(({ data, error }) => {
    if (error) setErr(error.message); else if (!data) setErr('Copy doc not found.'); else setDoc(data); }); }, [id]);
  if (err) return <div className="pad"><a href="?" onClick={(e) => { e.preventDefault(); go({}); }}>← All copy docs</a><p className="err">{err}</p></div>;
  if (!doc) return <p className="muted pad">Loading…</p>;
  openTogglesByDefault(doc.content);
  return <Editor key={doc.id} doc={doc} />;
}

function Editor({ doc }) {
  const [title, setTitle] = useState(doc.title);
  const [brief, setBrief] = useState(doc.brief_number || '');
  const [status, setStatus] = useState({ kind: 'saved', at: doc.updated_at });
  const [showHist, setShowHist] = useState(false);
  const lastAt = useRef(doc.updated_at);
  const dirty = useRef(false); const timer = useRef(null); const saving = useRef(false);
  const meta = useRef({ title: doc.title, brief: doc.brief_number || '' });

  const editor = useCreateBlockNote({
    schema,
    initialContent: Array.isArray(doc.content) && doc.content.length ? doc.content : undefined,
    // Nov 19 08:48 (Hannes's rule: media stays in Drive, Supabase holds no media): uploads are OFF until the Drive
    // path exists. makeUploader/the bucket stay in the code, unreachable from the UI. Image paste/drop shows a toast.
    uploadFile: undefined,
    pasteHandler: ({ event, editor: ed, defaultPasteHandler }) => {
      const dt = event.clipboardData;
      if (dt && [...dt.files].some((f) => f.type.startsWith('image/'))) { toast(IMG_MSG); return true; }
      const text = ((dt && dt.getData('text/plain')) || '').trim();
      if (/^https?:\/\/\S+$/.test(text) && !/notion\.(so|com|site)\//.test(text)) {   // a bare link: paste it, then drop its preview under it
        const ok = defaultPasteHandler();
        setTimeout(() => { try { const b = ed.getTextCursorPosition().block; ed.insertBlocks([{ type: 'linkPreview', props: { url: text, mode: 'preview' } }], b, 'after'); } catch (_) {} }, 0);
        return ok;
      }
      return defaultPasteHandler();
    },
    resolveFileUrl,
    tables: { splitCells: true, cellBackgroundColor: true, cellTextColor: true, headers: true },
  });
  const initJson = useRef(null); if (initJson.current === null) initJson.current = JSON.stringify(editor.document);

  // Nov 19 21:40 fix: Hannes lost ~1.5 h of edits. A save landed on the server but its answer never reached the tab,
  // so every later save hit the stale updated_at lock, matched 0 rows and showed a tiny "Changed elsewhere".
  // Now: 0 rows -> read the row; if it holds text this tab sent, carry on; if someone else wrote it, keep my text in
  // History and show a big banner; a failed save shows a big NOT SAVED banner and keeps retrying; a copy of unsaved
  // text stays on this device until the server confirms it.
  const tried = useRef(new Set()); const retryMs = useRef(3000); const conflictRef = useRef(null);
  const bkKey = 'cd-unsaved-' + doc.id;
  const keepLocal = () => { try { localStorage.setItem(bkKey, JSON.stringify({ at: Date.now(), title: meta.current.title, content: editor.document })); } catch (_) {} };
  const dropLocal = () => { try { localStorage.removeItem(bkKey); } catch (_) {} };
  const save = useCallback(async (force) => {
    if (saving.current) { dirty.current = true; return; }
    if (!dirty.current && !force) return;
    if (conflictRef.current && force !== 'mine') return;   // waiting for Hannes to pick reload or keep mine
    saving.current = true; dirty.current = false; setStatus((st) => ({ ...st, kind: 'saving' }));
    const content = editor.document; tried.current.add(canon(content));
    const bn = meta.current.brief.trim().toUpperCase() || null;
    const again = (kind, msg) => { saving.current = false; dirty.current = true; setStatus({ kind, msg, at: lastAt.current });
      clearTimeout(timer.current); timer.current = setTimeout(() => save(), retryMs.current); retryMs.current = Math.min(retryMs.current * 1.5, 20000); };
    let res;
    try { res = await sb.from('copy_docs')
      .update({ content, title: meta.current.title.trim() || 'Untitled copy doc', brief_number: bn, brand: brandOf(bn) || null })
      .eq('id', doc.id).eq('updated_at', lastAt.current).select('updated_at'); }
    catch (e) { res = { error: { message: String((e && e.message) || e) } }; }
    if (res.error) return again(/jwt|auth|401|403|permission/i.test(res.error.message + ' ' + (res.error.code || '')) ? 'auth' : 'error', res.error.message);
    if (res.data && res.data.length) {
      saving.current = false; lastAt.current = res.data[0].updated_at; tried.current.clear(); retryMs.current = 3000;
      setStatus({ kind: 'saved', at: res.data[0].updated_at });
      if (dirty.current) { clearTimeout(timer.current); timer.current = setTimeout(() => save(), 600); } else dropLocal();
      return;
    }
    // 0 rows: our own earlier write landed (answer lost), someone else wrote, or this browser can't see the doc
    let cur;
    try { cur = await sb.from('copy_docs').select('updated_at,updated_by,content').eq('id', doc.id).maybeSingle(); }
    catch (e) { cur = { error: { message: String((e && e.message) || e) } }; }
    if (cur.error) return again('error', cur.error.message);
    if (!cur.data) return again('auth', 'this browser cannot see the doc');
    if (tried.current.has(canon(cur.data.content))) {   // it's text this tab sent: take the new lock and keep going
      saving.current = false; lastAt.current = cur.data.updated_at; dirty.current = true; retryMs.current = 3000;
      clearTimeout(timer.current); timer.current = setTimeout(() => save(), 50); return;
    }
    saving.current = false; dirty.current = true; conflictRef.current = cur.data;
    const v = await sb.from('copy_doc_versions').insert({ doc_id: doc.id, title: meta.current.title, content: editor.document, label: 'my unsaved text (conflict)' });
    setStatus({ kind: 'conflict', at: cur.data.updated_at, by: cur.data.updated_by, kept: !v.error });
  }, [editor, doc.id]);
  const keepMine = () => { const c = conflictRef.current; if (!c) return; lastAt.current = c.updated_at; conflictRef.current = null; dirty.current = true; save('mine'); };

  const lastJson = useRef(null);   // set from the freshly loaded doc on first change, so opening a doc never saves
  const schedule = useCallback((ed) => {
    if (ed && ed.document) { const j = JSON.stringify(ed.document); if (lastJson.current === null) lastJson.current = initJson.current; if (lastJson.current === j) return; lastJson.current = j; }
    dirty.current = true; keepLocal(); if (!conflictRef.current) setStatus((st) => (st.kind === 'error' || st.kind === 'auth' ? st : { kind: 'editing', at: lastAt.current }));
    clearTimeout(timer.current); timer.current = setTimeout(() => save(), 900); }, [save]);

  useEffect(() => {
    const flush = () => { if (dirty.current) save(); };
    const warn = (e) => { if (dirty.current || saving.current) { e.preventDefault(); e.returnValue = ''; flush(); } };
    const online = () => { if (dirty.current) { retryMs.current = 3000; save(); } };
    document.addEventListener('visibilitychange', flush); window.addEventListener('beforeunload', warn); window.addEventListener('online', online);
    return () => { document.removeEventListener('visibilitychange', flush); window.removeEventListener('beforeunload', warn); window.removeEventListener('online', online); clearTimeout(timer.current); };
  }, [save]);

  const [offer, setOffer] = useState(() => { try { const b = JSON.parse(localStorage.getItem('cd-unsaved-' + doc.id) || 'null');
    return b && Array.isArray(b.content) && canon(b.content) !== canon(doc.content) ? b : null; } catch (_) { return null; } });
  const useOffer = async () => { const b = offer; setOffer(null); await snapshot('before restoring device copy');
    editor.replaceBlocks(editor.document, b.content.length ? b.content : [{ type: 'paragraph' }]);
    if (b.title) { setTitle(b.title); meta.current.title = b.title; } schedule(); };
  const snapshot = async (label) => {
    const { error } = await sb.from('copy_doc_versions').insert({ doc_id: doc.id, title: meta.current.title, content: editor.document, label });
    if (error) alert(error.message);
  };
  const restore = async (v) => {
    if (!confirm(`Restore the version from ${fmt(v.created_at)}? The current text is kept as a version first, so you can undo this.`)) return;
    await snapshot('before restore');
    editor.replaceBlocks(editor.document, Array.isArray(v.content) && v.content.length ? v.content : [{ type: 'paragraph' }]);
    if (v.title) { setTitle(v.title); meta.current.title = v.title; }
    schedule(); setShowHist(false);
  };

  const hm = (t) => (t ? new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false }) : '');
  const label = status.kind === 'saving' ? 'Saving…' : status.kind === 'editing' ? 'Editing…'
    : status.kind === 'error' || status.kind === 'auth' || status.kind === 'conflict' ? 'NOT SAVED' : `Saved ${hm(status.at)}`;
  const banner = status.kind === 'error' ? <>NOT SAVED: your last changes haven't reached the server ({status.msg}). Retrying by itself; keep this tab open. A copy is kept on this device.</>
    : status.kind === 'auth' ? <>NOT SAVED: this browser is signed out. Sign in again from the hub (CRAFT → COPY DOCS → OPEN) in another tab; this tab keeps retrying and keeps a copy on this device.</>
    : status.kind === 'conflict' ? <>NOT SAVED: someone else changed this doc at {hm(status.at)}{status.by ? ` (${status.by})` : ''}. {status.kept ? 'Your text is safe in History as "my unsaved text (conflict)".' : 'Copy your text somewhere before reloading.'}
        <span className="banner-acts"><button className="btn" onClick={() => { dropLocal(); location.reload(); }}>Reload to see theirs</button><button className="btn ghost" onClick={keepMine}>Keep mine (overwrite theirs)</button></span></>
    : null;

  return (
    <div className="doc">
      <header className="top sticky">
        <a className="back" href="?" onClick={(e) => { e.preventDefault(); save(); go({}); }}>←<span className="hide-sm"> All docs</span></a>
        <input className="brief-in" value={brief} placeholder="Brief #" onChange={(e) => { setBrief(e.target.value); meta.current.brief = e.target.value; schedule(); }} />
        <div className="grow" />
        <span className={'status ' + status.kind}>{label}</span>
        <button className="btn ghost icon" title="Undo (Ctrl+Z)" onClick={() => editor.undo()}>↶</button>
        <button className="btn ghost icon" title="Redo (Ctrl+Shift+Z)" onClick={() => editor.redo()}>↷</button>
        <button className="btn ghost" title="Add a preview under every link that doesn't have one yet" onClick={() => { const n = addPreviews(editor); if (!n) alert('Every link already has a preview.'); }}>Previews</button>
        <button className="btn ghost" onClick={() => setShowHist(true)}>History</button>
        <button className="btn ghost hide-sm" onClick={() => { navigator.clipboard.writeText(location.origin + location.pathname + '?doc=' + doc.id); }} title="Copy this doc's link (only signed-in editors can open it)">Copy link</button>
      </header>
      {banner && <div className="banner bad" role="alert">{banner}</div>}
      {offer && !banner && <div className="banner warn" role="alert">This device has text from {hm(offer.at)} that never reached the server.<span className="banner-acts"><button className="btn" onClick={useOffer}>Restore it</button><button className="btn ghost" onClick={() => { dropLocal(); setOffer(null); }}>Discard</button></span></div>}
      <main className="page">

        <input className="title-in" value={title} placeholder="Untitled" onChange={(e) => { setTitle(e.target.value); meta.current.title = e.target.value; schedule(); }} />
        <BlockNoteView editor={editor} theme="dark" onChange={schedule} slashMenu={false}>
          <SuggestionMenuController triggerCharacter="/" getItems={async (q) => filterSuggestionItems([...getDefaultReactSlashMenuItems(editor), {
            title: 'Link preview', subtext: 'Preview a Drive file/folder, YouTube, Instagram, TikTok or any link', aliases: ['embed', 'preview', 'drive', 'link'], group: 'Media',
            onItemClick: () => { const url = (prompt('Paste the link to preview:') || '').trim(); if (url) insertOrUpdateBlockForSlashMenu(editor, { type: 'linkPreview', props: { url } }); },
          }], q)} />
        </BlockNoteView>
        <p className="hint">Type <kbd>/</kbd> for blocks · paste a Drive / YouTube / Instagram / TikTok / store link and it previews here · <b>Previews</b> adds one for every link · drag the ⋮⋮ handle to move a block · select text to format</p>
      </main>
      {showHist && <History docId={doc.id} onClose={() => setShowHist(false)} onRestore={restore} onSnapshot={async () => { const l = prompt('Name this version (optional):') ; if (l === null) return; await snapshot(l.trim() || 'manual'); }} />}
    </div>
  );
}

function History({ docId, onClose, onRestore, onSnapshot }) {
  const [rows, setRows] = useState(null); const [n, setN] = useState(0);
  useEffect(() => { sb.from('copy_doc_versions').select('id,created_at,label,title,created_by,content').eq('doc_id', docId).order('created_at', { ascending: false }).limit(100)
    .then(({ data }) => setRows(data || [])); }, [docId, n]);
  const words = (c) => JSON.stringify(c || []).replace(/"(type|props|id|styles|children|content|level|textColor|backgroundColor|textAlignment)"/g, '').length;
  return (
    <div className="drawer-wrap" onClick={onClose}>
      <aside className="drawer" onClick={(e) => e.stopPropagation()}>
        <div className="drawer-head"><b>Version history</b><div className="grow" /><button className="btn ghost" onClick={onClose}>Close</button></div>
        <button className="btn primary full" onClick={async () => { await onSnapshot(); setN(n + 1); }}>Save a version now</button>
        <p className="muted small">A version is kept automatically every 10 minutes of editing, before every restore, and whenever you save one.</p>
        {rows === null ? <p className="muted">Loading…</p> : rows.length === 0 ? <p className="muted">No versions yet.</p> : rows.map((v) => (
          <div key={v.id} className="ver">
            <div><b>{fmt(v.created_at)}</b> <span className="pill small">{v.label || 'auto'}</span></div>
            <div className="muted small">{v.title} · {Math.round(words(v.content) / 100) / 10}k chars</div>
            <button className="btn ghost" onClick={() => onRestore(v)}>Restore</button>
          </div>
        ))}
      </aside>
    </div>
  );
}

/* ---------------- app ---------------- */
function App() {
  const auth = useSession();
  const [, force] = useState(0);
  useEffect(() => { const f = () => force((x) => x + 1); window.addEventListener('popstate', f); window.addEventListener('cd-nav', f);
    return () => { window.removeEventListener('popstate', f); window.removeEventListener('cd-nav', f); }; }, []);
  const [briefDoc, setBriefDoc] = useState(null);
  const p = qs(); const id = p.get('doc'); const brief = p.get('brief');
  useEffect(() => {
    if (!brief || id || !auth.editor) return;
    sb.from('copy_docs').select('id').eq('brief_number', brief.toUpperCase()).eq('archived', false).order('updated_at', { ascending: false }).limit(1)
      .then(({ data }) => { if (data && data[0]) { const u = new URL(location.href); u.search = '?doc=' + data[0].id; history.replaceState({}, '', u); force((x) => x + 1); } else setBriefDoc('none'); });
  }, [brief, id, auth.editor]);
  if (auth.loading) return <p className="muted pad">Loading…</p>;
  if (!auth.session) return <Gate err={auth.err} />;
  if (!auth.editor) return <Gate signedInButNotEditor />;
  if (id) return <DocPage id={id} />;
  if (brief && briefDoc === 'none') return <div className="pad"><p>No copy doc for {brief.toUpperCase()} yet.</p><a href="?" onClick={(e) => { e.preventDefault(); go({}); }}>← All copy docs</a></div>;
  if (brief) return <p className="muted pad">Loading…</p>;
  return <DocList />;
}

createRoot(document.getElementById('root')).render(<App />);
