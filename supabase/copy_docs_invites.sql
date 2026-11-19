-- COPY DOCS personal invite links (Nov 19 2026, overnight fix after David's sign-in links failed).
-- Why: Supabase one-time links work once and each new one cancels the last. David's second link was opened in Hannes's
-- own browser first (22:38:56), so David got "already used". The dashboard (redirect URLs, SMTP) is Hannes-only.
-- What: a personal invite per editor (?invite=<32 chars>), tied to one email, 30 days, revocable, usable up to 20 times.
-- Each time it's opened, copy_doc_redeem_invite() mints a FRESH one-time Supabase token for that email (same format
-- GoTrue uses: sha224(email || otp) in auth.users.recovery_token + auth.one_time_tokens) and the page signs in with it.
-- Only the sha256 of the invite token is stored. Anon can't read the table; it can only call the two RPCs below.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.copy_doc_invites (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  email text not null,
  token_sha256 text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  revoked_at timestamptz,
  uses int not null default 0,
  max_uses int not null default 20,
  last_used_at timestamptz,
  created_by text,
  note text
);
alter table public.copy_doc_invites enable row level security;   -- no policies: service role / RPCs only
revoke all on public.copy_doc_invites from anon, authenticated;

create table if not exists public.copy_doc_link_requests (
  id bigint generated always as identity primary key,
  email text not null,
  created_at timestamptz not null default now(),
  handled_at timestamptz
);
alter table public.copy_doc_link_requests enable row level security;
revoke all on public.copy_doc_link_requests from anon, authenticated;

-- whose invite is this? (so a browser already signed in as someone else doesn't silently switch accounts)
create or replace function public.copy_doc_invite_email(p_token text) returns text
language sql stable security definer set search_path = public, extensions as $$
  select i.email from public.copy_doc_invites i
  where length(coalesce(p_token, '')) >= 32 and i.token_sha256 = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and i.revoked_at is null and i.expires_at > now() and i.uses < i.max_uses
    and exists (select 1 from public.copy_doc_editors e where e.user_id = i.user_id);
$$;

create or replace function public.copy_doc_redeem_invite(p_token text) returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare inv public.copy_doc_invites; otp text; h text;
begin
  if length(coalesce(p_token, '')) < 32 then return null; end if;
  select * into inv from public.copy_doc_invites i
   where i.token_sha256 = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and i.revoked_at is null and i.expires_at > now() and i.uses < i.max_uses
   for update;
  if not found then return null; end if;
  if not exists (select 1 from public.copy_doc_editors e where e.user_id = inv.user_id) then return null; end if;
  otp := encode(extensions.gen_random_bytes(16), 'hex');
  h := encode(extensions.digest(inv.email || otp, 'sha224'), 'hex');
  update auth.users set recovery_token = h, recovery_sent_at = now() where id = inv.user_id;
  delete from auth.one_time_tokens where user_id = inv.user_id and token_type = 'recovery_token';
  insert into auth.one_time_tokens (id, user_id, token_type, token_hash, relates_to, created_at, updated_at)
  values (gen_random_uuid(), inv.user_id, 'recovery_token', h, inv.email, now(), now());
  update public.copy_doc_invites set uses = uses + 1, last_used_at = now() where id = inv.id;
  return h;
end $$;

-- "Send me a sign-in link": records a request for Hannes's hub (never sends anything). Same answer either way.
create or replace function public.copy_doc_request_link(p_email text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email, '')));
begin
  if e = '' or length(e) > 200 then return true; end if;
  if exists (select 1 from public.copy_doc_editors where lower(email) = e)
     and not exists (select 1 from public.copy_doc_link_requests where email = e and created_at > now() - interval '10 minutes') then
    insert into public.copy_doc_link_requests (email) values (e);
  end if;
  return true;
end $$;

revoke all on function public.copy_doc_invite_email(text) from public;
revoke all on function public.copy_doc_redeem_invite(text) from public;
revoke all on function public.copy_doc_request_link(text) from public;
grant execute on function public.copy_doc_invite_email(text) to anon, authenticated;
grant execute on function public.copy_doc_redeem_invite(text) to anon, authenticated;
grant execute on function public.copy_doc_request_link(text) to anon, authenticated;
