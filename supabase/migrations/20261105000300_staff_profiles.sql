-- GURISHA SIMPLE: profils d'employés liés aux comptes Auth.
-- Les écritures seront effectuées par une Edge Function sécurisée (service role côté serveur uniquement).

create table if not exists public.staff_profiles (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null check (role in ('manager', 'cashier')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (shop_id, user_id),
  unique (shop_id, display_name)
);

create index if not exists idx_staff_profiles_shop on public.staff_profiles(shop_id);

alter table public.staff_profiles enable row level security;

drop policy if exists "owners can view staff profiles" on public.staff_profiles;
create policy "owners can view staff profiles"
on public.staff_profiles for select
to authenticated
using (public.has_shop_role(shop_id, array['owner']));

-- Aucun droit d'écriture direct depuis le navigateur.
-- Les créations, désactivations, changements de code et suppressions passent par le serveur.
revoke all on public.staff_profiles from anon, authenticated;
grant select on public.staff_profiles to authenticated;

