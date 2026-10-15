-- Accounts are a username and a password. Supabase Auth still keys users by
-- uuid and wants an email, so the apps sign up with
-- "<username>@users.mmerioles.github.io" (ours, and it can't receive mail,
-- so a forged password reset goes nowhere) and keep the username here.

create table public.profiles (
    user_id    uuid        primary key references auth.users (id) on delete cascade,
    username   text        not null check (username ~ '^[a-z0-9_]{3,20}$'),
    created_at timestamptz not null default now()
);
create unique index profiles_username on public.profiles (username);

alter table public.profiles enable row level security;
create policy "own profile" on public.profiles for select to authenticated using (auth.uid() = user_id);
grant select on public.profiles to authenticated;

-- Sign-up sends the username as user metadata; this makes the profile in the
-- same transaction, so an account never exists without one. A taken name
-- fails the sign-up (the apps check first, so only a race gets here).
create function public.make_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
declare name text := lower(trim(new.raw_user_meta_data ->> 'username'));
begin
    if name is null or name !~ '^[a-z0-9_]{3,20}$' then
        raise exception 'bad username';
    end if;
    insert into public.profiles (user_id, username) values (new.id, name);
    return new;
end $$;
create trigger on_user_made after insert on auth.users
    for each row execute function public.make_profile();

-- The live check while someone types a username. Anyone may ask.
create function public.username_available(name text) returns boolean
language sql stable security definer set search_path = '' as $$
    select lower(trim(name)) ~ '^[a-z0-9_]{3,20}$'
       and not exists (select 1 from public.profiles p where p.username = lower(trim(name)))
$$;
revoke all on function public.username_available(text) from public;
grant execute on function public.username_available(text) to anon, authenticated;

-- No more confirmation emails.
drop function public.email_confirmed(uuid);
