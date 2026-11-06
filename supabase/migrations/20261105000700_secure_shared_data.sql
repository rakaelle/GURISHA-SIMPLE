-- GURISHA SIMPLE: contrôles de synchronisation selon le rôle.
-- À exécuter après 20261105000000_gurisha_shared_data.sql.

create or replace function public.gurisha_save_data(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_shop_id uuid;
  v_role text;
  v_old jsonb;
  v_old_product jsonb;
  v_new_product jsonb;
  v_id text;
  v_old_a numeric;
  v_old_b numeric;
  v_new_a numeric;
  v_new_b numeric;
  v_old_sold numeric;
  v_new_sold numeric;
  v_old_sales numeric;
  v_new_sales numeric;
  v_old_stock numeric;
  v_new_stock numeric;
begin
  select sm.shop_id, sm.role
    into v_shop_id, v_role
    from public.shop_members sm
   where sm.user_id = auth.uid()
   limit 1;

  if v_shop_id is null then
    raise exception 'Aucune boutique associée à ce compte.';
  end if;

  if p_payload is null
     or jsonb_typeof(p_payload) <> 'object'
     or jsonb_typeof(p_payload->'categories') <> 'array'
     or jsonb_typeof(p_payload->'products') <> 'array' then
    raise exception 'Données GURISHA invalides.';
  end if;

  select d.payload into v_old
    from public.gurisha_shop_data d
   where d.shop_id = v_shop_id
   for update;

  if v_old is null then
    if v_role <> 'owner' then
      raise exception 'Le propriétaire doit effectuer la première synchronisation.';
    end if;
  elsif v_role = 'cashier' then
    if p_payload->'categories' is distinct from v_old->'categories' then
      raise exception 'Le caissier ne peut pas modifier les catégories.';
    end if;

    if jsonb_array_length(p_payload->'products') < jsonb_array_length(v_old->'products') then
      raise exception 'Le caissier ne peut pas supprimer un article.';
    end if;

    for v_old_product in
      select value from jsonb_array_elements(v_old->'products')
    loop
      v_id := v_old_product->>'id';
      select value into v_new_product
        from jsonb_array_elements(p_payload->'products')
       where value->>'id' = v_id
       limit 1;

      if v_new_product is null then
        raise exception 'Le caissier ne peut pas supprimer un article.';
      end if;

      if (v_new_product->'name') is distinct from (v_old_product->'name')
         or (v_new_product->'format') is distinct from (v_old_product->'format')
         or (v_new_product->'container') is distinct from (v_old_product->'container')
         or (v_new_product->'category') is distinct from (v_old_product->'category')
         or (v_new_product->'initial') is distinct from (v_old_product->'initial')
         or (v_new_product->'buyPrice') is distinct from (v_old_product->'buyPrice')
         or (v_new_product->'sellPrice') is distinct from (v_old_product->'sellPrice') then
        raise exception 'Le caissier ne peut pas modifier les informations ou les prix d’un article existant.';
      end if;

      v_old_a := coalesce((v_old_product->>'lotA')::numeric, 0);
      v_old_b := coalesce((v_old_product->>'lotB')::numeric, 0);
      v_new_a := coalesce((v_new_product->>'lotA')::numeric, 0);
      v_new_b := coalesce((v_new_product->>'lotB')::numeric, 0);
      v_old_sold := coalesce((v_old_product->>'sold')::numeric, 0);
      v_new_sold := coalesce((v_new_product->>'sold')::numeric, 0);
      v_old_sales := coalesce((v_old_product->>'salesTotal')::numeric, 0);
      v_new_sales := coalesce((v_new_product->>'salesTotal')::numeric, 0);
      v_old_stock := v_old_a + v_old_b;
      v_new_stock := v_new_a + v_new_b;

      if not (
        (v_new_stock <= v_old_stock
          and v_new_sold - v_old_sold = v_old_stock - v_new_stock
          and v_new_sales >= v_old_sales)
        or
        (v_new_a = v_old_a
          and v_new_b >= v_old_b
          and v_new_sold = v_old_sold
          and v_new_sales = v_old_sales)
      ) then
        raise exception 'Modification de stock non autorisée pour le caissier.';
      end if;
    end loop;

    for v_new_product in
      select value
        from jsonb_array_elements(p_payload->'products')
    loop
      v_id := v_new_product->>'id';
      if not exists (
        select 1
          from jsonb_array_elements(v_old->'products') old_item
         where old_item->>'id' = v_id
      ) then
        if coalesce((v_new_product->>'initial')::numeric, 0) <> 0
           or coalesce((v_new_product->>'lotA')::numeric, 0) <> 0
           or coalesce((v_new_product->>'lotB')::numeric, 0) <> 0
           or coalesce((v_new_product->>'sold')::numeric, 0) <> 0
           or coalesce((v_new_product->>'salesTotal')::numeric, 0) <> 0 then
          raise exception 'Un nouvel article ajouté par le caissier doit commencer avec un stock nul.';
        end if;
      end if;
    end loop;
  end if;

  insert into public.gurisha_shop_data (shop_id, payload, updated_at)
  values (v_shop_id, p_payload, now())
  on conflict (shop_id)
  do update set payload = excluded.payload, updated_at = now();

  return jsonb_build_object('success', true);
end;
$$;

revoke all on function public.gurisha_save_data(jsonb) from public, anon;
grant execute on function public.gurisha_save_data(jsonb) to authenticated;
