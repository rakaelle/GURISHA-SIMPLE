-- GURISHA — Stock et matériaux du salon (migration additive)
create table if not exists public.salon_products (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops(id) on delete cascade,
 name text not null,
 category text not null default 'Autres',
 usage_type text not null check (usage_type in ('sale','consumable','both','equipment')),
 unit text not null default 'unité',
 purchase_price numeric(14,2) not null default 0 check (purchase_price>=0),
 sale_price numeric(14,2) not null default 0 check (sale_price>=0),
 stock_quantity numeric(14,3) not null default 0 check (stock_quantity>=0),
 min_stock numeric(14,3) not null default 0 check (min_stock>=0),
 media_items jsonb not null default '[]'::jsonb check (jsonb_typeof(media_items)='array'),
 is_active boolean not null default true,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists salon_products_shop_idx on public.salon_products(shop_id,is_active,name);
create table if not exists public.salon_stock_movements (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops(id) on delete cascade,
 product_id uuid not null references public.salon_products(id) on delete restrict,
 movement_type text not null check (movement_type in ('purchase','consumption','sale','adjustment')),
 quantity numeric(14,3) not null check (quantity>0),
 unit_cost numeric(14,2) not null default 0 check (unit_cost>=0),
 note text,
 appointment_id uuid references public.salon_appointments(id) on delete set null,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now()
);
create index if not exists salon_stock_movements_shop_date_idx on public.salon_stock_movements(shop_id,created_at desc);
alter table public.salon_products enable row level security;
alter table public.salon_stock_movements enable row level security;
drop policy if exists salon_products_read on public.salon_products;
create policy salon_products_read on public.salon_products for select to authenticated
using (public.gurisha_has_shop_access(shop_id,array['receptionist','hairdresser','beautician']));
drop policy if exists salon_products_manage on public.salon_products;
create policy salon_products_manage on public.salon_products for all to authenticated
using (public.gurisha_has_shop_access(shop_id,array[]::text[]))
with check (public.gurisha_has_shop_access(shop_id,array[]::text[]));
drop policy if exists salon_stock_movements_read on public.salon_stock_movements;
create policy salon_stock_movements_read on public.salon_stock_movements for select to authenticated
using (public.gurisha_has_shop_access(shop_id,array[]::text[]));
drop policy if exists salon_stock_movements_manage on public.salon_stock_movements;
create policy salon_stock_movements_manage on public.salon_stock_movements for all to authenticated
using (public.gurisha_has_shop_access(shop_id,array[]::text[]))
with check (public.gurisha_has_shop_access(shop_id,array[]::text[]));
grant select,insert,update,delete on public.salon_products to authenticated;
grant select,insert,update,delete on public.salon_stock_movements to authenticated;

-- Enregistrer les mouvements et recalculer le stock dans une transaction atomique.
create or replace function public.gurisha_salon_stock_move(
 p_product_id uuid,p_movement_type text,p_quantity numeric,p_unit_cost numeric default 0,
 p_note text default null,p_appointment_id uuid default null
) returns void language plpgsql security definer set search_path=public as $$
declare v_product public.salon_products%rowtype; v_delta numeric;
begin
 if p_movement_type not in ('purchase','consumption','sale','adjustment') or p_quantity<=0 then
  raise exception 'Mouvement ou quantité invalide.';
 end if;
 select * into v_product from public.salon_products where id=p_product_id for update;
 if not found then raise exception 'Article introuvable.'; end if;
 if not public.gurisha_has_shop_access(v_product.shop_id,array[]::text[]) then
  raise exception 'Accès non autorisé à ce stock.';
 end if;
 if v_product.usage_type='equipment' and p_movement_type in ('consumption','sale') then
  raise exception 'Un équipement durable ne peut pas être consommé ou vendu depuis ce mouvement.';
 end if;
 v_delta:=case when p_movement_type='purchase' then p_quantity when p_movement_type='adjustment' then p_quantity else -p_quantity end;
 if v_product.stock_quantity+v_delta<0 then raise exception 'Stock insuffisant.'; end if;
 update public.salon_products set stock_quantity=stock_quantity+v_delta,
  purchase_price=case when p_movement_type='purchase' and p_unit_cost>0 then p_unit_cost else purchase_price end,
  updated_at=now() where id=p_product_id;
 insert into public.salon_stock_movements(shop_id,product_id,movement_type,quantity,unit_cost,note,appointment_id,created_by)
 values(v_product.shop_id,p_product_id,p_movement_type,p_quantity,greatest(coalesce(p_unit_cost,0),0),p_note,p_appointment_id,auth.uid());
end $$;
revoke all on function public.gurisha_salon_stock_move(uuid,text,numeric,numeric,text,uuid) from public,anon;
grant execute on function public.gurisha_salon_stock_move(uuid,text,numeric,numeric,text,uuid) to authenticated;
