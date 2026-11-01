-- Nov 1 2026: meeting share pages, same locked pattern as CRAFT. RLS on with no policies, so the public key reaches nothing,
-- and the one function hands back a single meeting to whoever holds its token, until it expires or is revoked.
create table if not exists meeting_shares (
  token text primary key,
  meeting_id text not null,
  title text not null,
  started text,
  summary text,
  tasks jsonb,
  transcript text not null,
  shared_to text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked boolean not null default false
);
alter table meeting_shares enable row level security;

create or replace function get_meeting_share(p_token text)
returns json language sql security definer set search_path = public as $$
  select json_build_object('title', title, 'started', started, 'summary', summary, 'tasks', tasks, 'transcript', transcript, 'expires_at', expires_at)
  from meeting_shares where token = p_token and not revoked and expires_at > now()
$$;
revoke all on function get_meeting_share(text) from public;
grant execute on function get_meeting_share(text) to anon, authenticated;
