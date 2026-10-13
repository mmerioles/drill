-- drill's hosted sync: the same contract as the self-hosted server
-- (docs/SYNC.md), on Supabase. Accounts are Supabase Auth users; this file
-- adds their session history.
--
-- Clients never write the table directly. They call two functions:
--   push_sessions(sessions jsonb) -> integer   rows that won the merge
--   pull_sessions(after bigint)   -> jsonb     { sessions, cursor, more }
-- Both answer in the FocusSession JSON the apps already decode.

-- One sequence for all users. A row takes a fresh number every time it's
-- written, so "seq > cursor" is exactly what a device hasn't seen yet. It's
-- server-assigned, so a device with a wrong clock can't make others skip rows.
create sequence public.sessions_seq as bigint;

create table public.sessions (
    user_id         uuid        not null references auth.users (id) on delete cascade,
    id              uuid        not null,
    started_at      timestamptz not null,
    ended_at        timestamptz not null,
    focus_seconds   integer     not null check (focus_seconds between 0 and 86400),
    planned_seconds integer     not null check (planned_seconds between 0 and 86400),
    completed       boolean     not null,
    tag             text        check (char_length(tag) <= 100),
    device_id       text        not null check (char_length(device_id) between 1 and 100),
    updated_at      timestamptz not null,
    deleted_at      timestamptz,
    seq             bigint      not null default nextval('public.sessions_seq'),
    -- Keyed per user, so one account's ids can never touch another's rows.
    primary key (user_id, id)
);

-- Every pull is "this user's rows after seq n, in order": one index range scan.
create index sessions_user_seq on public.sessions (user_id, seq);

alter sequence public.sessions_seq owned by public.sessions.seq;

-- Reads go through RLS as well as the functions; writes only through
-- push_sessions.
alter table public.sessions enable row level security;

create policy "read own sessions" on public.sessions
    for select to authenticated
    using (user_id = (select auth.uid()));

revoke all on public.sessions from anon, authenticated;
grant select on public.sessions to authenticated;
revoke all on sequence public.sessions_seq from anon, authenticated;

-- Dates go out as whole-second UTC ("…Z"): Swift's .iso8601 decoder rejects
-- fractions and offsets other than Z on some systems.
create function public.session_json(s public.sessions) returns jsonb
language sql immutable set search_path = '' as $$
    select jsonb_build_object(
        'id',             upper(s.id::text),
        'startedAt',      to_char(s.started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'endedAt',        to_char(s.ended_at   at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'focusSeconds',   s.focus_seconds,
        'plannedSeconds', s.planned_seconds,
        'completed',      s.completed,
        'tag',            s.tag,
        'deviceID',       s.device_id,
        'updatedAt',      to_char(s.updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'deletedAt',      to_char(s.deleted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    )
$$;

-- Last-writer-wins on updatedAt; returns how many rows were taken. A bad row
-- fails the whole push. Unconfirmed accounts get 403 (errcode 42501), which
-- the apps already read as "confirm your email first".
create function public.push_sessions(sessions jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
    uid uuid := auth.uid();
    accepted integer;
begin
    if uid is null then
        raise exception 'sign in again' using errcode = '28000';
    end if;
    if not exists (select 1 from auth.users u where u.id = uid and u.email_confirmed_at is not null) then
        raise exception 'confirm your email first' using errcode = '42501';
    end if;
    if jsonb_typeof(sessions) is distinct from 'array' then
        raise exception 'sessions must be a list' using errcode = '22023';
    end if;
    if jsonb_array_length(sessions) > 500 then
        raise exception 'push at most 500 sessions at a time' using errcode = '22023';
    end if;

    -- Serialize pushes per user, so their seq numbers commit in order and a
    -- pull can never pass a number that's still in flight.
    perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));

    insert into public.sessions as s (user_id, id, started_at, ended_at, focus_seconds,
                                      planned_seconds, completed, tag, device_id,
                                      updated_at, deleted_at)
    -- The newest copy of each id, in case a batch names one twice.
    select distinct on (r.id)
           uid, r.id,
           date_trunc('second', r."startedAt"), date_trunc('second', r."endedAt"),
           round(r."focusSeconds"), round(r."plannedSeconds"), r.completed,
           nullif(r.tag, ''), r."deviceID",
           date_trunc('second', r."updatedAt"), date_trunc('second', r."deletedAt")
    from jsonb_to_recordset(sessions) as r(
        id uuid, "startedAt" timestamptz, "endedAt" timestamptz,
        "focusSeconds" double precision, "plannedSeconds" double precision,
        completed boolean, tag text, "deviceID" text,
        "updatedAt" timestamptz, "deletedAt" timestamptz)
    order by r.id, r."updatedAt" desc
    on conflict (user_id, id) do update set
        started_at = excluded.started_at, ended_at = excluded.ended_at,
        focus_seconds = excluded.focus_seconds, planned_seconds = excluded.planned_seconds,
        completed = excluded.completed, tag = excluded.tag, device_id = excluded.device_id,
        updated_at = excluded.updated_at, deleted_at = excluded.deleted_at,
        seq = nextval('public.sessions_seq')
    where excluded.updated_at > s.updated_at;

    get diagnostics accepted = row_count;
    return accepted;
exception
    when not_null_violation or check_violation or invalid_text_representation
         or invalid_datetime_format or datetime_field_overflow then
        raise exception 'bad session: %', sqlerrm using errcode = '22023';
end;
$$;

-- Pages of 500 after a cursor. Start at 0; repeat while more is true.
create function public.pull_sessions("after" bigint default 0) returns jsonb
language sql stable security invoker set search_path = '' as $$
    with page as (
        select s.* from public.sessions s
        where s.user_id = (select auth.uid()) and s.seq > "after"
        order by s.seq
        limit 501
    )
    select jsonb_build_object(
        'sessions', coalesce((select jsonb_agg(public.session_json(p) order by p.seq)
                              from (select * from page order by seq limit 500) p), '[]'::jsonb),
        'cursor',   coalesce((select max(seq) from (select seq from page order by seq limit 500) q),
                             "after")::text,
        'more',     (select count(*) > 500 from page)
    )
$$;

revoke all on function public.session_json(public.sessions) from public, anon;
revoke all on function public.push_sessions(jsonb) from public, anon;
revoke all on function public.pull_sessions(bigint) from public, anon;
grant execute on function public.session_json(public.sessions) to authenticated;
grant execute on function public.push_sessions(jsonb) to authenticated;
grant execute on function public.pull_sessions(bigint) to authenticated;
