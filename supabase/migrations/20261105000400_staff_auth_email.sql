-- GURISHA SIMPLE: internal Auth email for employee PIN accounts.
-- This value is private and must never be returned to the browser.
alter table public.staff_profiles
  add column if not exists auth_email text;

create unique index if not exists idx_staff_profiles_auth_email
  on public.staff_profiles(auth_email)
  where auth_email is not null;

-- Ensure profile writes remain server-side only.
revoke all on public.staff_profiles from anon, authenticated;
grant select on public.staff_profiles to authenticated;
