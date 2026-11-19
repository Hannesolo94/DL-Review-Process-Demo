// COPY DOCS v1.1 (Nov 19 2026): link previews inside the doc.
// Drive files/folders, YouTube, Instagram and TikTok embed in place (loaded with the viewer's own sign-in,
// nothing is copied anywhere). Everything else is a link card; its title/thumbnail come from copy_link_meta,
// which the hub fills on the laptop (server-side OG fetch). Previews only load when scrolled near.
import React, { useEffect, useRef, useState } from 'react';
import { createReactBlockSpec } from '@blocknote/react';
import { sb } from './sb.js';

export function classify(raw) {
  let u; try { u = new URL(raw); } catch (_) { return null; }
  const h = u.hostname.replace(/^www\./, ''), p = u.pathname;
  let m;
  if (/(^|\.)drive\.google\.com$|^docs\.google\.com$|^drive\.usercontent\.google\.com$/.test(h)) {
    if ((m = p.match(/\/(?:drive\/(?:u\/\d+\/)?)?folders\/([\w-]{10,})/))) return { kind: 'drivefolder', id: m[1], label: 'Drive folder' };
    if ((m = p.match(/\/file\/d\/([\w-]{10,})/))) return { kind: 'drive', id: m[1], label: 'Drive file' };
    if ((m = p.match(/\/(document|spreadsheets|presentation)\/d\/([\w-]{10,})/))) return { kind: 'gdoc', id: m[2], doc: m[1], label: 'Google ' + ({ document: 'Doc', spreadsheets: 'Sheet', presentation: 'Slides' })[m[1]] };
    const id = u.searchParams.get('id'); if (id && /^[\w-]{10,}$/.test(id)) return { kind: 'drive', id, label: 'Drive file' };
    return { kind: 'card', label: 'Google Drive' };
  }
  if (h === 'youtu.be' && (m = p.match(/^\/([\w-]{6,})/))) return { kind: 'youtube', id: m[1], label: 'YouTube' };
  if (/youtube\.com$/.test(h)) {
    const v = u.searchParams.get('v') || ((m = p.match(/\/(?:shorts|embed|live)\/([\w-]{6,})/)) && m[1]);
    if (v) return { kind: 'youtube', id: v, short: p.startsWith('/shorts'), label: 'YouTube' };
  }
  if (/instagram\.com$/.test(h) && (m = p.match(/\/(p|reel|reels|tv)\/([\w-]+)/))) return { kind: 'instagram', id: m[2], t: m[1] === 'reels' ? 'reel' : m[1], label: 'Instagram' };
  if (/tiktok\.com$/.test(h) && (m = p.match(/\/video\/(\d+)/))) return { kind: 'tiktok', id: m[1], label: 'TikTok' };
  if (/facebook\.com$/.test(h) && p.startsWith('/ads/library')) return { kind: 'card', label: 'Meta Ad Library', noembed: 'Meta does not allow the Ad Library to be embedded' };
  if (h === 'fb.me' || /facebook\.com$|fb\.watch$/.test(h)) return { kind: 'card', label: 'Facebook', noembed: 'Facebook pages need its own player' };
  if (/atria/.test(h)) return { kind: 'card', label: 'Atria', noembed: 'Atria needs its own login' };
  return { kind: 'card', label: h };
}

const SKIP = /^https?:\/\/([\w-]+\.)?notion\.(so|com|site)\//;   // the Notion original needs Notion's own login
export const PREVIEWABLE = (url) => /^https?:\/\//.test(url || '');

function useNear(ref) {
  const [near, setNear] = useState(false);
  useEffect(() => {
    if (near || !ref.current) return;
    const io = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) { setNear(true); io.disconnect(); } }, { rootMargin: '600px' });
    io.observe(ref.current); return () => io.disconnect();
  }, [near]);
  return near;
}

// link card metadata, batched
const metaCache = new Map(); let metaQ = new Set(), metaT = null; const metaSubs = new Set();
function wantMeta(url) {
  if (metaCache.has(url)) return;
  metaCache.set(url, null); metaQ.add(url);
  clearTimeout(metaT); metaT = setTimeout(flushMeta, 150);
}
let SHARED = false;   // read-only share view: link data comes with the doc, never read or written here
export function primeMeta(m) { SHARED = true; Object.entries(m || {}).forEach(([u, r]) => metaCache.set(u, r)); }
async function flushMeta() {
  const urls = [...metaQ]; metaQ = new Set(); if (!urls.length || SHARED) return;
  const { data } = await sb.from('copy_link_meta').select('*').in('url', urls);
  const got = new Set((data || []).map((r) => r.url));
  (data || []).forEach((r) => metaCache.set(r.url, r));
  const missing = urls.filter((u) => !got.has(u));
  if (missing.length) await sb.from('copy_link_meta').insert(missing.map((url) => ({ url, status: 'pending' })));
  metaSubs.forEach((f) => f());
}
function useMeta(url, on) {
  const [, force] = useState(0);
  useEffect(() => { if (!on) return; const f = () => force((x) => x + 1); metaSubs.add(f); wantMeta(url); return () => metaSubs.delete(f); }, [url, on]);
  return metaCache.get(url) || null;
}

// Drive picks the browser's first Google account unless told which; use the doc editor's own sign-in email (runtime only).
let AU = '';
sb.auth.getSession().then(({ data }) => { AU = (data.session && data.session.user.email) || ''; });
const au = (sep) => (AU ? `${sep}authuser=${encodeURIComponent(AU)}` : '');

function Embed({ c, url }) {
  if (c.kind === 'drive') return <iframe className="pv-frame tall" src={`https://drive.google.com/file/d/${c.id}/preview${au('?')}`} allow="autoplay; fullscreen" allowFullScreen loading="lazy" title="Drive preview" />;
  if (c.kind === 'gdoc') return <iframe className="pv-frame" src={`https://docs.google.com/${c.doc}/d/${c.id}/preview${au('?')}`} loading="lazy" title="Google preview" />;
  if (c.kind === 'drivefolder') return <Folder c={c} url={url} />;
  if (c.kind === 'youtube') return <iframe className={'pv-frame ' + (c.short ? 'tall' : 'wide')} src={`https://www.youtube-nocookie.com/embed/${c.id}`} referrerPolicy="strict-origin-when-cross-origin" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowFullScreen loading="lazy" title="YouTube" />;
  if (c.kind === 'instagram') return <iframe className="pv-frame tall" src={`https://www.instagram.com/${c.t}/${c.id}/embed/`} referrerPolicy="strict-origin-when-cross-origin" loading="lazy" title="Instagram" />;
  if (c.kind === 'tiktok') return <iframe className="pv-frame tall" src={`https://www.tiktok.com/embed/v2/${c.id}`} referrerPolicy="strict-origin-when-cross-origin" allow="fullscreen" loading="lazy" title="TikTok" />;
  return null;
}

// Drive folders: the hub counts the files from Drive for desktop. Empty -> a dark note, files -> the grid,
// unknown -> a dark card with Show files (Drive's own folder frame is white, so it only opens on request).
function Folder({ c, url }) {
  const m = useMeta(url, true); const [open, setOpen] = useState(false);
  const n = m && m.site === 'drive-folder' && m.description ? parseInt(m.description, 10) : NaN;
  const openUrl = `https://drive.google.com/drive/folders/${c.id}${au('?')}`;
  if (n > 0 || open) return <iframe className="pv-frame folder" src={`https://drive.google.com/embeddedfolderview?id=${c.id}${au('&')}#grid`} loading="lazy" title="Drive folder" />;
  return (
    <div className="pv-folder" contentEditable={false}>
      <span className="pv-ficon">📁</span>
      <div className="pv-ct"><b>{(m && m.title) || 'Drive folder'}</b>
        <span className="pv-host">{n === 0 ? 'Folder is empty for now' : 'File count not known yet'}</span></div>
      <span className="grow" />
      {n === 0 ? null : <button className="pv-btn" onClick={() => setOpen(true)}>Show files</button>}
      <a className="pv-btn" href={openUrl} target="_blank" rel="noopener noreferrer">Open in Drive ↗</a>
    </div>
  );
}

function Card({ c, url, on }) {
  const m = useMeta(url, on);
  const host = (() => { try { return new URL(url).hostname.replace(/^www\./, ''); } catch (_) { return url; } })();
  return (
    <a className="pv-card" href={url} target="_blank" rel="noopener noreferrer" contentEditable={false}>
      {m && m.image ? <img src={m.image} alt="" loading="lazy" referrerPolicy="no-referrer" onError={(e) => { e.currentTarget.style.display = 'none'; }} /> : <div className="pv-ph">{(c.label || host).slice(0, 1).toUpperCase()}</div>}
      <div className="pv-ct">
        <b>{(m && m.title) || c.label || host}</b>
        {m && m.description ? <span className="pv-desc">{m.description}</span> : null}
        <span className="pv-host">{host}{c.noembed ? ' · ' + c.noembed : ''}{!m || m.status === 'pending' ? ' · preview pending' : m.status === 'failed' ? ' · no preview from this site' : ''}</span>
      </div>
    </a>
  );
}

function View({ block, editor }) {
  const { url, mode, title } = block.props;
  const ref = useRef(null); const near = useNear(ref);
  const c = classify(url) || { kind: 'card', label: url };
  const isEmbed = c.kind !== 'card';
  const set = (props) => editor.updateBlock(block, { props });
  const openUrl = c.kind === 'drive' ? `https://drive.google.com/file/d/${c.id}/view${au('?')}` : c.kind === 'drivefolder' ? `https://drive.google.com/drive/folders/${c.id}${au('?')}` : url;
  return (
    <div className={'pv ' + mode} ref={ref} contentEditable={false}>
      <div className="pv-head">
        <span className="pv-tag">{c.label}</span>
        <a className="pv-title" href={openUrl} target="_blank" rel="noopener noreferrer">{title || url}</a>
        <span className="grow" />
        <button className="pv-btn" onClick={() => set({ mode: mode === 'link' ? 'preview' : 'link' })} title="Switch between preview and plain link">{mode === 'link' ? 'Show preview' : 'Plain link'}</button>
        <a className="pv-btn" href={openUrl} target="_blank" rel="noopener noreferrer">{c.kind.startsWith('drive') ? 'Open in Drive ↗' : 'Open ↗'}</a>
      </div>
      {mode !== 'link' && (near ? (isEmbed ? <Embed c={c} url={url} /> : <Card c={c} url={url} on={near} />) : <div className="pv-wait">Preview loads when you scroll here</div>)}
    </div>
  );
}

export const LinkPreview = createReactBlockSpec(
  { type: 'linkPreview', propSchema: { url: { default: '' }, title: { default: '' }, mode: { default: 'preview' } }, content: 'none' },
  { render: (props) => <View {...props} /> },
);

// Every link in the doc that has no preview block yet gets one, right after the block holding it.
export function linksIn(block) {
  const out = [];
  const walk = (ic) => (Array.isArray(ic) ? ic : []).forEach((n) => {
    if (n.type === 'link' && PREVIEWABLE(n.href)) out.push({ url: n.href, text: (n.content || []).map((t) => t.text || '').join('') });
    else if (n.type === 'text') (n.text.match(/https?:\/\/[^\s)<>"]+/g) || []).forEach((u) => out.push({ url: u, text: '' }));
  });
  if (Array.isArray(block.content)) walk(block.content);
  else if (block.content && block.content.type === 'tableContent') block.content.rows.forEach((r) => r.cells.forEach((cell) => walk(Array.isArray(cell) ? cell : cell.content)));
  return out;
}
// Every block holding links gets a preview for each of them directly under it; a link used in two places gets one
// in both (Nov 19 09:35). Previews already right after the block count; nothing is removed.
export function addPreviews(editor, { only } = {}) {
  const jobs = [];
  const walk = (bs) => {
    for (let i = 0; i < bs.length; i++) {
      const b = bs[i]; walk(b.children || []);
      if (b.type === 'linkPreview') continue;
      const attached = new Set(); let last = b, j = i + 1;
      while (j < bs.length && bs[j].type === 'linkPreview') { attached.add(bs[j].props.url); last = bs[j]; j++; }
      const ls = []; for (const l of linksIn(b)) { if (attached.has(l.url) || SKIP.test(l.url) || (only && !only(l.url))) continue; attached.add(l.url); ls.push(l); }
      if (ls.length) jobs.push({ after: last, ls });
    }
  };
  walk(editor.document);
  let n = 0;
  editor.transact(() => {
    for (const { after, ls } of jobs) {
      editor.insertBlocks(ls.map((l) => ({ type: 'linkPreview', props: { url: l.url, title: l.text && l.text !== l.url ? l.text : '', mode: 'preview' } })), after, 'after');
      n += ls.length;
    }
  });
  return n;
}
