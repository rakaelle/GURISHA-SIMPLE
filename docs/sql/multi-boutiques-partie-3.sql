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

