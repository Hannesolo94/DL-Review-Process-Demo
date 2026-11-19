-- COPY DOCS (Nov 19 2026). DL Media's own copy docs: one editable block page per brief.
-- Access: Supabase Auth + an editor allowlist. RLS on every table; no anon access at all.
-- Read-only share mode exists as a column (share_token) but is OFF: no policy or function reads it yet.

create table if not exists public.copy_doc_editors (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  added_at timestamptz not null default now()
);
alter table public.copy_doc_editors enable row level security;
-- no policies: only the service role / SQL can change who edits.

create or replace function public.is_copy_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.copy_doc_editors where user_id = auth.uid());
$$;
revoke all on function public.is_copy_editor() from public, anon;
grant execute on function public.is_copy_editor() to authenticated;

create table if not exists public.copy_docs (
  id uuid primary key default gen_random_uuid(),
  brief_number text,                       -- e.g. PLT0213
  brand text,                              -- e.g. PLT
  title text not null default 'Untitled copy doc',
  content jsonb not null default '[]'::jsonb,   -- BlockNote document (array of blocks)
  source text,                             -- e.g. 'notion-import:<page id>' (read-only import, never written back)
  share_token text,                        -- for a later read-only share mode; unused, off by default
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text
);
create index if not exists copy_docs_brief_idx on public.copy_docs (brief_number);
alter table public.copy_docs enable row level security;

create table if not exists public.copy_doc_versions (
  id bigserial primary key,
  doc_id uuid not null references public.copy_docs(id) on delete cascade,
  title text,
  content jsonb not null,
  label text,                              -- 'auto', 'manual', 'before restore', 'import'
  created_at timestamptz not null default now(),
  created_by text
);
create index if not exists copy_doc_versions_doc_idx on public.copy_doc_versions (doc_id, created_at desc);
alter table public.copy_doc_versions enable row level security;

drop policy if exists cd_all on public.copy_docs;
create policy cd_all on public.copy_docs for all to authenticated
  using (public.is_copy_editor()) with check (public.is_copy_editor());
drop policy if exists cdv_all on public.copy_doc_versions;
create policy cdv_all on public.copy_doc_versions for all to authenticated
  using (public.is_copy_editor()) with check (public.is_copy_editor());

revoke all on public.copy_docs, public.copy_doc_versions, public.copy_doc_editors from anon;
grant select, insert, update, delete on public.copy_docs, public.copy_doc_versions to authenticated;
grant usage, select on sequence public.copy_doc_versions_id_seq to authenticated;

-- stamp updated_at / updated_by, and keep an automatic version at most every 10 minutes of editing
create or replace function public.copy_docs_touch() returns trigger
language plpgsql security definer set search_path = public as $$
declare last_at timestamptz;
begin
  new.updated_at := now();
  new.updated_by := coalesce(auth.jwt()->>'email', new.updated_by);
  if tg_op = 'UPDATE' and (new.content is distinct from old.content or new.title is distinct from old.title) then
    select max(created_at) into last_at from public.copy_doc_versions where doc_id = new.id;
    if last_at is null or last_at < now() - interval '10 minutes' then
      insert into public.copy_doc_versions (doc_id, title, content, label, created_by)
      values (old.id, old.title, old.content, 'auto', new.updated_by);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists copy_docs_touch on public.copy_docs;
create trigger copy_docs_touch before insert or update on public.copy_docs
  for each row execute function public.copy_docs_touch();

-- images: private bucket, editors only. 5 MB cap; the page shrinks pastes before upload.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('copy-doc-images', 'copy-doc-images', false, 5242880,
        array['image/png','image/jpeg','image/webp','image/gif'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists cdi_select on storage.objects;
drop policy if exists cdi_insert on storage.objects;
drop policy if exists cdi_update on storage.objects;
drop policy if exists cdi_delete on storage.objects;
create policy cdi_select on storage.objects for select to authenticated
  using (bucket_id = 'copy-doc-images' and public.is_copy_editor());
create policy cdi_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'copy-doc-images' and public.is_copy_editor());
create policy cdi_update on storage.objects for update to authenticated
  using (bucket_id = 'copy-doc-images' and public.is_copy_editor());
create policy cdi_delete on storage.objects for delete to authenticated
  using (bucket_id = 'copy-doc-images' and public.is_copy_editor());
