-- Matériels et équipements Fast-Food : inventaire séparé des ingrédients et du stock boutique.
create table if not exists public.fast_food_equipment (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null,
  category text not null default 'Autres',
  quantity_total integer not null default 1 check (quantity_total >= 0),
  quantity_usable integer not null default 1 check (quantity_usable >= 0),
  purchase_date date,
  unit_cost numeric(14,2) not null default 0 check (unit_cost >= 0),
  supplier text,
  storage_location text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fast_food_equipment_usable_lte_total check (quantity_usable <= quantity_total),
  constraint fast_food_equipment_name_shop_unique unique (shop_id, name)
);
create index if not exists fast_food_equipment_shop_category_idx
  on public.fast_food_equipment(shop_id, category, name);
alter table public.fast_food_equipment enable row level security;
drop policy if exists "ff_equipment_manage_shop" on public.fast_food_equipment;
create policy "ff_equipment_manage_shop"
on public.fast_food_equipment for all to authenticated
using (
  exists (select 1 from public.shop_members sm
    where sm.shop_id = fast_food_equipment.shop_id
      and sm.user_id = auth.uid()
      and sm.role in ('owner','manager'))
)
with check (
  exists (select 1 from public.shop_members sm
    where sm.shop_id = fast_food_equipment.shop_id
      and sm.user_id = auth.uid()
      and sm.role in ('owner','manager'))
);
grant select, insert, update, delete on public.fast_food_equipment to authenticated;
