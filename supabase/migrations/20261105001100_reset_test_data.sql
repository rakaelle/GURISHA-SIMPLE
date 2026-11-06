-- Nettoyage initial des données fictives de GURISHA.
-- Réservé au propriétaire : supprime les articles, ventes et achats de la boutique.
-- Les catégories, comptes employés et paramètres de boutique sont conservés.

create or replace function public.gurisha_reset_test_data()
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
  select sm.shop_id, sm.role into v_shop_id, v_role
    from public.shop_members sm
   where sm.user_id = auth.uid()
   limit 1;

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

revoke all on function public.gurisha_reset_test_data() from public, anon;
grant execute on function public.gurisha_reset_test_data() to authenticated;
