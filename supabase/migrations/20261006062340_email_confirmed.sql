-- Lets an app that just signed someone up notice when they click the link
-- in the confirmation email, so it can sign them in by itself.
--
-- It answers only for a user id, which Supabase hands back to the device
-- that made the account and which is too random to guess. Asking about an
-- email instead would tell anyone which addresses have confirmed accounts.
create function public.email_confirmed(user_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
    select exists (
        select 1 from auth.users u
        where u.id = email_confirmed.user_id and u.email_confirmed_at is not null
    )
$$;

revoke all on function public.email_confirmed(uuid) from public;
grant execute on function public.email_confirmed(uuid) to anon, authenticated;
