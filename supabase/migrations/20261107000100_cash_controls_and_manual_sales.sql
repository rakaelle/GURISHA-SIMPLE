-- GURISHA SIMPLE : ventes manuelles horodatées et contrôles périodiques de caisse.
-- Les ventes du bouton « Vendre » et celles de la caisse POS alimentent le même historique.
-- Utiliser l'heure réelle d'insertion, pas l'heure de début de transaction, pour éviter les ventes
-- qui attendent le verrou de clôture d'être affectées à la mauvaise période.
alter table public.gurisha_sales alter column created_at set default clock_timestamp();

-- Reconstituer les anciennes ventes du bouton « Vendre » qui avaient modifié le stock
-- sans créer de ligne dans gurisha_sales. Les ventes POS déjà historisées sont soustraites.
do $backfill$
declare
  v_shop record;
  v_product jsonb;
  v_items jsonb;
  v_item jsonb;
  v_legacy_qty integer;
  v_legacy_amount numeric(14,2);
  v_total numeric(14,2);
  v_sale_id uuid;
begin
  for v_shop in select shop_id,payload from public.gurisha_shop_data loop
    v_items := '[]'::jsonb;
    v_total := 0;

    for v_product in
      select value from jsonb_array_elements(coalesce(v_shop.payload->'products','[]'::jsonb))
    loop
      select
        greatest(floor(coalesce((v_product->>'sold')::numeric,0) - coalesce((
          select sum(i.quantity)::numeric
            from public.gurisha_sale_items i
            join public.gurisha_sales s on s.id=i.sale_id
           where s.shop_id=v_shop.shop_id and i.product_id=v_product->>'id'
        ),0)),0)::integer,
        greatest(coalesce((v_product->>'salesTotal')::numeric,0) - coalesce((
          select sum(i.line_total)
            from public.gurisha_sale_items i
            join public.gurisha_sales s on s.id=i.sale_id
           where s.shop_id=v_shop.shop_id and i.product_id=v_product->>'id'
        ),0),0)
      into v_legacy_qty,v_legacy_amount;

      if v_legacy_qty > 0 then
        v_items := v_items || jsonb_build_array(jsonb_build_object(
          'product_id',v_product->>'id',
          'product_name',coalesce(v_product->>'name','Article'),
          'product_format',v_product->>'format',
          'quantity',v_legacy_qty,
          'unit_price',v_legacy_amount/v_legacy_qty,
          'line_total',v_legacy_amount
        ));
        v_total := v_total+v_legacy_amount;
      end if;
    end loop;

    if jsonb_array_length(v_items)>0 then
      v_sale_id := gen_random_uuid();
      insert into public.gurisha_sales(id,shop_id,total_amount,cash_received,change_due)
      values(v_sale_id,v_shop.shop_id,v_total,v_total,0);

      for v_item in select value from jsonb_array_elements(v_items)
      loop
        insert into public.gurisha_sale_items(
          sale_id,product_id,product_name,product_format,quantity,unit_price,line_total,
          quantity_from_lot_a,quantity_from_lot_b
        ) values (
          v_sale_id,v_item->>'product_id',v_item->>'product_name',v_item->>'product_format',
          (v_item->>'quantity')::integer,(v_item->>'unit_price')::numeric,
          (v_item->>'line_total')::numeric,0,0
        );
      end loop;
    end if;
  end loop;
end;
$backfill$;

create table if not exists public.gurisha_cash_controls (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  period_start timestamptz not null,
  opened_at timestamptz not null default now(),
  opened_by uuid references auth.users(id),
  opening_float numeric(14,2) not null check (opening_float >= 0),
  closed_at timestamptz,
  closed_by uuid references auth.users(id),
  total_sales numeric(14,2),
  sales_count integer,
  cash_collected numeric(14,2),
  closing_float numeric(14,2),
  expected_cash numeric(14,2),
  discrepancy numeric(14,2),
  status text not null default 'open' check (status in ('open','closed')),
  created_at timestamptz not null default now(),
  constraint gurisha_cash_controls_close_fields check (
    (status='open' and closed_at is null and cash_collected is null and closing_float is null)
    or
    (status='closed' and closed_at is not null and cash_collected is not null and closing_float is not null)
  )
);

create unique index if not exists gurisha_one_open_cash_control_per_shop
  on public.gurisha_cash_controls(shop_id) where status='open';
create index if not exists gurisha_cash_controls_shop_date_idx
  on public.gurisha_cash_controls(shop_id, closed_at desc);
alter table public.gurisha_cash_controls enable row level security;
revoke all on public.gurisha_cash_controls from public, anon, authenticated;

-- Saisie du bouton « Vendre » : stock, statistiques et historique sont modifiés dans une seule transaction.
create or replace function public.gurisha_record_manual_sale(
  p_product_id text, p_quantity integer, p_unit_price numeric, p_shop_id uuid
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_role text;
  v_payload jsonb;
  v_products jsonb;
  v_product jsonb;
  v_updated jsonb;
  v_idx integer;
  v_a integer;
  v_b integer;
  v_from_a integer;
  v_from_b integer;
  v_total numeric;
  v_sale_id uuid;
  v_name text;
  v_format text;
begin
  v_role := public.gurisha_require_shop_role(p_shop_id, array['owner','manager','gestionnaire','cashier','caissier']);
  if p_quantity is null or p_quantity < 1 or p_unit_price is null or p_unit_price < 0 then
    raise exception 'Quantité ou prix de vente invalide.';
  end if;

  select payload into v_payload
    from public.gurisha_shop_data
   where shop_id=p_shop_id
   for update;
  if v_payload is null then raise exception 'Données de la boutique introuvables.'; end if;

  v_products := v_payload->'products';
  select value, ordinality::integer into v_product, v_idx
    from jsonb_array_elements(v_products) with ordinality
   where value->>'id'=p_product_id limit 1;
  if v_product is null then raise exception 'Article introuvable.'; end if;

  if v_role in ('cashier','caissier')
     and p_unit_price <> coalesce((v_product->>'sellPrice')::numeric,0) then
    raise exception 'Le caissier ne peut pas modifier le prix de vente.';
  end if;

  v_a := greatest(coalesce((v_product->>'lotA')::integer,0),0);
  v_b := greatest(coalesce((v_product->>'lotB')::integer,0),0);
  if p_quantity > v_a+v_b then
    raise exception 'Stock insuffisant pour % (disponible : %).',v_product->>'name',v_a+v_b;
  end if;

  v_from_a := least(v_a,p_quantity);
  v_from_b := p_quantity-v_from_a;
  v_updated := jsonb_set(v_product,'{lotA}',to_jsonb(greatest(v_a-v_from_a,0)),true);
  v_updated := jsonb_set(v_updated,'{lotB}',to_jsonb(greatest(v_b-v_from_b,0)),true);
  v_updated := jsonb_set(v_updated,'{sold}',to_jsonb(coalesce((v_product->>'sold')::numeric,0)+p_quantity),true);
  v_total := p_quantity*p_unit_price;
  v_updated := jsonb_set(v_updated,'{salesTotal}',to_jsonb(coalesce((v_product->>'salesTotal')::numeric,0)+v_total),true);

  if greatest(v_a-v_from_a,0)=0 and greatest(v_b-v_from_b,0)>0 then
    v_updated := jsonb_set(v_updated,'{lotA}',to_jsonb(greatest(v_b-v_from_b,0)),true);
    v_updated := jsonb_set(v_updated,'{lotB}',to_jsonb(0),true);
  end if;

  v_products := jsonb_set(v_products,array[(v_idx-1)::text],v_updated,false);
  update public.gurisha_shop_data
     set payload=jsonb_set(v_payload,'{products}',v_products),updated_at=now()
   where shop_id=p_shop_id;

  v_sale_id := gen_random_uuid();
  v_name := coalesce(v_product->>'name','Article');
  v_format := v_product->>'format';
  insert into public.gurisha_sales(id,shop_id,total_amount,cash_received,change_due)
  values(v_sale_id,p_shop_id,v_total,v_total,0);
  insert into public.gurisha_sale_items(
    sale_id,product_id,product_name,product_format,quantity,unit_price,line_total,
    quantity_from_lot_a,quantity_from_lot_b
  ) values (
    v_sale_id,p_product_id,v_name,v_format,p_quantity,p_unit_price,v_total,v_from_a,v_from_b
  );

  return jsonb_build_object('success',true,'sale_id',v_sale_id,'total',v_total);
end;
$$;

-- Donne le résumé courant à l'équipe. Le détail de l'historique reste réservé au gestionnaire/propriétaire.
create or replace function public.gurisha_get_cash_control(p_shop_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_role text;
  v_shop_created timestamptz;
  v_open public.gurisha_cash_controls%rowtype;
  v_last public.gurisha_cash_controls%rowtype;
  v_period_start timestamptz;
  v_opening_float numeric(14,2);
  v_sales numeric(14,2);
  v_count integer;
  v_history jsonb := '[]'::jsonb;
begin
  v_role := public.gurisha_require_shop_role(p_shop_id,array['owner','manager','gestionnaire','cashier','caissier']);
  select created_at into v_shop_created from public.shops where id=p_shop_id;
  select * into v_open from public.gurisha_cash_controls
   where shop_id=p_shop_id and status='open' order by opened_at desc limit 1;
  select * into v_last from public.gurisha_cash_controls
   where shop_id=p_shop_id and status='closed' order by closed_at desc limit 1;

  if v_open.id is not null then
    v_period_start := v_open.period_start;
    v_opening_float := v_open.opening_float;
  else
    v_period_start := coalesce(v_last.closed_at,v_shop_created,now());
    v_opening_float := coalesce(v_last.closing_float,30000);
  end if;

  select coalesce(sum(total_amount),0),count(*)::integer
    into v_sales,v_count
    from public.gurisha_sales
   where shop_id=p_shop_id and created_at >= v_period_start;

  if v_role in ('owner','manager','gestionnaire') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',h.id,'period_start',h.period_start,'opened_at',h.opened_at,'closed_at',h.closed_at,
      'opening_float',h.opening_float,'total_sales',h.total_sales,'sales_count',h.sales_count,
      'cash_collected',h.cash_collected,'closing_float',h.closing_float,
      'expected_cash',h.expected_cash,'discrepancy',h.discrepancy
    ) order by h.closed_at desc),'[]'::jsonb)
    into v_history
    from (
      select * from public.gurisha_cash_controls
       where shop_id=p_shop_id and status='closed'
       order by closed_at desc limit 20
    ) h;
  end if;

  return jsonb_build_object(
    'open',case when v_open.id is null then null else jsonb_build_object(
      'id',v_open.id,'opened_at',v_open.opened_at,'period_start',v_open.period_start,
      'opening_float',v_open.opening_float
    ) end,
    'period_start',v_period_start,
    'opening_float',v_opening_float,
    'sales_total',v_sales,
    'sales_count',v_count,
    'last_closed_at',v_last.closed_at,
    'history',v_history
  );
end;
$$;

create or replace function public.gurisha_start_cash_control(p_shop_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_role text;
  v_payload jsonb;
  v_shop_created timestamptz;
  v_last public.gurisha_cash_controls%rowtype;
  v_existing public.gurisha_cash_controls%rowtype;
  v_period_start timestamptz;
  v_opening_float numeric(14,2);
  v_id uuid;
begin
  v_role := public.gurisha_require_shop_role(p_shop_id,array['owner','manager','gestionnaire']);
  -- Même verrou que les ventes : évite qu'une vente soit partiellement incluse/exclue au démarrage.
  select payload into v_payload from public.gurisha_shop_data where shop_id=p_shop_id for update;
  if v_payload is null then raise exception 'Données de la boutique introuvables.'; end if;

  select * into v_existing from public.gurisha_cash_controls
   where shop_id=p_shop_id and status='open' limit 1;
  if v_existing.id is not null then raise exception 'Un contrôle de caisse est déjà ouvert.'; end if;

  select created_at into v_shop_created from public.shops where id=p_shop_id;
  select * into v_last from public.gurisha_cash_controls
   where shop_id=p_shop_id and status='closed' order by closed_at desc limit 1;

  v_period_start := coalesce(v_last.closed_at,v_shop_created,now());
  v_opening_float := coalesce(v_last.closing_float,30000);

  insert into public.gurisha_cash_controls(shop_id,period_start,opened_by,opening_float)
  values(p_shop_id,v_period_start,auth.uid(),v_opening_float)
  returning id into v_id;

  return jsonb_build_object('success',true,'control_id',v_id,'period_start',v_period_start,'opening_float',v_opening_float);
end;
$$;

create or replace function public.gurisha_close_cash_control(
  p_shop_id uuid,p_cash_collected numeric,p_closing_float numeric
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_role text;
  v_payload jsonb;
  v_control public.gurisha_cash_controls%rowtype;
  v_closed_at timestamptz;
  v_sales numeric(14,2);
  v_count integer;
  v_expected numeric(14,2);
  v_discrepancy numeric(14,2);
begin
  v_role := public.gurisha_require_shop_role(p_shop_id,array['owner','manager','gestionnaire']);
  if p_cash_collected is null or p_cash_collected<0 or p_closing_float is null or p_closing_float<0 then
    raise exception 'Les montants saisis doivent être positifs ou nuls.';
  end if;

  -- Le verrouillage du stock sérialise la clôture avec toutes les ventes POS et les ventes manuelles.
  select payload into v_payload from public.gurisha_shop_data where shop_id=p_shop_id for update;
  if v_payload is null then raise exception 'Données de la boutique introuvables.'; end if;

  select * into v_control from public.gurisha_cash_controls
   where shop_id=p_shop_id and status='open' for update;
  if not found then raise exception 'Aucun contrôle de caisse ouvert.'; end if;

  v_closed_at := clock_timestamp();
  select coalesce(sum(total_amount),0),count(*)::integer
    into v_sales,v_count
    from public.gurisha_sales
   where shop_id=p_shop_id
     and created_at >= v_control.period_start
     and created_at <= v_closed_at;

  v_expected := v_control.opening_float+v_sales;
  v_discrepancy := (p_cash_collected+p_closing_float)-v_expected;

  update public.gurisha_cash_controls
     set closed_at=v_closed_at,closed_by=auth.uid(),total_sales=v_sales,sales_count=v_count,
         cash_collected=p_cash_collected,closing_float=p_closing_float,
         expected_cash=v_expected,discrepancy=v_discrepancy,status='closed'
   where id=v_control.id;

  return jsonb_build_object(
    'success',true,'control_id',v_control.id,'period_start',v_control.period_start,
    'closed_at',v_closed_at,'opening_float',v_control.opening_float,
    'sales_total',v_sales,'sales_count',v_count,'expected_cash',v_expected,
    'cash_collected',p_cash_collected,'closing_float',p_closing_float,
    'counted_cash',p_cash_collected+p_closing_float,'discrepancy',v_discrepancy
  );
end;
$$;

revoke all on function public.gurisha_record_manual_sale(text,integer,numeric,uuid) from public,anon;
revoke all on function public.gurisha_get_cash_control(uuid) from public,anon;
revoke all on function public.gurisha_start_cash_control(uuid) from public,anon;
revoke all on function public.gurisha_close_cash_control(uuid,numeric,numeric) from public,anon;
grant execute on function public.gurisha_record_manual_sale(text,integer,numeric,uuid) to authenticated;
grant execute on function public.gurisha_get_cash_control(uuid) to authenticated;
grant execute on function public.gurisha_start_cash_control(uuid) to authenticated;
grant execute on function public.gurisha_close_cash_control(uuid,numeric,numeric) to authenticated;
