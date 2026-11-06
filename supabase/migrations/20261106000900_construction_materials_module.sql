-- GURISHA: ajouter l'activité matériaux de construction et son module dédié.
-- Migration additive : aucune table métier ni donnée existante n'est modifiée.

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
    select 1 from public.shop_members sm
     where sm.shop_id = p_shop_id
       and sm.user_id = auth.uid()
       and sm.role = 'owner'
  ) then
    raise exception 'Seul le propriétaire peut configurer les activités.';
  end if;

  if p_activity_types is null or cardinality(p_activity_types) = 0
     or not (p_activity_types <@ array[
       'commerce','restaurant','bakery','salon','garage','workshop',
       'transport','moving','delivery','event','construction_materials','other'
     ]::text[]) then
    raise exception 'Types d’activité invalides.';
  end if;

  if p_enabled_modules is null or cardinality(p_enabled_modules) = 0
     or not (p_enabled_modules <@ array[
       'commerce','pos','fast_food','appointments','service_management',
       'transport','delivery','moving','production','event_management',
       'construction_materials_delivery'
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
  values (p_shop_id, p_activity_types, p_enabled_modules, now(), auth.uid())
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
  ) into v_result
    from public.shop_module_settings cfg
   where cfg.shop_id = p_shop_id;

  return v_result;
end;
$$;

create or replace function public.create_shop_for_current_user_with_modules(
  p_name text,
  p_activity_types text[],
  p_enabled_modules text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_shop_id uuid;
  v_name text := trim(coalesce(p_name, ''));
begin
  if v_user is null then
    raise exception 'Connexion requise.';
  end if;
  if length(v_name) < 2 or length(v_name) > 100 then
    raise exception 'Le nom doit contenir entre 2 et 100 caractères.';
  end if;
  if p_activity_types is null or cardinality(p_activity_types) = 0
     or not (p_activity_types <@ array[
       'commerce','restaurant','bakery','salon','garage','workshop',
       'transport','moving','delivery','event','construction_materials','other'
     ]::text[]) then
    raise exception 'Sélectionnez au moins une activité valide.';
  end if;
  if p_enabled_modules is null or cardinality(p_enabled_modules) = 0
     or not (p_enabled_modules <@ array[
       'commerce','pos','fast_food','appointments','service_management',
       'transport','delivery','moving','production','event_management',
       'construction_materials_delivery'
     ]::text[]) then
    raise exception 'Sélectionnez au moins un module valide.';
  end if;
  if cardinality(p_activity_types) <> (select count(distinct x) from unnest(p_activity_types) as x)
     or cardinality(p_enabled_modules) <> (select count(distinct x) from unnest(p_enabled_modules) as x) then
    raise exception 'Les choix ne doivent pas être répétés.';
  end if;

  insert into public.shops(name, owner_id, currency)
  values (v_name, v_user, 'FBu')
  returning id into v_shop_id;

  insert into public.shop_members(shop_id, user_id, role)
  values (v_shop_id, v_user, 'owner');

  insert into public.shop_module_settings(
    shop_id, activity_types, enabled_modules, marketplace_status, updated_by
  )
  values (v_shop_id, p_activity_types, p_enabled_modules, 'not_requested', v_user);

  return v_shop_id;
end;
$$;

revoke all on function public.gurisha_save_shop_modules(uuid, text[], text[]) from public, anon;
grant execute on function public.gurisha_save_shop_modules(uuid, text[], text[]) to authenticated;
revoke all on function public.create_shop_for_current_user_with_modules(text, text[], text[]) from public, anon;
grant execute on function public.create_shop_for_current_user_with_modules(text, text[], text[]) to authenticated;
