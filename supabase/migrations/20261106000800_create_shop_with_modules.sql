-- GURISHA: création atomique d'une boutique avec ses activités et modules.
-- La fonction historique create_shop_for_current_user reste disponible pour les anciens parcours.
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
       'transport','moving','delivery','event','other'
     ]::text[]) then
    raise exception 'Sélectionnez au moins une activité valide.';
  end if;
  if p_enabled_modules is null or cardinality(p_enabled_modules) = 0
     or not (p_enabled_modules <@ array[
       'commerce','pos','fast_food','appointments','service_management',
       'transport','delivery','moving','production','event_management'
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

revoke all on function public.create_shop_for_current_user_with_modules(text, text[], text[]) from public, anon;
grant execute on function public.create_shop_for_current_user_with_modules(text, text[], text[]) to authenticated;
