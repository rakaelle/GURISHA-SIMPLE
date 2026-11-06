-- GURISHA SIMPLE : support multi-boutiques avec contrôle strict de l'accès.
create or replace function public.gurisha_require_shop_role(p_shop_id uuid, p_roles text[])
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_role text;
begin
 if auth.uid() is null or p_shop_id is null then raise exception 'Connexion ou boutique requise.'; end if;
 select role into v_role from public.shop_members where user_id=auth.uid() and shop_id=p_shop_id;
 if v_role is null or not (v_role = any(p_roles)) then raise exception 'Vous n’avez pas accès à cette boutique.'; end if;
 return v_role;
end; $$;
revoke all on function public.gurisha_require_shop_role(uuid,text[]) from public,anon;
grant execute on function public.gurisha_require_shop_role(uuid,text[]) to authenticated;

create or replace function public.gurisha_get_data(p_shop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop_id uuid;
  v_payload jsonb;
begin
  perform public.gurisha_require_shop_role(p_shop_id, array['owner','manager','cashier','gestionnaire','caissier']);
  v_shop_id := p_shop_id;

  if v_shop_id is null then
    raise exception 'Aucune boutique associée à ce compte.';
  end if;

  select d.payload
    into v_payload
    from public.gurisha_shop_data d
   where d.shop_id = v_shop_id;

  return v_payload;
end;
$$;

create or replace function public.gurisha_save_data(p_payload jsonb, p_shop_id uuid)
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
  v_role := public.gurisha_require_shop_role(p_shop_id, array['owner','manager','cashier','gestionnaire','caissier']);
  v_shop_id := p_shop_id;

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

create or replace function public.gurisha_checkout(p_items jsonb, p_cash_received numeric, p_shop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_shop_id uuid;
  v_role text;
  v_payload jsonb;
  v_products jsonb;
  v_item jsonb;
  v_product jsonb;
  v_updated jsonb;
  v_idx integer;
  v_product_id text;
  v_qty integer;
  v_stock_a integer;
  v_stock_b integer;
  v_from_a integer;
  v_from_b integer;
  v_price numeric;
  v_line_total numeric;
  v_total numeric := 0;
  v_sale_id uuid;
  v_name text;
  v_format text;
  v_seen text[] := array[]::text[];
begin
  v_role := public.gurisha_require_shop_role(p_shop_id, array['owner','manager','gestionnaire','cashier','caissier']);
  v_shop_id := p_shop_id;

  if v_shop_id is null then raise exception 'Aucune boutique associée à ce compte.'; end if;
  if v_role not in ('owner','manager','gestionnaire','cashier') then
    raise exception 'Rôle non autorisé pour la caisse.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Le panier est vide.';
  end if;
  if p_cash_received is null or p_cash_received < 0 then
    raise exception 'Montant reçu invalide.';
  end if;

  select d.payload into v_payload
    from public.gurisha_shop_data d where d.shop_id = v_shop_id for update;
  if v_payload is null then raise exception 'Données de la boutique introuvables.'; end if;
  v_products := v_payload->'products';

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := v_item->>'product_id';
    if v_product_id is null or v_product_id = '' or v_product_id = any(v_seen) then
      raise exception 'Article invalide ou présent plusieurs fois dans le panier.';
    end if;
    v_seen := array_append(v_seen, v_product_id);
    v_qty := (v_item->>'quantity')::integer;
    if v_qty is null or v_qty < 1 then raise exception 'Quantité invalide.'; end if;

    v_product := null;
    v_idx := null;
    select value, ordinality::integer into v_product, v_idx
      from jsonb_array_elements(v_products) with ordinality
     where value->>'id' = v_product_id limit 1;
    if v_product is null then raise exception 'Un article du panier n’existe plus.'; end if;

    v_stock_a := greatest(coalesce((v_product->>'lotA')::integer,0),0);
    v_stock_b := greatest(coalesce((v_product->>'lotB')::integer,0),0);
    if v_qty > v_stock_a + v_stock_b then
      raise exception 'Stock insuffisant pour % (disponible : %).', v_product->>'name', v_stock_a + v_stock_b;
    end if;

    v_from_a := least(v_stock_a, v_qty);
    v_from_b := v_qty - v_from_a;
    v_price := coalesce((v_product->>'sellPrice')::numeric,0);
    v_line_total := v_qty * v_price;
    v_total := v_total + v_line_total;
    v_name := coalesce(v_product->>'name','Article');
    v_format := v_product->>'format';

    v_updated := jsonb_set(
      jsonb_set(
        jsonb_set(v_product, '{lotA}', to_jsonb(greatest(v_stock_a-v_from_a,0))),
        '{lotB}', to_jsonb(greatest(v_stock_b-v_from_b,0))
      ),
      '{sold}', to_jsonb(coalesce((v_product->>'sold')::numeric,0)+v_qty), true
    );
    v_updated := jsonb_set(v_updated, '{salesTotal}',
      to_jsonb(coalesce((v_product->>'salesTotal')::numeric,0)+v_line_total), true);

    if greatest(v_stock_a-v_from_a,0)=0 and greatest(v_stock_b-v_from_b,0)>0 then
      v_updated := jsonb_set(v_updated, '{lotA}', to_jsonb(greatest(v_stock_b-v_from_b,0)));
      v_updated := jsonb_set(v_updated, '{lotB}', to_jsonb(0));
    end if;
    v_products := jsonb_set(v_products, array[(v_idx-1)::text], v_updated, false);
  end loop;

  if p_cash_received < v_total then
    raise exception 'Montant insuffisant. Total à payer : % FBu.', v_total;
  end if;

  v_sale_id := gen_random_uuid();
  insert into public.gurisha_sales(id, shop_id, total_amount, cash_received, change_due)
  values (v_sale_id, v_shop_id, v_total, p_cash_received, p_cash_received-v_total);

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := v_item->>'product_id';
    v_qty := (v_item->>'quantity')::integer;
    select value into v_product from jsonb_array_elements(v_payload->'products')
      where value->>'id'=v_product_id limit 1;
    v_stock_a := greatest(coalesce((v_product->>'lotA')::integer,0),0);
    v_stock_b := greatest(coalesce((v_product->>'lotB')::integer,0),0);
    v_from_a := least(v_stock_a,v_qty);
    v_from_b := v_qty-v_from_a;
    v_price := coalesce((v_product->>'sellPrice')::numeric,0);
    insert into public.gurisha_sale_items(
      sale_id, product_id, product_name, product_format, quantity,
      unit_price, line_total, quantity_from_lot_a, quantity_from_lot_b
    ) values (
      v_sale_id, v_product_id, coalesce(v_product->>'name','Article'),
      v_product->>'format', v_qty, v_price, v_qty*v_price, v_from_a, v_from_b
    );
  end loop;

  update public.gurisha_shop_data
     set payload = jsonb_set(v_payload, '{products}', v_products), updated_at = now()
   where shop_id = v_shop_id;

  return jsonb_build_object(
    'sale_id', v_sale_id, 'total', v_total,
    'cash_received', p_cash_received, 'change_due', p_cash_received-v_total
  );
end;
$$;

create or replace function public.gurisha_cancel_sale(p_sale_id uuid, p_shop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_shop_id uuid;
  v_role text;
  v_sale public.gurisha_sales%rowtype;
  v_payload jsonb;
  v_products jsonb;
  v_item record;
  v_product jsonb;
  v_updated jsonb;
  v_idx integer;
  v_a integer;
  v_b integer;
  v_sold numeric;
  v_sales numeric;
begin
  v_role := public.gurisha_require_shop_role(p_shop_id, array['owner','manager','gestionnaire','cashier','caissier']);
  v_shop_id := p_shop_id;
  if v_shop_id is null or v_role not in ('owner','manager','gestionnaire','cashier') then
    raise exception 'Vous n’êtes pas autorisé à annuler une vente.';
  end if;

  select * into v_sale from public.gurisha_sales
   where id=p_sale_id and shop_id=v_shop_id for update;
  if not found then raise exception 'Cette vente est introuvable ou déjà supprimée.'; end if;

  select payload into v_payload from public.gurisha_shop_data
   where shop_id=v_shop_id for update;
  if v_payload is null then raise exception 'Données de stock introuvables.'; end if;
  v_products := v_payload->'products';

  for v_item in
    select product_id, quantity, line_total
      from public.gurisha_sale_items where sale_id=p_sale_id
  loop
    select value, ordinality::integer into v_product, v_idx
      from jsonb_array_elements(v_products) with ordinality
     where value->>'id'=v_item.product_id limit 1;
    if v_product is null then
      raise exception 'Impossible de restaurer le stock : article % introuvable.', v_item.product_id;
    end if;

    v_a := coalesce((v_product->>'lotA')::integer,0);
    v_b := coalesce((v_product->>'lotB')::integer,0);
    v_sold := coalesce((v_product->>'sold')::numeric,0);
    v_sales := coalesce((v_product->>'salesTotal')::numeric,0);
    v_updated := jsonb_set(v_product, '{lotA}', to_jsonb(v_a+v_item.quantity), true);
    v_updated := jsonb_set(v_updated, '{sold}', to_jsonb(greatest(v_sold-v_item.quantity,0)), true);
    v_updated := jsonb_set(v_updated, '{salesTotal}', to_jsonb(greatest(v_sales-v_item.line_total,0)), true);
    v_products := jsonb_set(v_products, array[(v_idx-1)::text], v_updated, false);
  end loop;

  update public.gurisha_shop_data
     set payload=jsonb_set(v_payload,'{products}',v_products), updated_at=now()
   where shop_id=v_shop_id;

  delete from public.gurisha_sales where id=p_sale_id and shop_id=v_shop_id;
  return jsonb_build_object('success',true,'deleted_sale_id',p_sale_id);
end;
$$;

create or replace function public.gurisha_list_sales(p_shop_id uuid)
returns table (
  id uuid,
  created_at timestamptz,
  total_amount numeric,
  cash_received numeric,
  change_due numeric,
  items jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_shop_id uuid;
  v_role text;
begin
  v_role := public.gurisha_require_shop_role(p_shop_id, array['owner','manager','gestionnaire']);
  v_shop_id := p_shop_id;
  if v_shop_id is null or v_role not in ('owner','manager','gestionnaire') then
    raise exception 'Historique réservé au propriétaire et au gestionnaire.';
  end if;

  return query
  select s.id, s.created_at, s.total_amount, s.cash_received, s.change_due,
         coalesce((
           select jsonb_agg(jsonb_build_object(
             'product_name',i.product_name,'product_format',i.product_format,
             'quantity',i.quantity,'unit_price',i.unit_price,'line_total',i.line_total
           ) order by i.id)
           from public.gurisha_sale_items i where i.sale_id=s.id
         ),'[]'::jsonb)
    from public.gurisha_sales s
   where s.shop_id=v_shop_id
   order by s.created_at desc;
end;
$$;

create or replace function public.gurisha_record_purchase(
  p_product_id text, p_quantity integer, p_unit_cost numeric, p_shop_id uuid
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_shop_id uuid;
  v_role text;
  v_payload jsonb;
  v_products jsonb;
  v_product jsonb;
  v_updated jsonb;
  v_idx integer;
  v_name text;
  v_total numeric;
begin
  v_role := public.gurisha_require_shop_role(p_shop_id, array['owner','manager','gestionnaire','cashier','caissier']);
  v_shop_id := p_shop_id;
  if v_shop_id is null or v_role not in ('owner','manager','gestionnaire','cashier','caissier') then
    raise exception 'Vous n’êtes pas autorisé à enregistrer un achat.';
  end if;
  if p_product_id is null or p_product_id='' or p_quantity is null or p_quantity<1
     or p_unit_cost is null or p_unit_cost<0 then
    raise exception 'Quantité ou prix d’achat invalide.';
  end if;

  select payload into v_payload from public.gurisha_shop_data
   where shop_id=v_shop_id for update;
  if v_payload is null then raise exception 'Données de la boutique introuvables.'; end if;
  v_products := v_payload->'products';
  select value, ordinality::integer into v_product, v_idx
    from jsonb_array_elements(v_products) with ordinality
   where value->>'id'=p_product_id limit 1;
  if v_product is null then raise exception 'Article introuvable.'; end if;

  v_name := coalesce(v_product->>'name','Article');
  v_total := p_quantity*p_unit_cost;
  v_updated := jsonb_set(v_product,'{lotB}',
    to_jsonb(coalesce((v_product->>'lotB')::integer,0)+p_quantity),true);
  v_updated := jsonb_set(v_updated,'{buyPrice}',to_jsonb(p_unit_cost),true);
  v_products := jsonb_set(v_products,array[(v_idx-1)::text],v_updated,false);

  insert into public.gurisha_purchases(shop_id,product_id,product_name,quantity,unit_cost,total_cost)
  values(v_shop_id,p_product_id,v_name,p_quantity,p_unit_cost,v_total);

  update public.gurisha_shop_data
     set payload=jsonb_set(v_payload,'{products}',v_products),updated_at=now()
   where shop_id=v_shop_id;
  return jsonb_build_object('success',true,'product_name',v_name,'quantity',p_quantity,'total_cost',v_total);
end;
$$;

create or replace function public.gurisha_list_purchases(p_shop_id uuid)
returns table (
  id bigint, created_at timestamptz, product_id text, product_name text,
  quantity integer, unit_cost numeric, total_cost numeric
)
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_shop_id uuid;
  v_role text;
begin
  v_role := public.gurisha_require_shop_role(p_shop_id, array['owner','manager','gestionnaire']);
  v_shop_id := p_shop_id;
  if v_shop_id is null or v_role not in ('owner','manager','gestionnaire') then
    raise exception 'Historique réservé au propriétaire et au gestionnaire.';
  end if;
  return query
  select p.id,p.created_at,p.product_id,p.product_name,p.quantity,p.unit_cost,p.total_cost
    from public.gurisha_purchases p
   where p.shop_id=v_shop_id order by p.created_at desc;
end;
$$;

create or replace function public.gurisha_reset_test_data(p_shop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_shop_id uuid;
  v_role text;
  v_payload jsonb;
  v_product_count integer := 0;
  v_sales_count integer := 0;
  v_purchases_count integer := 0;
begin
  v_role := public.gurisha_require_shop_role(p_shop_id, array['owner']);
  v_shop_id := p_shop_id;

  if v_shop_id is null or v_role <> 'owner' then
    raise exception 'Seul le propriétaire peut réinitialiser les données de test.';
  end if;

  select d.payload into v_payload
    from public.gurisha_shop_data d
   where d.shop_id = v_shop_id
   for update;

  if v_payload is null then
    raise exception 'Données de la boutique introuvables.';
  end if;

  v_product_count := jsonb_array_length(coalesce(v_payload->'products', '[]'::jsonb));

  delete from public.gurisha_sales
   where shop_id = v_shop_id;
  get diagnostics v_sales_count = row_count;

  delete from public.gurisha_purchases
   where shop_id = v_shop_id;
  get diagnostics v_purchases_count = row_count;

  update public.gurisha_shop_data
     set payload = jsonb_set(v_payload, '{products}', '[]'::jsonb, true),
         updated_at = now()
   where shop_id = v_shop_id;

  return jsonb_build_object(
    'success', true,
    'deleted_products', v_product_count,
    'deleted_sales', v_sales_count,
    'deleted_purchases', v_purchases_count
  );
end;
$$;
-- Les anciennes signatures sont désactivées pour empêcher tout choix implicite de boutique.
revoke all on function public.gurisha_get_data() from public,anon,authenticated;
revoke all on function public.gurisha_save_data(jsonb) from public,anon,authenticated;
revoke all on function public.gurisha_checkout(jsonb,numeric) from public,anon,authenticated;
revoke all on function public.gurisha_cancel_sale(uuid) from public,anon,authenticated;
revoke all on function public.gurisha_list_sales() from public,anon,authenticated;
revoke all on function public.gurisha_record_purchase(text,integer,numeric) from public,anon,authenticated;
revoke all on function public.gurisha_list_purchases() from public,anon,authenticated;
revoke all on function public.gurisha_reset_test_data() from public,anon,authenticated;
revoke all on function public.gurisha_get_data(uuid) from public,anon;
revoke all on function public.gurisha_save_data(jsonb,uuid) from public,anon;
revoke all on function public.gurisha_checkout(jsonb,numeric,uuid) from public,anon;
revoke all on function public.gurisha_cancel_sale(uuid,uuid) from public,anon;
revoke all on function public.gurisha_list_sales(uuid) from public,anon;
revoke all on function public.gurisha_record_purchase(text,integer,numeric,uuid) from public,anon;
revoke all on function public.gurisha_list_purchases(uuid) from public,anon;
revoke all on function public.gurisha_reset_test_data(uuid) from public,anon;
grant execute on function public.gurisha_get_data(uuid) to authenticated;
grant execute on function public.gurisha_save_data(jsonb,uuid) to authenticated;
grant execute on function public.gurisha_checkout(jsonb,numeric,uuid) to authenticated;
grant execute on function public.gurisha_cancel_sale(uuid,uuid) to authenticated;
grant execute on function public.gurisha_list_sales(uuid) to authenticated;
grant execute on function public.gurisha_record_purchase(text,integer,numeric,uuid) to authenticated;
grant execute on function public.gurisha_list_purchases(uuid) to authenticated;
grant execute on function public.gurisha_reset_test_data(uuid) to authenticated;
