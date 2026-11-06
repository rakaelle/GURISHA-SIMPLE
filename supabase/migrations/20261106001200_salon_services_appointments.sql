-- GURISHA — Fondations du module salon : catalogue média, équipes, rendez-vous,
-- prestations à domicile, réservation de taxi et dépenses réelles.
-- Migration additive : ne modifie aucune donnée des modules existants.

-- Tous les catalogues peuvent associer plusieurs images et vidéos.
alter table public.products
  add column if not exists media_items jsonb not null default '[]'::jsonb;
alter table public.fast_food_menu_items
  add column if not exists media_items jsonb not null default '[]'::jsonb;
alter table public.construction_materials
  add column if not exists media_items jsonb not null default '[]'::jsonb;

alter table public.products
  drop constraint if exists products_media_items_array_check;
alter table public.products
  add constraint products_media_items_array_check
  check (jsonb_typeof(media_items) = 'array');
alter table public.fast_food_menu_items
  drop constraint if exists fast_food_menu_items_media_items_array_check;
alter table public.fast_food_menu_items
  add constraint fast_food_menu_items_media_items_array_check
  check (jsonb_typeof(media_items) = 'array');
alter table public.construction_materials
  drop constraint if exists construction_materials_media_items_array_check;
alter table public.construction_materials
  add constraint construction_materials_media_items_array_check
  check (jsonb_typeof(media_items) = 'array');

-- Autorisation commune : propriétaire/gestionnaire ou employé ayant un rôle
-- explicitement synchronisé dans les métadonnées Auth par l'Edge Function.
create or replace function public.gurisha_has_shop_access(p_shop_id uuid, p_roles text[] default array[]::text[])
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.shop_members sm
     where sm.shop_id = p_shop_id
       and sm.user_id = auth.uid()
       and (
         sm.role in ('owner','manager','gestionnaire')
         or sm.role = any(coalesce(p_roles, array[]::text[]))
         or (
           coalesce(auth.jwt()->'user_metadata'->'gurisha_roles', '[]'::jsonb)
           ?| coalesce(p_roles, array[]::text[])
         )
       )
  );
$$;

create table if not exists public.salon_services (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null,
  category text not null default 'Coiffure',
  description text,
  price numeric(14,2) not null default 0 check (price >= 0),
  duration_minutes integer not null default 60 check (duration_minutes > 0),
  required_staff_count integer not null default 2 check (required_staff_count > 0),
  is_home_service boolean not null default true,
  media_items jsonb not null default '[]'::jsonb check (jsonb_typeof(media_items) = 'array'),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (shop_id, name)
);
create index if not exists salon_services_shop_idx
  on public.salon_services(shop_id, is_active, category);

create table if not exists public.salon_teams (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  team_name text not null,
  team_leader_id uuid references public.staff_profiles(id) on delete set null,
  is_active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (shop_id, team_name)
);
create index if not exists salon_teams_shop_idx on public.salon_teams(shop_id, is_active);

create table if not exists public.salon_team_members (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  team_id uuid not null references public.salon_teams(id) on delete cascade,
  staff_profile_id uuid not null references public.staff_profiles(id) on delete cascade,
  team_function text not null default 'Tresseuse',
  created_at timestamptz not null default now(),
  unique (team_id, staff_profile_id),
  unique (shop_id, team_id, staff_profile_id)
);
create index if not exists salon_team_members_staff_idx
  on public.salon_team_members(shop_id, staff_profile_id);

create table if not exists public.salon_appointments (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  appointment_number text not null,
  client_name text not null,
  client_phone text,
  service_id uuid references public.salon_services(id) on delete set null,
  service_name text not null,
  service_amount numeric(14,2) not null default 0 check (service_amount >= 0),
  required_staff_count integer not null default 2 check (required_staff_count > 0),
  appointment_date date not null,
  start_time time not null,
  duration_minutes integer not null default 60 check (duration_minutes > 0),
  location_mode text not null default 'salon' check (location_mode in ('salon','home')),
  client_address text,
  client_location_notes text,
  transport_charge_client numeric(14,2) not null default 0 check (transport_charge_client >= 0),
  quote_status text not null default 'draft' check (quote_status in ('draft','sent','accepted','rejected')),
  appointment_status text not null default 'pending' check (appointment_status in ('pending','confirmed','in_progress','completed','cancelled')),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','partial','paid')),
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (shop_id, appointment_number),
  check (location_mode <> 'home' or nullif(trim(coalesce(client_address,'')), '') is not null)
);
create index if not exists salon_appointments_schedule_idx
  on public.salon_appointments(shop_id, appointment_date, start_time);
create index if not exists salon_appointments_status_idx
  on public.salon_appointments(shop_id, appointment_status, appointment_date);

alter table public.salon_appointments
  add column if not exists team_id uuid references public.salon_teams(id) on delete set null;

create table if not exists public.salon_appointment_staff (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  appointment_id uuid not null references public.salon_appointments(id) on delete cascade,
  staff_profile_id uuid not null references public.staff_profiles(id) on delete restrict,
  assignment_label text not null default 'Tresseuse',
  created_at timestamptz not null default now(),
  unique (appointment_id, staff_profile_id)
);
create index if not exists salon_appointment_staff_member_idx
  on public.salon_appointment_staff(shop_id, staff_profile_id);

create table if not exists public.salon_transport_bookings (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  appointment_id uuid not null unique references public.salon_appointments(id) on delete cascade,
  transport_type text not null default 'taxi' check (transport_type in ('taxi')),
  booking_status text not null default 'to_book' check (booking_status in ('to_book','booked','driver_confirmed','in_progress','completed','cancelled')),
  pickup_address text not null,
  destination_address text not null,
  pickup_at timestamptz not null,
  passenger_count integer not null default 2 check (passenger_count > 0),
  taxi_provider text,
  taxi_contact text,
  client_charge_amount numeric(14,2) not null default 0 check (client_charge_amount >= 0),
  booking_notes text,
  booked_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists salon_transport_bookings_schedule_idx
  on public.salon_transport_bookings(shop_id, pickup_at, booking_status);

-- Dépenses réellement payées par le salon : distinctes du montant facturé à la cliente.
create table if not exists public.salon_expenses (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  appointment_id uuid references public.salon_appointments(id) on delete set null,
  transport_booking_id uuid references public.salon_transport_bookings(id) on delete set null,
  category text not null default 'transport',
  description text not null,
  amount numeric(14,2) not null check (amount > 0),
  paid_to text,
  paid_at timestamptz not null default now(),
  receipt_media_items jsonb not null default '[]'::jsonb check (jsonb_typeof(receipt_media_items) = 'array'),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists salon_expenses_shop_date_idx
  on public.salon_expenses(shop_id, paid_at desc);

-- Détecter les rendez-vous auxquels un employé est personnellement affecté.
create or replace function public.gurisha_is_salon_appointment_staff(p_appointment_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.salon_appointment_staff sas
      join public.staff_profiles sp on sp.id = sas.staff_profile_id
     where sas.appointment_id = p_appointment_id
       and sp.user_id = auth.uid()
       and sp.is_active = true
  );
$$;

-- Vérification sécurisée d'appartenance à une équipe (évite une récursion RLS).
create or replace function public.gurisha_is_salon_team_member(p_team_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $
  select exists (
    select 1
      from public.salon_team_members tm
      join public.staff_profiles sp on sp.id = tm.staff_profile_id
     where tm.team_id = p_team_id
       and sp.user_id = auth.uid()
       and sp.is_active = true
  );
$;

-- Les responsables et les employés beauté/réception peuvent voir les noms
-- de leurs collègues afin de constituer les équipes et consulter les affectations.
drop policy if exists salon_staff_profiles_read on public.staff_profiles;
create policy salon_staff_profiles_read on public.staff_profiles
for select to authenticated
using (public.gurisha_has_shop_access(shop_id, array['hairdresser','beautician','receptionist']));

-- RLS : données isolées par établissement et droits adaptés au rôle.
do $$
declare t text;
begin
  foreach t in array array[
    'salon_services','salon_teams','salon_team_members',
    'salon_appointments','salon_appointment_staff',
    'salon_transport_bookings','salon_expenses'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

drop policy if exists salon_services_read on public.salon_services;
create policy salon_services_read on public.salon_services
for select to authenticated
using (public.gurisha_has_shop_access(shop_id, array['hairdresser','beautician','receptionist']));
drop policy if exists salon_services_manage on public.salon_services;
create policy salon_services_manage on public.salon_services
for all to authenticated
using (public.gurisha_has_shop_access(shop_id, array[]::text[]))
with check (public.gurisha_has_shop_access(shop_id, array[]::text[]));

drop policy if exists salon_teams_read on public.salon_teams;
create policy salon_teams_read on public.salon_teams
for select to authenticated
using (
  public.gurisha_has_shop_access(shop_id, array['hairdresser','beautician','receptionist'])
  or public.gurisha_is_salon_team_member(id)
);
drop policy if exists salon_teams_manage on public.salon_teams;
create policy salon_teams_manage on public.salon_teams
for all to authenticated
using (public.gurisha_has_shop_access(shop_id, array[]::text[]))
with check (public.gurisha_has_shop_access(shop_id, array[]::text[]));

drop policy if exists salon_team_members_read on public.salon_team_members;
create policy salon_team_members_read on public.salon_team_members
for select to authenticated
using (
  public.gurisha_has_shop_access(shop_id, array['hairdresser','beautician','receptionist'])
  or exists (
    select 1 from public.staff_profiles sp
    where sp.id=salon_team_members.staff_profile_id and sp.user_id=auth.uid()
  )
  or public.gurisha_is_salon_team_member(team_id)
);
drop policy if exists salon_team_members_manage on public.salon_team_members;
create policy salon_team_members_manage on public.salon_team_members
for all to authenticated
using (public.gurisha_has_shop_access(shop_id, array[]::text[]))
with check (public.gurisha_has_shop_access(shop_id, array[]::text[]));

drop policy if exists salon_appointments_read on public.salon_appointments;
create policy salon_appointments_read on public.salon_appointments
for select to authenticated
using (
  public.gurisha_has_shop_access(shop_id, array['receptionist'])
  or public.gurisha_is_salon_appointment_staff(id)
);
drop policy if exists salon_appointments_manage on public.salon_appointments;
create policy salon_appointments_manage on public.salon_appointments
for all to authenticated
using (public.gurisha_has_shop_access(shop_id, array['receptionist']))
with check (public.gurisha_has_shop_access(shop_id, array['receptionist']));

drop policy if exists salon_appointment_staff_read on public.salon_appointment_staff;
create policy salon_appointment_staff_read on public.salon_appointment_staff
for select to authenticated
using (
  public.gurisha_has_shop_access(shop_id, array['receptionist'])
  or public.gurisha_is_salon_appointment_staff(appointment_id)
);
drop policy if exists salon_appointment_staff_manage on public.salon_appointment_staff;
create policy salon_appointment_staff_manage on public.salon_appointment_staff
for all to authenticated
using (public.gurisha_has_shop_access(shop_id, array['receptionist']))
with check (public.gurisha_has_shop_access(shop_id, array['receptionist']));

drop policy if exists salon_transport_read on public.salon_transport_bookings;
create policy salon_transport_read on public.salon_transport_bookings
for select to authenticated
using (
  public.gurisha_has_shop_access(shop_id, array['receptionist'])
  or public.gurisha_is_salon_appointment_staff(appointment_id)
);
drop policy if exists salon_transport_manage on public.salon_transport_bookings;
create policy salon_transport_manage on public.salon_transport_bookings
for all to authenticated
using (public.gurisha_has_shop_access(shop_id, array['receptionist']))
with check (public.gurisha_has_shop_access(shop_id, array['receptionist']));

drop policy if exists salon_expenses_read on public.salon_expenses;
create policy salon_expenses_read on public.salon_expenses
for select to authenticated
using (public.gurisha_has_shop_access(shop_id, array[]::text[]));
drop policy if exists salon_expenses_manage on public.salon_expenses;
create policy salon_expenses_manage on public.salon_expenses
for all to authenticated
using (public.gurisha_has_shop_access(shop_id, array[]::text[]))
with check (public.gurisha_has_shop_access(shop_id, array[]::text[]));

grant select,insert,update,delete on public.salon_services to authenticated;
grant select,insert,update,delete on public.salon_teams to authenticated;
grant select,insert,update,delete on public.salon_team_members to authenticated;
grant select,insert,update,delete on public.salon_appointments to authenticated;
grant select,insert,update,delete on public.salon_appointment_staff to authenticated;
grant select,insert,update,delete on public.salon_transport_bookings to authenticated;
grant select,insert,update,delete on public.salon_expenses to authenticated;

-- Un employé affecté à un rendez-vous peut uniquement signaler le début
-- ou la fin de sa prestation, sans modifier le devis ni les données financières.
create or replace function public.gurisha_salon_update_appointment_status(
  p_appointment_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = public
as $
declare
  v_current text;
begin
  if p_status not in ('in_progress','completed') then
    raise exception 'Statut non autorisé.';
  end if;
  if not public.gurisha_is_salon_appointment_staff(p_appointment_id) then
    raise exception 'Vous ne faites pas partie de cette équipe.';
  end if;
  select appointment_status into v_current
    from public.salon_appointments
   where id = p_appointment_id
   for update;
  if not found then raise exception 'Rendez-vous introuvable.'; end if;
  if p_status = 'in_progress' and v_current <> 'confirmed' then
    raise exception 'Le rendez-vous doit être confirmé avant de commencer.';
  end if;
  if p_status = 'completed' and v_current <> 'in_progress' then
    raise exception 'La prestation doit être en cours avant de la terminer.';
  end if;
  update public.salon_appointments
     set appointment_status = p_status, updated_at = now()
   where id = p_appointment_id;
end;
$;
revoke all on function public.gurisha_salon_update_appointment_status(uuid,text) from public, anon;
grant execute on function public.gurisha_salon_update_appointment_status(uuid,text) to authenticated;

-- Stocker les photos et vidéos des catalogues dans un bucket public dédié.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'gurisha-catalog-media',
  'gurisha-catalog-media',
  true,
  52428800,
  array['image/jpeg','image/png','image/webp','image/avif','video/mp4','video/webm','video/quicktime']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists gurisha_catalog_media_upload on storage.objects;
create policy gurisha_catalog_media_upload on storage.objects
for insert to authenticated
with check (
  bucket_id = 'gurisha-catalog-media'
  and public.gurisha_has_shop_access((storage.foldername(name))[1]::uuid, array['cashier']::text[])
);
drop policy if exists gurisha_catalog_media_update on storage.objects;
create policy gurisha_catalog_media_update on storage.objects
for update to authenticated
using (
  bucket_id = 'gurisha-catalog-media'
  and public.gurisha_has_shop_access((storage.foldername(name))[1]::uuid, array[]::text[])
)
with check (
  bucket_id = 'gurisha-catalog-media'
  and public.gurisha_has_shop_access((storage.foldername(name))[1]::uuid, array[]::text[])
);
drop policy if exists gurisha_catalog_media_delete on storage.objects;
create policy gurisha_catalog_media_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'gurisha-catalog-media'
  and public.gurisha_has_shop_access((storage.foldername(name))[1]::uuid, array[]::text[])
);
