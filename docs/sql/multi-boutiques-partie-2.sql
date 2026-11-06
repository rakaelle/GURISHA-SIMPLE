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

