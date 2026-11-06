-- GURISHA SIMPLE: configuration des activités et modules par établissement.
-- Migration additive : ne modifie ni les stocks, ni les ventes, ni les commandes existantes.

create table if not exists public.shop_module_settings (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  activity_types text[] not null default array['legacy']::text[],
  enabled_modules text[] not null default array[
    'commerce',
    'pos',
    'fast_food'
  ]::text[],
  marketplace_status text not null default 'not_requested'
    check (marketplace_status in ('not_requested', 'pending', 'approved', 'suspended', 'rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create index if not exists idx_shop_module_settings_status
  on public.shop_module_settings(marketplace_status);

alter table public.shop_module_settings enable row level security;

-- La configuration n'est jamais modifiable directement depuis le navigateur.
-- Les lectures et modifications passent par les RPC ci-dessous.
revoke all on table public.shop_module_settings from anon, authenticated;

-- Les établissements déjà créés reçoivent un profil "legacy" qui conserve
-- les fonctionnalités actuelles jusqu'à leur configuration explicite.
insert into public.shop_module_settings (shop_id, activity_types, enabled_modules)
select s.id,
       array['legacy']::text[],
       array['commerce', 'pos', 'fast_food']::text[]
  from public.shops s
on conflict (shop_id) do nothing;

create or replace function public.gurisha_get_shop_modules(p_shop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Connexion requise.';
  end if;

  if not exists (
    select 1
      from public.shop_members sm
     where sm.shop_id = p_shop_id
       and sm.user_id = auth.uid()
  ) then
    raise exception 'Vous n’avez pas accès à cet établissement.';
  end if;

  select jsonb_build_object(
    'shop_id', cfg.shop_id,
    'activity_types', to_jsonb(cfg.activity_types),
    'enabled_modules', to_jsonb(cfg.enabled_modules),
    'marketplace_status', cfg.marketplace_status
  )
    into v_result
    from public.shop_module_settings cfg
   where cfg.shop_id = p_shop_id;

  if v_result is null then
    raise exception 'Configuration de l’établissement introuvable.';
  end if;

  return v_result;
end;
$$;

create or replace function public.gurisha_save_shop_modules(
  p_shop_id uuid,
  p_activity_types text[],
  p_enabled_modules text[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Connexion requise.';
  end if;

  if not exists (
    select 1
      from public.shop_members sm
     where sm.shop_id = p_shop_id
       and sm.user_id = auth.uid()
       and sm.role = 'owner'
  ) then
    raise exception 'Seul le propriétaire peut configurer les activités.';
  end if;

  if p_activity_types is null
     or cardinality(p_activity_types) = 0
     or not (p_activity_types <@ array[
       'commerce', 'restaurant', 'bakery', 'salon', 'garage',
       'workshop', 'transport', 'moving', 'delivery', 'event', 'other'
     ]::text[]) then
    raise exception 'Types d’activité invalides.';
  end if;

  if p_enabled_modules is null
     or cardinality(p_enabled_modules) = 0
     or not (p_enabled_modules <@ array[
       'commerce', 'pos', 'fast_food', 'appointments',
       'service_management', 'transport', 'delivery',
       'moving', 'production', 'event_management'
     ]::text[]) then
    raise exception 'Modules sélectionnés invalides.';
  end if;

  if cardinality(p_activity_types) <> (
    select count(distinct x) from unnest(p_activity_types) as x
  ) or cardinality(p_enabled_modules) <> (
    select count(distinct x) from unnest(p_enabled_modules) as x
  ) then
    raise exception 'Les activités et modules ne doivent pas être répétés.';
  end if;

  insert into public.shop_module_settings (
    shop_id, activity_types, enabled_modules, updated_at, updated_by
  )
  values (
    p_shop_id, p_activity_types, p_enabled_modules, now(), auth.uid()
  )
  on conflict (shop_id) do update
    set activity_types = excluded.activity_types,
        enabled_modules = excluded.enabled_modules,
        updated_at = now(),
        updated_by = auth.uid();

  select jsonb_build_object(
    'shop_id', cfg.shop_id,
    'activity_types', to_jsonb(cfg.activity_types),
    'enabled_modules', to_jsonb(cfg.enabled_modules),
    'marketplace_status', cfg.marketplace_status
  )
    into v_result
    from public.shop_module_settings cfg
   where cfg.shop_id = p_shop_id;

  return v_result;
end;
$$;

revoke all on function public.gurisha_get_shop_modules(uuid) from public, anon;
revoke all on function public.gurisha_save_shop_modules(uuid, text[], text[]) from public, anon;

grant execute on function public.gurisha_get_shop_modules(uuid) to authenticated;
grant execute on function public.gurisha_save_shop_modules(uuid, text[], text[]) to authenticated;
