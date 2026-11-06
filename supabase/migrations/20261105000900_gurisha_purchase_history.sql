-- GURISHA SIMPLE : journal des achats de stock.
-- À exécuter dans Supabase SQL Editor après les migrations précédentes.

create table if not exists public.gurisha_purchases (
  id bigint generated always as identity primary key,
  shop_id uuid not null,
  created_at timestamptz not null default now(),
  product_id text not null,
  product_name text not null,
  quantity integer not null check (quantity > 0),
  unit_cost numeric(14,2) not null check (unit_cost >= 0),
  total_cost numeric(14,2) not null check (total_cost >= 0)
);
create index if not exists gurisha_purchases_shop_created_idx
  on public.gurisha_purchases(shop_id, created_at desc);
alter table public.gurisha_purchases enable row level security;
revoke all on public.gurisha_purchases from anon, authenticated;

create or replace function public.gurisha_record_purchase(
  p_product_id text, p_quantity integer, p_unit_cost numeric
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
  select shop_id, role into v_shop_id, v_role
    from public.shop_members where user_id=auth.uid() limit 1;
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
  if v_shop_id is null or v_role<>'owner' then
    raise exception 'Seul le propriétaire peut consulter l’historique des achats.';
  end if;
  return query
  select p.id,p.created_at,p.product_id,p.product_name,p.quantity,p.unit_cost,p.total_cost
    from public.gurisha_purchases p
   where p.shop_id=v_shop_id order by p.created_at desc;
end;
$$;

revoke all on function public.gurisha_record_purchase(text,integer,numeric) from public,anon;
revoke all on function public.gurisha_list_purchases() from public,anon;
grant execute on function public.gurisha_record_purchase(text,integer,numeric) to authenticated;
grant execute on function public.gurisha_list_purchases() to authenticated;
