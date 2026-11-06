-- GURISHA SIMPLE : caisse multi-articles, paiement en espèces et annulation atomique.
-- À exécuter dans Supabase > SQL Editor après les migrations précédentes.
-- Les ventes annulées sont supprimées définitivement et le stock est restauré dans la même transaction.

create table if not exists public.gurisha_sales (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null,
  created_at timestamptz not null default now(),
  total_amount numeric(14,2) not null check (total_amount >= 0),
  cash_received numeric(14,2) not null check (cash_received >= total_amount),
  change_due numeric(14,2) not null check (change_due = cash_received - total_amount)
);

create table if not exists public.gurisha_sale_items (
  id bigint generated always as identity primary key,
  sale_id uuid not null references public.gurisha_sales(id) on delete cascade,
  product_id text not null,
  product_name text not null,
  product_format text,
  quantity integer not null check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  line_total numeric(14,2) not null check (line_total >= 0),
  quantity_from_lot_a integer not null default 0,
  quantity_from_lot_b integer not null default 0
);

create index if not exists gurisha_sales_shop_created_idx
  on public.gurisha_sales(shop_id, created_at desc);
create index if not exists gurisha_sale_items_sale_idx
  on public.gurisha_sale_items(sale_id);

alter table public.gurisha_sales enable row level security;
alter table public.gurisha_sale_items enable row level security;
revoke all on public.gurisha_sales, public.gurisha_sale_items from anon, authenticated;

create or replace function public.gurisha_checkout(p_items jsonb, p_cash_received numeric)
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
  select sm.shop_id, sm.role into v_shop_id, v_role
    from public.shop_members sm where sm.user_id = auth.uid() limit 1;

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

create or replace function public.gurisha_cancel_sale(p_sale_id uuid)
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
  select sm.shop_id, sm.role into v_shop_id, v_role
    from public.shop_members sm where sm.user_id = auth.uid() limit 1;
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
  if v_shop_id is null or v_role <> 'owner' then
    raise exception 'Seul le propriétaire peut consulter l’historique complet des ventes.';
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

revoke all on function public.gurisha_checkout(jsonb,numeric) from public, anon;
revoke all on function public.gurisha_cancel_sale(uuid) from public, anon;
revoke all on function public.gurisha_list_sales() from public, anon;
grant execute on function public.gurisha_checkout(jsonb,numeric) to authenticated;
grant execute on function public.gurisha_cancel_sale(uuid) to authenticated;
grant execute on function public.gurisha_list_sales() to authenticated;
