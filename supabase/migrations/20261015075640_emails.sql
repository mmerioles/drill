-- Accounts are an email and a password. Supabase Auth keys users by uuid and
-- keeps the email itself; the email isn't verified at sign-up and will be
-- what account recovery uses. Usernames and their profiles go.

drop trigger on_user_made on auth.users;
drop function public.make_profile();
drop function public.username_available(text);
drop table public.profiles;

-- The live check on the sign-up form. Anyone may ask; it tells whether an
-- email already has an account (a deliberate trade for the live check).
create function public.email_available(email text) returns boolean
language sql stable security definer set search_path = '' as $$
    select not exists (
        select 1 from auth.users u where lower(u.email) = lower(trim(email_available.email))
    )
$$;
revoke all on function public.email_available(text) from public;
grant execute on function public.email_available(text) to anon, authenticated;
