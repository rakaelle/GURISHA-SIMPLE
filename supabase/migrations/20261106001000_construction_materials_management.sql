-- GURISHA - Gestion des matériaux de construction, commandes, devis et livraisons.
-- Module autonome : n'altère pas les stocks historiques ni le module fast-food.

create table if not exists public.construction_materials (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops(id) on delete cascade,
 name text not null,
 category text not null default 'Autres',
 unit text not null default 'pièce',
 description text,
 unit_price numeric(14,2) not null default 0 check(unit_price>=0),
 available_quantity numeric(14,3) not null default 0 check(available_quantity>=0),
 manage_stock boolean not null default false,
 is_active boolean not null default true,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(shop_id,name)
);
create index if not exists construction_materials_shop_idx on public.construction_materials(shop_id,is_active,category);

create table if not exists public.construction_material_orders (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops(id) on delete cascade,
 order_number text not null,
 client_name text not null,
 client_phone text,
 delivery_address text not null,
 delivery_area text,
 requested_date date,
 items jsonb not null default '[]'::jsonb check(jsonb_typeof(items)='array'),
 subtotal numeric(14,2) not null default 0 check(subtotal>=0),
 delivery_fee numeric(14,2) not null default 0 check(delivery_fee>=0),
 total numeric(14,2) not null default 0 check(total>=0),
 notes text,
 status text not null default 'received' check(status in ('received','confirmed','loading','in_transit','delivered','cancelled')),
 payment_status text not null default 'unpaid' check(payment_status in ('unpaid','partial','paid')),
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(shop_id,order_number)
);
create index if not exists construction_orders_shop_status_idx on public.construction_material_orders(shop_id,status,created_at desc);

create table if not exists public.construction_material_quotes (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops(id) on delete cascade,
 quote_number text not null,
 client_name text not null,
 client_phone text,
 delivery_address text,
 delivery_area text,
 requested_date date,
 items jsonb not null default '[]'::jsonb check(jsonb_typeof(items)='array'),
 subtotal numeric(14,2) not null default 0 check(subtotal>=0),
 delivery_fee numeric(14,2) not null default 0 check(delivery_fee>=0),
 total numeric(14,2) not null default 0 check(total>=0),
 notes text,
 status text not null default 'draft' check(status in ('draft','sent','accepted','rejected','converted')),
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(shop_id,quote_number)
);
create index if not exists construction_quotes_shop_status_idx on public.construction_material_quotes(shop_id,status,created_at desc);

create table if not exists public.construction_material_vehicles (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops(id) on delete cascade,
 vehicle_name text not null,
 plate_number text,
 capacity numeric(14,3),
 capacity_unit text not null default 'tonne',
 driver_name text,
 driver_phone text,
 is_active boolean not null default true,
 notes text,
 created_at timestamptz not null default now(),
 unique(shop_id,plate_number)
);

create table if not exists public.construction_material_deliveries (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops(id) on delete cascade,
 order_id uuid references public.construction_material_orders(id) on delete cascade,
 quote_id uuid references public.construction_material_quotes(id) on delete set null,
 vehicle_id uuid references public.construction_material_vehicles(id) on delete set null,
 driver_name text,
 driver_phone text,
 delivery_date date,
 status text not null default 'planned' check(status in ('planned','loading','in_transit','delivered','failed','cancelled')),
 notes text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(order_id is not null or quote_id is not null)
);

do $$
declare t text;
begin
 foreach t in array array[
  'construction_materials','construction_material_orders',
  'construction_material_quotes','construction_material_vehicles',
  'construction_material_deliveries'
 ] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists %I on public.%I',t||'_member_select',t);
  execute format('create policy %I on public.%I for select to authenticated using (exists (select 1 from public.shop_members sm where sm.shop_id = %I.shop_id and sm.user_id = auth.uid()))',t||'_member_select',t,t);
 end loop;
end $$;

drop policy if exists construction_materials_manage on public.construction_materials;
create policy construction_materials_manage on public.construction_materials for all to authenticated
using(exists(select 1 from public.shop_members sm where sm.shop_id=construction_materials.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager')))
with check(exists(select 1 from public.shop_members sm where sm.shop_id=construction_materials.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager')));

drop policy if exists construction_orders_insert on public.construction_material_orders;
create policy construction_orders_insert on public.construction_material_orders for insert to authenticated
with check(created_by=auth.uid() and exists(select 1 from public.shop_members sm where sm.shop_id=construction_material_orders.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager','cashier')));
drop policy if exists construction_orders_update on public.construction_material_orders;
create policy construction_orders_update on public.construction_material_orders for update to authenticated
using(exists(select 1 from public.shop_members sm where sm.shop_id=construction_material_orders.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager','cashier')))
with check(exists(select 1 from public.shop_members sm where sm.shop_id=construction_material_orders.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager','cashier')));

drop policy if exists construction_quotes_manage on public.construction_material_quotes;
create policy construction_quotes_manage on public.construction_material_quotes for all to authenticated
using(exists(select 1 from public.shop_members sm where sm.shop_id=construction_material_quotes.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager')))
with check(created_by=auth.uid() and exists(select 1 from public.shop_members sm where sm.shop_id=construction_material_quotes.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager')));

drop policy if exists construction_vehicles_manage on public.construction_material_vehicles;
create policy construction_vehicles_manage on public.construction_material_vehicles for all to authenticated
using(exists(select 1 from public.shop_members sm where sm.shop_id=construction_material_vehicles.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager')))
with check(exists(select 1 from public.shop_members sm where sm.shop_id=construction_material_vehicles.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager')));

drop policy if exists construction_deliveries_manage on public.construction_material_deliveries;
create policy construction_deliveries_manage on public.construction_material_deliveries for all to authenticated
using(exists(select 1 from public.shop_members sm where sm.shop_id=construction_material_deliveries.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager')))
with check(exists(select 1 from public.shop_members sm where sm.shop_id=construction_material_deliveries.shop_id and sm.user_id=auth.uid() and sm.role in ('owner','manager')));

grant select,insert,update,delete on public.construction_materials to authenticated;
grant select,insert,update on public.construction_material_orders to authenticated;
grant select,insert,update,delete on public.construction_material_quotes to authenticated;
grant select,insert,update,delete on public.construction_material_vehicles to authenticated;
grant select,insert,update,delete on public.construction_material_deliveries to authenticated;
