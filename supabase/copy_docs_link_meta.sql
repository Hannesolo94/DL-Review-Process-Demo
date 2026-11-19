-- COPY DOCS v1.1 (Nov 19 2026): link card metadata (title/thumbnail of non-embeddable links).
-- The page asks for a URL by inserting a row with status 'pending'; the hub on the laptop fetches the
-- page's OG tags server-side and fills the row (service key). No media is stored, only text + remote image URL.
create table if not exists public.copy_link_meta (
  url text primary key,
  title text, description text, image text, site text,
  status text not null default 'pending',   -- pending | ok | failed
  fetched_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.copy_link_meta enable row level security;
drop policy if exists clm_sel on public.copy_link_meta;
drop policy if exists clm_ins on public.copy_link_meta;
create policy clm_sel on public.copy_link_meta for select to authenticated using (public.is_copy_editor());
create policy clm_ins on public.copy_link_meta for insert to authenticated with check (public.is_copy_editor() and status = 'pending');
revoke all on public.copy_link_meta from anon;
grant select, insert on public.copy_link_meta to authenticated;
