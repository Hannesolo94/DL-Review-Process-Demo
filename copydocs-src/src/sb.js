import { createClient } from '@supabase/supabase-js';

// Publishable key: safe in page source. RLS gives it nothing; only a signed-in editor
// (row in copy_doc_editors) can read or write copy docs or their images.
export const SB_URL = 'https://owxhmgqpcpkyiybsxipl.supabase.co';
export const SB_KEY = 'sb_publishable_h21XYNmQH0cXuGRp3yc1jQ_DjslVfPG';
export const BUCKET = 'copy-doc-images';

export const sb = createClient(SB_URL, SB_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: 'dl-copydocs-auth' },
});

// Images are stored in the block as sbimg://<path>; shown through short-lived signed URLs.
const signed = new Map();
export async function resolveFileUrl(url) {
  if (!url || !url.startsWith('sbimg://')) return url;
  const path = url.slice(8);
  const hit = signed.get(path);
  if (hit && hit.exp > Date.now()) return hit.url;
  const { data, error } = await sb.storage.from(BUCKET).createSignedUrl(path, 3600 * 6);
  if (error) throw error;
  signed.set(path, { url: data.signedUrl, exp: Date.now() + 3600 * 5 * 1000 });
  return data.signedUrl;
}

// Shrink big images before upload (keeps the free-tier storage small). GIFs go up as they are.
async function shrink(file) {
  if (!/^image\/(png|jpeg|webp)$/.test(file.type)) return file;
  const bmp = await createImageBitmap(file).catch(() => null);
  if (!bmp) return file;
  const max = 1800;
  if (bmp.width <= max && bmp.height <= max && file.size < 900 * 1024) return file;
  const k = Math.min(1, max / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas');
  c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
  c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
  const blob = await new Promise((r) => c.toBlob(r, 'image/webp', 0.85));
  return blob ? new File([blob], (file.name || 'image').replace(/\.\w+$/, '') + '.webp', { type: 'image/webp' }) : file;
}

export function makeUploader(docId) {
  return async (file) => {
    if (!file.type.startsWith('image/')) throw new Error('Only images can be uploaded');
    const f = await shrink(file);
    const ext = (f.type.split('/')[1] || 'png').replace('jpeg', 'jpg');
    const path = `${docId}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`;
    const { error } = await sb.storage.from(BUCKET).upload(path, f, { contentType: f.type, upsert: false });
    if (error) throw error;
    return 'sbimg://' + path;
  };
}
