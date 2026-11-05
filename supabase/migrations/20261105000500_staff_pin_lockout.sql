-- GURISHA SIMPLE: server-side PIN login lockout.
create table if not exists public.staff_pin_attempts (
  shop_id uuid not null references public.shops(id) on delete cascade,
  login_key text not null,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now(),
  primary key (shop_id, login_key)
);

alter table public.staff_pin_attempts enable row level security;
revoke all on public.staff_pin_attempts from public, anon, authenticated;

create or replace function public.gurisha_pin_is_locked(p_shop_id uuid, p_login_key text)
returns boolean
language sql
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.staff_pin_attempts
    where shop_id = p_shop_id
      and login_key = p_login_key
      and locked_until > now()
  );
$$;

create or replace function public.gurisha_pin_record_failure(p_shop_id uuid, p_login_key text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.staff_pin_attempts(shop_id, login_key, failed_attempts, updated_at)
  values (p_shop_id, p_login_key, 1, now())
  on conflict (shop_id, login_key) do update
  set failed_attempts = case
        when public.staff_pin_attempts.locked_until is not null
             and public.staff_pin_attempts.locked_until <= now() then 1
        else public.staff_pin_attempts.failed_attempts + 1
      end,
      locked_until = case
        when (case
          when public.staff_pin_attempts.locked_until is not null
               and public.staff_pin_attempts.locked_until <= now() then 1
          else public.staff_pin_attempts.failed_attempts + 1
        end) >= 5 then now() + interval '15 minutes'
        else null
      end,
      updated_at = now();
end;
$$;

create or replace function public.gurisha_pin_clear_failures(p_shop_id uuid, p_login_key text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.staff_pin_attempts
  where shop_id = p_shop_id and login_key = p_login_key;
$$;

revoke all on function public.gurisha_pin_is_locked(uuid, text) from public, anon, authenticated;
revoke all on function public.gurisha_pin_record_failure(uuid, text) from public, anon, authenticated;
revoke all on function public.gurisha_pin_clear_failures(uuid, text) from public, anon, authenticated;
grant execute on function public.gurisha_pin_is_locked(uuid, text) to service_role;
grant execute on function public.gurisha_pin_record_failure(uuid, text) to service_role;
grant execute on function public.gurisha_pin_clear_failures(uuid, text) to service_role;
