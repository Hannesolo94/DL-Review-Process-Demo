-- CRAFT live schema, public schema only, generated from the live project on Nov 5 2026 (Magnus).
-- Schema only: no data, no keys, no tokens. Rebuild order: tables, constraints, RLS, functions.

create table if not exists public."briefs" (
  "id" uuid default gen_random_uuid() not null,
  "creator_token" text default new_token() not null,
  "slug" text not null,
  "brand" text not null,
  "title" text not null,
  "round" integer default 1 not null,
  "data" jsonb not null,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  "client_token" text
);
alter table public."briefs" add constraint "briefs_client_token_key" UNIQUE (client_token);
alter table public."briefs" add constraint "briefs_token_key" UNIQUE (creator_token);
alter table public."briefs" add constraint "briefs_pkey" PRIMARY KEY (id);
CREATE INDEX briefs_slug ON public.briefs USING btree (slug);
alter table public."briefs" enable row level security;

create table if not exists public."craft_alert_mutes" (
  "pattern" text not null,
  "note" text
);
alter table public."craft_alert_mutes" add constraint "craft_alert_mutes_pkey" PRIMARY KEY (pattern);
alter table public."craft_alert_mutes" enable row level security;

create table if not exists public."meeting_shares" (
  "token" text not null,
  "meeting_id" text not null,
  "title" text not null,
  "started" text,
  "summary" text,
  "tasks" jsonb,
  "transcript" text not null,
  "shared_to" text,
  "created_at" timestamp with time zone default now() not null,
  "expires_at" timestamp with time zone not null,
  "revoked" boolean default false not null
);
alter table public."meeting_shares" add constraint "meeting_shares_pkey" PRIMARY KEY (token);
alter table public."meeting_shares" enable row level security;

create table if not exists public."notes" (
  "id" text not null,
  "brief_id" uuid not null,
  "round" integer default 1 not null,
  "kind" text default 'note'::text not null,
  "asset_id" text,
  "x" real,
  "y" real,
  "t" real,
  "author" text not null,
  "body" text default ''::text,
  "img" text,
  "link" text,
  "urls" jsonb,
  "headlines" jsonb,
  "primaries" jsonb,
  "state" text,
  "created_at" timestamp with time zone default now() not null,
  "audience" text default 'internal'::text not null
);
alter table public."notes" add constraint "notes_pkey" PRIMARY KEY (id);
alter table public."notes" add constraint "notes_brief_id_fkey" FOREIGN KEY (brief_id) REFERENCES briefs(id) ON DELETE CASCADE;
CREATE INDEX notes_brief_round ON public.notes USING btree (brief_id, round);
alter table public."notes" enable row level security;

create table if not exists public."reports" (
  "id" uuid default gen_random_uuid() not null,
  "report_code" text,
  "brand" text not null,
  "kind" text default 'weekly'::text not null,
  "title" text not null,
  "period" text,
  "period_start" date,
  "status" text default 'final'::text not null,
  "spend" numeric,
  "revenue" numeric,
  "roas" numeric,
  "purchases" numeric,
  "aov" numeric,
  "roas_target" numeric,
  "notion_page_id" text,
  "notion_url" text,
  "library_notion_id" text,
  "html" text,
  "slack_text" text,
  "qa" text,
  "approved_at" timestamp with time zone,
  "created_at" timestamp with time zone default now() not null,
  "source" text default 'hub'::text not null
);
alter table public."reports" add constraint "reports_report_code_key" UNIQUE (report_code);
alter table public."reports" add constraint "reports_pkey" PRIMARY KEY (id);
CREATE INDEX reports_brand_idx ON public.reports USING btree (brand, period_start DESC);
alter table public."reports" enable row level security;

create table if not exists public."review_events" (
  "id" bigint default nextval('review_events_id_seq'::regclass) not null,
  "brief_id" uuid not null,
  "kind" text default 'open'::text not null,
  "author" text,
  "audience" text,
  "created_at" timestamp with time zone default now() not null
);
alter table public."review_events" add constraint "review_events_pkey" PRIMARY KEY (id);
alter table public."review_events" add constraint "review_events_brief_id_fkey" FOREIGN KEY (brief_id) REFERENCES briefs(id) ON DELETE CASCADE;
alter table public."review_events" enable row level security;

CREATE OR REPLACE FUNCTION public.craft_asset_title(b briefs, p_asset text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select regexp_replace(coalesce((select a->>'title' from jsonb_array_elements(b.data->'assets') a where a->>'id' = p_asset), p_asset),
                        '\s*\((revised|new)[^)]*\)\s*$', '');
$function$;

CREATE OR REPLACE FUNCTION public.craft_brief_label(b briefs)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select '<https://hannesolo94.github.io/DL-Review-Process-Demo/?b=' || b.creator_token || '|'
         || coalesce(nullif(b.title, ''), b.slug) || '>';
$function$;

CREATE OR REPLACE FUNCTION public.craft_is_muted(p_author text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.craft_alert_mutes m where lower(trim(coalesce(p_author, ''))) like m.pattern);
$function$;

CREATE OR REPLACE FUNCTION public.craft_notify_brand_done()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$;

CREATE OR REPLACE FUNCTION public.craft_notify_note()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$;

CREATE OR REPLACE FUNCTION public.craft_notify_open()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b public.briefs;
begin
  select * into b from public.briefs where id = new.brief_id;
  if b.id is null or craft_is_muted(new.author) then return new; end if;
  perform craft_slack(':eyes: *' || coalesce(new.author, 'Someone') || '*'
                      || case when new.audience = 'client' then ' (client)' else '' end
                      || ' opened ' || craft_brief_label(b) || ' and started reviewing');
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.craft_slack(p_text text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_url text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'craft_slack_webhook' limit 1;
  if v_url is null or v_url = '' then return; end if;
  perform net.http_post(url := v_url,
                        body := jsonb_build_object('text', '<@U0757BQ1RFW> ' || p_text),   -- @Hannes so he gets the ping
                        headers := '{"Content-Type":"application/json"}'::jsonb);
end; $function$;

CREATE OR REPLACE FUNCTION public.craft_slack_brand(p_brand text, p_text text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_url text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets
  where name = 'craft_slack_webhook_' || lower(coalesce(p_brand, '')) limit 1;
  if v_url is null or v_url = '' then return; end if;
  perform net.http_post(url := v_url, body := jsonb_build_object('text', p_text),
                        headers := '{"Content-Type":"application/json"}'::jsonb);
end; $function$;

CREATE OR REPLACE FUNCTION public.del_note(p_token text, p_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_brief uuid; v_aud text;
begin
  select id, case when creator_token = p_token then 'internal' else 'client' end
    into v_brief, v_aud
  from public.briefs where creator_token = p_token or client_token = p_token;
  if v_brief is null then raise exception 'unknown review link'; end if;
  delete from public.notes where id = p_id and brief_id = v_brief
    and (v_aud = 'internal' or audience = 'client');
end; $function$;

CREATE OR REPLACE FUNCTION public.forge_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$;

CREATE OR REPLACE FUNCTION public.get_brief(p_token text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'slug', b.slug, 'brand', b.brand, 'title', b.title, 'round', b.round,
    'view', case when b.creator_token = p_token then 'creator' else 'client' end,
    'data', case when b.creator_token = p_token then b.data else b.data - 'strategy' end)
  from public.briefs b
  where b.creator_token = p_token or b.client_token = p_token;
$function$;

CREATE OR REPLACE FUNCTION public.get_meeting_share(p_token text)
 RETURNS json
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select json_build_object('title', title, 'started', started, 'summary', summary, 'tasks', tasks, 'transcript', transcript, 'expires_at', expires_at)
  from meeting_shares where token = p_token and not revoked and expires_at > now()
$function$;

CREATE OR REPLACE FUNCTION public.get_notes(p_token text)
 RETURNS TABLE(id text, round integer, kind text, asset_id text, x real, y real, t real, author text, body text, img text, link text, urls jsonb, headlines jsonb, primaries jsonb, state text, audience text, created_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select n.id,n.round,n.kind,n.asset_id,n.x,n.y,n.t,n.author,n.body,n.img,n.link,
         n.urls,n.headlines,n.primaries,n.state,n.audience,n.created_at
  from public.notes n join public.briefs b on b.id = n.brief_id
  where (b.creator_token = p_token)
     or (b.client_token = p_token and n.audience = 'client')
  order by n.created_at;
$function$;

CREATE OR REPLACE FUNCTION public.log_open(p_token text, p_author text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$;

CREATE OR REPLACE FUNCTION public.new_token()
 RETURNS text
 LANGUAGE sql
 SET search_path TO 'public', 'extensions', 'pg_catalog'
AS $function$
  select replace(replace(replace(
           encode(extensions.gen_random_bytes(18),'base64'),'+','-'),'/','_'),'=','');
$function$;

CREATE OR REPLACE FUNCTION public.open_to_client(p_creator_token text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text;
begin
  update public.briefs
     set client_token = coalesce(client_token, public.new_token()), updated_at = now()
   where creator_token = p_creator_token returning client_token into v;
  if v is null then raise exception 'unknown creator link'; end if;
  return v;
end; $function$;

CREATE OR REPLACE FUNCTION public.put_note(p_token text, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_brief uuid; v_aud text;
begin
  select id, case when creator_token = p_token then 'internal' else 'client' end
    into v_brief, v_aud
  from public.briefs where creator_token = p_token or client_token = p_token;
  if v_brief is null then raise exception 'unknown review link'; end if;
  insert into public.notes (id,brief_id,round,kind,asset_id,x,y,t,author,body,img,link,
                            urls,headlines,primaries,state,audience)
  values (p->>'id', v_brief, coalesce((p->>'round')::int,1), coalesce(p->>'kind','note'),
          p->>'assetId', (p->>'x')::real, (p->>'y')::real, (p->>'t')::real,
          coalesce(p->>'author','Someone'), coalesce(p->>'text',''),
          p->>'img', p->>'link', p->'urls', p->'headlines', p->'primaries', p->>'state', v_aud)
  on conflict (id) do update set
    body=excluded.body, img=excluded.img, link=excluded.link, urls=excluded.urls,
    headlines=excluded.headlines, primaries=excluded.primaries,
    state=excluded.state, author=excluded.author;
end; $function$;

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

grant execute on function public.craft_asset_title(b briefs, p_asset text) to anon;
grant execute on function public.craft_asset_title(b briefs, p_asset text) to authenticated;
grant execute on function public.craft_brief_label(b briefs) to anon;
grant execute on function public.craft_brief_label(b briefs) to authenticated;
grant execute on function public.craft_is_muted(p_author text) to anon;
grant execute on function public.craft_is_muted(p_author text) to authenticated;
grant execute on function public.craft_notify_brand_done() to anon;
grant execute on function public.craft_notify_brand_done() to authenticated;
grant execute on function public.craft_notify_note() to anon;
grant execute on function public.craft_notify_note() to authenticated;
grant execute on function public.craft_notify_open() to anon;
grant execute on function public.craft_notify_open() to authenticated;
grant execute on function public.del_note(p_token text, p_id text) to anon;
grant execute on function public.del_note(p_token text, p_id text) to authenticated;
grant execute on function public.forge_notify() to anon;
grant execute on function public.forge_notify() to authenticated;
grant execute on function public.get_brief(p_token text) to anon;
grant execute on function public.get_brief(p_token text) to authenticated;
grant execute on function public.get_meeting_share(p_token text) to anon;
grant execute on function public.get_meeting_share(p_token text) to authenticated;
grant execute on function public.get_notes(p_token text) to anon;
grant execute on function public.get_notes(p_token text) to authenticated;
grant execute on function public.log_open(p_token text, p_author text) to anon;
grant execute on function public.log_open(p_token text, p_author text) to authenticated;
grant execute on function public.new_token() to anon;
grant execute on function public.new_token() to authenticated;
grant execute on function public.open_to_client(p_creator_token text) to authenticated;
grant execute on function public.put_note(p_token text, p jsonb) to anon;
grant execute on function public.put_note(p_token text, p jsonb) to authenticated;
grant execute on function public.rls_auto_enable() to anon;
grant execute on function public.rls_auto_enable() to authenticated;
