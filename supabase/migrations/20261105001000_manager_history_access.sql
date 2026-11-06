-- Autoriser le propriétaire et le gestionnaire à consulter les historiques.
create or replace function public.gurisha_list_sales()
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
  select sm.shop_id, sm.role into v_shop_id, v_role
    from public.shop_members sm where sm.user_id=auth.uid() limit 1;
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

create or replace function public.gurisha_list_purchases()
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
  select shop_id, role into v_shop_id, v_role
    from public.shop_members where user_id=auth.uid() limit 1;
  if v_shop_id is null or v_role not in ('owner','manager','gestionnaire') then
    raise exception 'Historique réservé au propriétaire et au gestionnaire.';
  end if;
  return query
  select p.id,p.created_at,p.product_id,p.product_name,p.quantity,p.unit_cost,p.total_cost
    from public.gurisha_purchases p
   where p.shop_id=v_shop_id order by p.created_at desc;
end;
$$;

revoke all on function public.gurisha_list_sales() from public, anon;
revoke all on function public.gurisha_list_purchases() from public, anon;
grant execute on function public.gurisha_list_sales() to authenticated;
grant execute on function public.gurisha_list_purchases() to authenticated;
