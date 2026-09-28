-- Review canvas schema.
--
-- Access model: the review link IS the credential. Each brief has an unguessable
-- token. The tables themselves are NOT readable by the anon/publishable key at all
-- (RLS on, zero policies), so holding the key gets you nothing on its own. Every
-- read and write goes through a security-definer function that demands the token,
-- which means a link opens exactly one brief and cannot be used to enumerate others.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- briefs

create table if not exists public.briefs (
  id         uuid primary key default gen_random_uuid(),
  token      text unique not null,            -- what lives in the review URL
  slug       text not null,                   -- PLT0160
  brand      text not null,                   -- PLT
  title      text not null,
  round      int  not null default 1,
  data       jsonb not null,                  -- assets, meta copy, landing pages, strategy
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists briefs_slug on public.briefs(slug);

-- ---------------------------------------------------------------- notes

create table if not exists public.notes (
  id         text primary key,                -- client-generated so a verdict upserts
  brief_id   uuid not null references public.briefs(id) on delete cascade,
  round      int  not null default 1,
  kind       text not null default 'note',    -- note | verdict | copy | lp
  asset_id   text,
  x real, y real, t real,                     -- pin position, or video timestamp
  author     text not null,
  body       text default '',
  img        text,                            -- small inline reference image
  link       text,
  urls       jsonb,                           -- proposed landing pages
  headlines  jsonb,
  primaries  jsonb,
  state      text,                            -- approved | changes
  created_at timestamptz not null default now()
);

create index if not exists notes_brief_round on public.notes(brief_id, round);

-- ---------------------------------------------------------------- lock the doors

alter table public.briefs enable row level security;
alter table public.notes  enable row level security;
-- deliberately no policies: nothing reaches these tables without a token

-- ---------------------------------------------------------------- the only way in

create or replace function public.get_brief(p_token text)
returns jsonb language sql security definer set search_path = public stable as $$
  select jsonb_build_object(
    'slug', b.slug, 'brand', b.brand, 'title', b.title,
    'round', b.round, 'data', b.data
  )
  from public.briefs b
  where b.token = p_token;
$$;

create or replace function public.get_notes(p_token text)
returns table (
  id text, round int, kind text, asset_id text,
  x real, y real, t real, author text, body text,
  img text, link text, urls jsonb, headlines jsonb, primaries jsonb,
  state text, created_at timestamptz
) language sql security definer set search_path = public stable as $$
  select n.id, n.round, n.kind, n.asset_id, n.x, n.y, n.t, n.author, n.body,
         n.img, n.link, n.urls, n.headlines, n.primaries, n.state, n.created_at
  from public.notes n
  join public.briefs b on b.id = n.brief_id
  where b.token = p_token
  order by n.created_at;
$$;

create or replace function public.put_note(p_token text, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_brief uuid;
begin
  select id into v_brief from public.briefs where token = p_token;
  if v_brief is null then raise exception 'unknown review link'; end if;

  insert into public.notes (
    id, brief_id, round, kind, asset_id, x, y, t,
    author, body, img, link, urls, headlines, primaries, state
  ) values (
    p->>'id', v_brief, coalesce((p->>'round')::int, 1), coalesce(p->>'kind', 'note'),
    p->>'assetId', (p->>'x')::real, (p->>'y')::real, (p->>'t')::real,
    coalesce(p->>'author', 'Someone'), coalesce(p->>'text', ''),
    p->>'img', p->>'link', p->'urls', p->'headlines', p->'primaries', p->>'state'
  )
  on conflict (id) do update set
    body = excluded.body, img = excluded.img, link = excluded.link,
    urls = excluded.urls, headlines = excluded.headlines,
    primaries = excluded.primaries, state = excluded.state,
    author = excluded.author;
end; $$;

create or replace function public.del_note(p_token text, p_id text)
returns void language plpgsql security definer set search_path = public as $$
declare v_brief uuid;
begin
  select id into v_brief from public.briefs where token = p_token;
  if v_brief is null then raise exception 'unknown review link'; end if;
  delete from public.notes where id = p_id and brief_id = v_brief;
end; $$;

-- the publishable key may call these four and nothing else
revoke all on function public.get_brief(text)        from public, anon;
revoke all on function public.get_notes(text)        from public, anon;
revoke all on function public.put_note(text, jsonb)  from public, anon;
revoke all on function public.del_note(text, text)   from public, anon;

grant execute on function public.get_brief(text)       to anon;
grant execute on function public.get_notes(text)       to anon;
grant execute on function public.put_note(text, jsonb) to anon;
grant execute on function public.del_note(text, text)  to anon;

-- ---------------------------------------------------------------- media

-- Private bucket. Creative is served through signed URLs the generator mints,
-- never from a public path, so nothing is reachable by guessing a filename.
insert into storage.buckets (id, name, public)
values ('creative', 'creative', false)
on conflict (id) do nothing;
