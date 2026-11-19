-- COPY DOCS read-only share links (Nov 19 2026 22:25, for David's review). Per-doc random token with an expiry,
-- served only through this security-definer RPC (read-only). Revoke = set share_token null.
alter table public.copy_docs add column if not exists share_expires timestamptz;
create unique index if not exists copy_docs_share_token_idx on public.copy_docs (share_token) where share_token is not null;
create or replace function public.copy_doc_shared(p_token text) returns jsonb
language sql security definer stable set search_path = public as $fn$
  select jsonb_build_object('title', d.title, 'brief_number', d.brief_number, 'content', d.content, 'updated_at', d.updated_at,
    'meta', coalesce((select jsonb_object_agg(m.url, jsonb_build_object('url', m.url, 'title', m.title, 'description', m.description,
                      'image', m.image, 'site', m.site, 'status', m.status))
                      from public.copy_link_meta m where strpos(d.content::text, m.url) > 0), '{}'::jsonb))
  from public.copy_docs d
  where p_token is not null and length(p_token) >= 32 and d.share_token = p_token and not d.archived
    and (d.share_expires is null or d.share_expires > now())
$fn$;
revoke all on function public.copy_doc_shared(text) from public;
grant execute on function public.copy_doc_shared(text) to anon, authenticated;

-- copy_docs_touch was updated in place (see copy_docs.sql) so a share-only change keeps updated_at:
CREATE OR REPLACE FUNCTION public.copy_docs_touch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare last_at timestamptz;
begin
  -- Nov 19: a change to only the share link (share_token/share_expires) is not an edit: keep updated_at/updated_by,
  -- or an open editor tab would see it as someone else's change.
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'share_token' - 'share_expires' - 'updated_at' - 'updated_by')
       = (to_jsonb(old) - 'share_token' - 'share_expires' - 'updated_at' - 'updated_by') then
    new.updated_at := old.updated_at; new.updated_by := old.updated_by; return new;
  end if;
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
end $function$
;
