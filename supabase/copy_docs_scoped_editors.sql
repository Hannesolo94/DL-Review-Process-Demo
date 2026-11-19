-- COPY DOCS per-doc editors (Nov 19 2026 22:30, Hannes: David may edit the ODDS docs).
-- copy_doc_editors.doc_ids: null = every doc (Hannes); a list = only those docs (David).
alter table public.copy_doc_editors add column if not exists doc_ids uuid[];

-- any editor row (page gate + link previews)
create or replace function public.is_copy_editor() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.copy_doc_editors where user_id = auth.uid());
$$;
-- full editor (all docs, new docs, image bucket)
create or replace function public.is_copy_full_editor() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.copy_doc_editors where user_id = auth.uid() and doc_ids is null);
$$;
create or replace function public.can_edit_copy_doc(p_doc uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.copy_doc_editors where user_id = auth.uid() and (doc_ids is null or p_doc = any (doc_ids)));
$$;
revoke all on function public.is_copy_full_editor() from public;
revoke all on function public.can_edit_copy_doc(uuid) from public;
grant execute on function public.is_copy_full_editor() to authenticated;
grant execute on function public.can_edit_copy_doc(uuid) to authenticated;

drop policy if exists cd_all on public.copy_docs;
create policy cd_all on public.copy_docs for all to authenticated using (public.can_edit_copy_doc(id)) with check (public.can_edit_copy_doc(id));
drop policy if exists cdv_all on public.copy_doc_versions;
create policy cdv_all on public.copy_doc_versions for all to authenticated using (public.can_edit_copy_doc(doc_id)) with check (public.can_edit_copy_doc(doc_id));

drop policy if exists cdi_select on storage.objects;
drop policy if exists cdi_insert on storage.objects;
drop policy if exists cdi_update on storage.objects;
drop policy if exists cdi_delete on storage.objects;
create policy cdi_select on storage.objects for select to authenticated using (bucket_id = 'copy-doc-images' and public.is_copy_full_editor());
create policy cdi_insert on storage.objects for insert to authenticated with check (bucket_id = 'copy-doc-images' and public.is_copy_full_editor());
create policy cdi_update on storage.objects for update to authenticated using (bucket_id = 'copy-doc-images' and public.is_copy_full_editor());
create policy cdi_delete on storage.objects for delete to authenticated using (bucket_id = 'copy-doc-images' and public.is_copy_full_editor());
