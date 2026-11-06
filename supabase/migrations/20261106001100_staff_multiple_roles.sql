-- Catalogue de rôles multiples par employé.
-- Le champ role existant reste conservé pour compatibilité avec les anciens écrans et politiques.
alter table public.staff_profiles
  add column if not exists roles text[] not null default '{}';

update public.staff_profiles
set roles = array[role]
where roles is null or cardinality(roles) = 0;

alter table public.staff_profiles
  drop constraint if exists staff_profiles_roles_check;

alter table public.staff_profiles
  add constraint staff_profiles_roles_check
  check (
    roles <@ array[
      'manager','cashier','seller','stock_manager','preparer',
      'order_preparer','delivery_person','hairdresser','beautician',
      'receptionist','baker','mechanic','driver','reservation_manager',
      'delivery_manager','mover','team_leader','event_manager','technician'
    ]::text[]
    and cardinality(roles) > 0
  );

comment on column public.staff_profiles.roles is
  'Rôles opérationnels attribués par le propriétaire; role conserve le rôle historique principal.';
