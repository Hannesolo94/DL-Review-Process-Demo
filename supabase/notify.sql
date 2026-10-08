-- CRAFT review alerts to Slack (Oct 8 2026, Hannes).
-- Pings when someone opens a review link, leaves a note, sends an asset back,
-- suggests copy, or presses "I'm done reviewing". The Slack webhook URL lives in
-- Supabase Vault as 'craft_slack_webhook', never in the page source. With no
-- secret set, nothing is sent.

create extension if not exists pg_net;

-- who opened which link, once per person per brief per 30 minutes
create table if not exists public.review_events (
  id         bigserial primary key,
  brief_id   uuid not null references public.briefs(id) on delete cascade,
  kind       text not null default 'open',
  author     text,
  audience   text,
  created_at timestamptz not null default now()
);
alter table public.review_events enable row level security;

create or replace function public.log_open(p_token text, p_author text)
returns void language plpgsql security definer set search_path = public as $$
declare v_brief uuid; v_aud text; v_who text := coalesce(nullif(trim(p_author), ''), 'Someone');
begin
  select id, case when creator_token = p_token then 'internal' else 'client' end
    into v_brief, v_aud
  from public.briefs where creator_token = p_token or client_token = p_token;
  if v_brief is null then return; end if;
  if exists (select 1 from public.review_events
             where brief_id = v_brief and lower(author) = lower(v_who)
               and created_at > now() - interval '30 minutes') then return; end if;
  insert into public.review_events (brief_id, kind, author, audience) values (v_brief, 'open', v_who, v_aud);
end; $$;
revoke all on function public.log_open(text, text) from public, anon;
grant execute on function public.log_open(text, text) to anon;

-- send one Slack message
create or replace function public.craft_slack(p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare v_url text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'craft_slack_webhook' limit 1;
  if v_url is null or v_url = '' then return; end if;
  perform net.http_post(url := v_url,
                        body := jsonb_build_object('text', '<@U0757BQ1RFW> ' || p_text),   -- @Hannes so he gets the ping
                        headers := '{"Content-Type":"application/json"}'::jsonb);
end; $$;
revoke all on function public.craft_slack(text) from public, anon, authenticated;

create or replace function public.craft_brief_label(b public.briefs)
returns text language sql immutable as $$
  select '<https://hannesolo94.github.io/DL-Review-Process-Demo/?b=' || b.creator_token || '|'
         || coalesce(nullif(b.title, ''), b.slug) || '>';
$$;

create or replace function public.craft_asset_title(b public.briefs, p_asset text)
returns text language sql immutable as $$
  select regexp_replace(coalesce((select a->>'title' from jsonb_array_elements(b.data->'assets') a where a->>'id' = p_asset), p_asset),
                        '\s*\((revised|new)[^)]*\)\s*$', '');
$$;

-- notes: new note, asset sent back, copy suggestion, done
create or replace function public.craft_notify_note()
returns trigger language plpgsql security definer set search_path = public as $$
declare b public.briefs; who text; tag text; msg text; n_ok int; n_ch int; n_notes int;
begin
  select * into b from public.briefs where id = new.brief_id;
  if b.id is null then return new; end if;
  who := coalesce(new.author, 'Someone');
  if craft_is_muted(who) then return new; end if;               -- mute list (Hannes never gets pinged about himself)
  tag := case when new.audience = 'client' then ' (client)' else '' end;

  if new.kind = 'done' and tg_op = 'INSERT' then
    select count(*) filter (where state = 'approved'), count(*) filter (where state = 'changes')
      into n_ok, n_ch
    from public.notes where brief_id = new.brief_id and kind = 'verdict' and round = new.round
                        and lower(author) = lower(new.author);
    select count(*) into n_notes from public.notes
    where brief_id = new.brief_id and kind = 'note' and round = new.round and lower(author) = lower(new.author);
    msg := ':white_check_mark: *' || who || '*' || tag || ' finished reviewing ' || craft_brief_label(b)
           || ': ' || n_ok || ' approved, ' || n_ch || case when n_ch = 1 then ' needs' else ' need' end || ' changes, '
           || n_notes || case when n_notes = 1 then ' note' else ' notes' end;

  elsif new.kind = 'verdict' and new.state = 'changes'
        and (tg_op = 'INSERT' or old.state is distinct from new.state) then
    msg := ':warning: *' || who || '*' || tag || ' sent back *' || craft_asset_title(b, new.asset_id)
           || '* on ' || craft_brief_label(b);

  elsif new.kind = 'note' and tg_op = 'INSERT' and new.asset_id = 'copy' then
    msg := ':pencil2: *' || who || '*' || tag || ' suggested new ad copy on ' || craft_brief_label(b);

  elsif new.kind = 'note' and tg_op = 'INSERT' and coalesce(new.body, '') <> '' then
    msg := ':speech_balloon: *' || who || '*' || tag || ' on ' || craft_brief_label(b) || ', *'
           || case when new.asset_id = 'general' then 'general comment' else craft_asset_title(b, new.asset_id) end || '*'
           || case when new.t is not null then ' at ' || floor(new.t / 60)::int || ':' || lpad((floor(new.t)::int % 60)::text, 2, '0') else '' end
           || ': "' || left(new.body, 400) || '"';
  end if;

  if msg is not null then perform craft_slack(msg); end if;
  return new;
end; $$;

drop trigger if exists craft_notify_note on public.notes;
create trigger craft_notify_note after insert or update on public.notes
  for each row execute function public.craft_notify_note();

-- opens
create or replace function public.craft_notify_open()
returns trigger language plpgsql security definer set search_path = public as $$
declare b public.briefs;
begin
  select * into b from public.briefs where id = new.brief_id;
  if b.id is null or craft_is_muted(new.author) then return new; end if;
  perform craft_slack(':eyes: *' || coalesce(new.author, 'Someone') || '*'
                      || case when new.audience = 'client' then ' (client)' else '' end
                      || ' opened ' || craft_brief_label(b));
  return new;
end; $$;

drop trigger if exists craft_notify_open on public.review_events;
create trigger craft_notify_open after insert on public.review_events
  for each row execute function public.craft_notify_open();

-- Oct 8: mute list. Reviewer names matching a pattern here never ping (Hannes, and anyone added later).
create table if not exists public.craft_alert_mutes (pattern text primary key, note text);
alter table public.craft_alert_mutes enable row level security;
insert into public.craft_alert_mutes (pattern, note) values ('hannes%', 'Hannes, his own reviews and his agent''s notes')
  on conflict do nothing;

create or replace function public.craft_is_muted(p_author text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.craft_alert_mutes m where lower(trim(coalesce(p_author, ''))) like m.pattern);
$$;
