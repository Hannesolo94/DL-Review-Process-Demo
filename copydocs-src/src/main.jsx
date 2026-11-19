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
function DocPage({ id }) {
  const [doc, setDoc] = useState(null); const [err, setErr] = useState('');
  useEffect(() => { sb.from('copy_docs').select('*').eq('id', id).maybeSingle().then(({ data, error }) => {
    if (error) setErr(error.message); else if (!data) setErr('Copy doc not found.'); else setDoc(data); }); }, [id]);
  if (err) return <div className="pad"><a href="?" onClick={(e) => { e.preventDefault(); go({}); }}>← All copy docs</a><p className="err">{err}</p></div>;
  if (!doc) return <p className="muted pad">Loading…</p>;
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
    uploadFile: makeUploader(doc.id),
    resolveFileUrl,
    tables: { splitCells: true, cellBackgroundColor: true, cellTextColor: true, headers: true },
  });

  const save = useCallback(async (force) => {
    if (saving.current) { dirty.current = true; return; }
    if (!dirty.current && !force) return;
    saving.current = true; dirty.current = false; setStatus({ kind: 'saving' });
    const bn = meta.current.brief.trim().toUpperCase() || null;
    const { data, error } = await sb.from('copy_docs')
      .update({ content: editor.document, title: meta.current.title.trim() || 'Untitled copy doc', brief_number: bn, brand: brandOf(bn) || null })
      .eq('id', doc.id).eq('updated_at', lastAt.current).select('updated_at');
    saving.current = false;
    if (error) { dirty.current = true; setStatus({ kind: 'error', msg: error.message }); clearTimeout(timer.current); timer.current = setTimeout(() => save(), 4000); return; }
    if (!data || !data.length) { setStatus({ kind: 'conflict' }); return; }
    lastAt.current = data[0].updated_at; setStatus({ kind: 'saved', at: data[0].updated_at });
    if (dirty.current) { clearTimeout(timer.current); timer.current = setTimeout(() => save(), 600); }
  }, [editor, doc.id]);

  const schedule = useCallback(() => { dirty.current = true; setStatus({ kind: 'editing' }); clearTimeout(timer.current); timer.current = setTimeout(() => save(), 900); }, [save]);

  useEffect(() => {
    const flush = () => { if (dirty.current) save(); };
    const warn = (e) => { if (dirty.current || saving.current) { e.preventDefault(); e.returnValue = ''; flush(); } };
    document.addEventListener('visibilitychange', flush); window.addEventListener('beforeunload', warn);
    return () => { document.removeEventListener('visibilitychange', flush); window.removeEventListener('beforeunload', warn); clearTimeout(timer.current); };
  }, [save]);

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

  const label = status.kind === 'saving' ? 'Saving…' : status.kind === 'editing' ? 'Editing…' : status.kind === 'error' ? 'Not saved, retrying…'
    : status.kind === 'conflict' ? 'Changed elsewhere, reload' : <>Saved<span className="hide-sm"> {fmt(status.at)}</span></>;

  return (
    <div className="doc">
      <header className="top sticky">
        <a className="back" href="?" onClick={(e) => { e.preventDefault(); save(); go({}); }}>←<span className="hide-sm"> All docs</span></a>
        <input className="brief-in" value={brief} placeholder="Brief #" onChange={(e) => { setBrief(e.target.value); meta.current.brief = e.target.value; schedule(); }} />
        <div className="grow" />
        <span className={'status ' + status.kind} onClick={() => status.kind === 'conflict' && location.reload()}>{label}</span>
        <button className="btn ghost icon" title="Undo (Ctrl+Z)" onClick={() => editor.undo()}>↶</button>
        <button className="btn ghost icon" title="Redo (Ctrl+Shift+Z)" onClick={() => editor.redo()}>↷</button>
        <button className="btn ghost" title="Add a preview under every link that doesn't have one yet" onClick={() => { const n = addPreviews(editor); if (!n) alert('Every link already has a preview.'); }}>Previews</button>
        <button className="btn ghost" onClick={() => setShowHist(true)}>History</button>
        <button className="btn ghost hide-sm" onClick={() => { navigator.clipboard.writeText(location.origin + location.pathname + '?doc=' + doc.id); }} title="Copy this doc's link (only signed-in editors can open it)">Copy link</button>
      </header>
      <main className="page">

        <input className="title-in" value={title} placeholder="Untitled" onChange={(e) => { setTitle(e.target.value); meta.current.title = e.target.value; schedule(); }} />
        <BlockNoteView editor={editor} theme="dark" onChange={schedule} slashMenu={false}>
          <SuggestionMenuController triggerCharacter="/" getItems={async (q) => filterSuggestionItems([...getDefaultReactSlashMenuItems(editor), {
            title: 'Link preview', subtext: 'Preview a Drive file/folder, YouTube, Instagram, TikTok or any link', aliases: ['embed', 'preview', 'drive', 'link'], group: 'Media',
            onItemClick: () => { const url = (prompt('Paste the link to preview:') || '').trim(); if (url) insertOrUpdateBlockForSlashMenu(editor, { type: 'linkPreview', props: { url } }); },
          }], q)} />
        </BlockNoteView>
        <p className="hint">Type <kbd>/</kbd> for blocks · <b>Previews</b> shows every link inside the doc · paste or drop images · drag the ⋮⋮ handle to move a block · select text to format</p>
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
