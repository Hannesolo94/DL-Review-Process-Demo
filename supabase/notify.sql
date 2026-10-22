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

-- notes: Oct 8 Hannes wants two pings only, 'opened' and 'done' (done lists the notes). The other branches are switched off with `false`.
create or replace function public.craft_notify_note()
returns trigger language plpgsql security definer set search_path = public as $$
declare b public.briefs; who text; tag text; msg text; n_ok int; n_ch int; n_notes int;
begin
  select * into b from public.briefs where id = new.brief_id;
  if b.id is null or b.brand = 'FG' then return new; end if;    -- Oct 22: FORGE boards post to #forge-notifications instead
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
           || n_notes || case when n_notes = 1 then ' note' else ' notes' end;   -- Oct 14: one line only, no notes list (Hannes)

  elsif false and new.kind = 'verdict' and new.state = 'changes'
        and (tg_op = 'INSERT' or old.state is distinct from new.state) then
    msg := ':warning: *' || who || '*' || tag || ' sent back *' || craft_asset_title(b, new.asset_id)
           || '* on ' || craft_brief_label(b);

  elsif false and new.kind = 'note' and tg_op = 'INSERT' and new.asset_id = 'copy' then
    msg := ':pencil2: *' || who || '*' || tag || ' suggested new ad copy on ' || craft_brief_label(b);

  elsif false and new.kind = 'note' and tg_op = 'INSERT' and coalesce(new.body, '') <> '' then
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

-- opens: Oct 14 Hannes turned these off (#craft-notifications = finished reviewing only). Trigger dropped, function kept.
create or replace function public.craft_notify_open()
returns trigger language plpgsql security definer set search_path = public as $$
declare b public.briefs;
begin
  select * into b from public.briefs where id = new.brief_id;
  if b.id is null or craft_is_muted(new.author) then return new; end if;
  perform craft_slack(':eyes: *' || coalesce(new.author, 'Someone') || '*'
                      || case when new.audience = 'client' then ' (client)' else '' end
                      || ' opened ' || craft_brief_label(b) || ' and started reviewing');
  return new;
end; $$;

drop trigger if exists craft_notify_open on public.review_events;

-- Oct 8: mute list. Reviewer names matching a pattern here never ping (Hannes, and anyone added later).
create table if not exists public.craft_alert_mutes (pattern text primary key, note text);
alter table public.craft_alert_mutes enable row level security;
insert into public.craft_alert_mutes (pattern, note) values ('hannes%', 'Hannes, his own reviews and his agent''s notes')
  on conflict do nothing;

create or replace function public.craft_is_muted(p_author text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.craft_alert_mutes m where lower(trim(coalesce(p_author, ''))) like m.pattern);
$$;

-- Oct 14 2026: per-brand review channels (#atp/#ctf/#plt/#tl/#gu/#otx-review-notifications, Hannes + Dillon + David).
-- Webhooks live in Vault as craft_slack_webhook_<brand lowercase> (e.g. craft_slack_webhook_atp). No secret = nothing sent.
-- #craft-notifications keeps the one-line "finished reviewing" ping for Hannes; the brand channel gets the full detail,
-- and when a CLIENT finishes, Dillon is tagged so he can look at the updates.
create or replace function public.craft_slack_brand(p_brand text, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare v_url text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets
  where name = 'craft_slack_webhook_' || lower(coalesce(p_brand, '')) limit 1;
  if v_url is null or v_url = '' then return; end if;
  perform net.http_post(url := v_url, body := jsonb_build_object('text', p_text),
                        headers := '{"Content-Type":"application/json"}'::jsonb);
end; $$;
revoke all on function public.craft_slack_brand(text, text) from public, anon, authenticated;

create or replace function public.craft_notify_brand_done()
returns trigger language plpgsql security definer set search_path = public as $$
declare b public.briefs; who text; n_ok int; n_ch int; msg text; v_assets text; v_notes text; v_copy text;
begin
  if new.kind <> 'done' then return new; end if;
  select * into b from public.briefs where id = new.brief_id;
  if b.id is null or b.brand = 'FG' then return new; end if;
  who := coalesce(new.author, 'Someone');
  if craft_is_muted(who) then return new; end if;
  select count(*) filter (where state = 'approved'), count(*) filter (where state = 'changes') into n_ok, n_ch
  from public.notes where brief_id = new.brief_id and kind = 'verdict' and round = new.round and lower(author) = lower(new.author);
  -- per-ad verdicts
  select string_agg(E'\n' || case when v.state = 'approved' then ':white_check_mark: ' else ':x: ' end || craft_asset_title(b, v.asset_id), '' order by v.asset_id)
    into v_assets
  from public.notes v where v.brief_id = new.brief_id and v.kind = 'verdict' and v.round = new.round and lower(v.author) = lower(new.author);
  -- every note in their words
  select string_agg(E'\n• *' || case when n.asset_id = 'general' then 'General' when n.asset_id = 'copy' then 'Ad copy' else craft_asset_title(b, n.asset_id) end || '*'
                    || case when n.t is not null then ' at ' || floor(n.t / 60)::int || ':' || lpad((floor(n.t)::int % 60)::text, 2, '0') else '' end
                    || ': ' || left(n.body, 600), '' order by n.created_at)
    into v_notes
  from public.notes n where n.brief_id = new.brief_id and n.kind = 'note' and n.round = new.round
                        and lower(n.author) = lower(new.author) and coalesce(n.body, '') <> '';
  msg := case when new.audience = 'client' then '<@U0C0D16NQKY> client update: ' else '' end
         || ':white_check_mark: *' || who || '*' || case when new.audience = 'client' then ' (client)' else '' end
         || ' finished reviewing ' || craft_brief_label(b) || ': ' || n_ok || ' approved, ' || n_ch
         || case when n_ch = 1 then ' needs' else ' need' end || ' changes'
         || coalesce(E'\n' || v_assets, '')
         || coalesce(E'\n\n*Notes*' || v_notes, '');
  perform craft_slack_brand(b.brand, msg);
  return new;
end; $$;

drop trigger if exists craft_notify_brand_done on public.notes;
create trigger craft_notify_brand_done after insert on public.notes
  for each row execute function public.craft_notify_brand_done();


-- Oct 22 2026 (Hannes): FORGE boards get their own channel, #forge-notifications (C0CC517D4JC).
-- Two pings: someone OPENS a board (forge.html writes one kind='open' row per reviewer per browser session),
-- and someone presses "I'm done reviewing" (idea counts: approved / changes / killed / not judged).
-- Webhook in Vault as craft_slack_webhook_fg (CRAFT Alerts app, Incoming Webhooks). No secret = nothing sent.
create or replace function public.forge_notify()
returns trigger language plpgsql security definer set search_path = public as $$
declare b public.briefs; who text; lbl text; n_ideas int; n_ok int; n_ch int; n_kill int; n_notes int;
begin
  if new.kind not in ('open', 'done') then return new; end if;
  select * into b from public.briefs where id = new.brief_id;
  if b.id is null or b.brand <> 'FG' then return new; end if;
  who := coalesce(nullif(trim(new.author), ''), 'Someone');
  if craft_is_muted(who) then return new; end if;
  lbl := '<https://hannesolo94.github.io/DL-Review-Process-Demo/forge.html?b=' || b.creator_token || '|'
         || coalesce(nullif(b.data->>'lane_text', ''), b.title, b.slug) || '>';
  if new.kind = 'open' then
    perform craft_slack_brand('fg', '<@U0757BQ1RFW> :eyes: *' || who || '* opened the FORGE board ' || lbl);
    return new;
  end if;
  n_ideas := coalesce(jsonb_array_length(b.data->'ideas'), 0);
  select count(*) filter (where state = 'approved'), count(*) filter (where state = 'changes'), count(*) filter (where state = 'killed')
    into n_ok, n_ch, n_kill
  from (select distinct on (asset_id) asset_id, state from public.notes
        where brief_id = new.brief_id and kind = 'verdict' and lower(author) = lower(new.author)
        order by asset_id, created_at desc) v;
  select count(*) into n_notes from public.notes
  where brief_id = new.brief_id and kind = 'note' and lower(author) = lower(new.author) and coalesce(body, '') <> '';
  perform craft_slack_brand('fg', '<@U0757BQ1RFW> :white_check_mark: *' || who || '* finished reviewing the FORGE board ' || lbl || ': '
          || n_ok || ' approved, ' || n_ch || ' changes, ' || n_kill || ' killed, '
          || greatest(n_ideas - n_ok - n_ch - n_kill, 0) || ' of ' || n_ideas || ' not judged, '
          || n_notes || case when n_notes = 1 then ' note' else ' notes' end);
  return new;
end; $$;

drop trigger if exists forge_notify on public.notes;
create trigger forge_notify after insert on public.notes
  for each row execute function public.forge_notify();
