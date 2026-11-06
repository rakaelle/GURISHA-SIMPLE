-- Menus Fast-Food et fiches de consommation (ingrédients + emballages).
-- Les équipements réutilisables restent dans fast_food_equipment.
create table if not exists public.fast_food_menu_items (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null,
  category text not null default 'Autres',
  description text,
  sale_price numeric(14,2) not null default 0 check (sale_price >= 0),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fast_food_menu_items_shop_name_unique unique(shop_id,name)
);
create index if not exists fast_food_menu_items_shop_idx
  on public.fast_food_menu_items(shop_id,is_active,category);

create table if not exists public.fast_food_menu_components (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  menu_item_id uuid not null references public.fast_food_menu_items(id) on delete cascade,
  ingredient_id uuid references public.fast_food_ingredients(id) on delete set null,
  component_type text not null check(component_type in ('ingredient','packaging')),
  component_name text not null,
  quantity_per_menu numeric(14,3) not null check(quantity_per_menu > 0),
  unit text not null default 'piece',
  service_mode text not null default 'all' check(service_mode in ('all','takeaway','dine_in')),
  created_at timestamptz not null default now()
);
create index if not exists fast_food_menu_components_menu_idx
  on public.fast_food_menu_components(menu_item_id,component_type);

alter table public.fast_food_menu_items enable row level security;
alter table public.fast_food_menu_components enable row level security;

drop policy if exists "ff_menu_items_read_shop" on public.fast_food_menu_items;
create policy "ff_menu_items_read_shop" on public.fast_food_menu_items
for select to authenticated using (
 exists(select 1 from public.shop_members sm
 where sm.shop_id=fast_food_menu_items.shop_id and sm.user_id=auth.uid())
);
drop policy if exists "ff_menu_items_manage_shop" on public.fast_food_menu_items;
create policy "ff_menu_items_manage_shop" on public.fast_food_menu_items
for all to authenticated using (
 exists(select 1 from public.shop_members sm
 where sm.shop_id=fast_food_menu_items.shop_id and sm.user_id=auth.uid()
 and sm.role in ('owner','manager','gestionnaire'))
) with check (
 exists(select 1 from public.shop_members sm
 where sm.shop_id=fast_food_menu_items.shop_id and sm.user_id=auth.uid()
 and sm.role in ('owner','manager','gestionnaire'))
);

-- Le caissier ne peut lire que les consignes d'emballage; préparateur et gestionnaire voient la fiche complète.
drop policy if exists "ff_menu_components_read_by_role" on public.fast_food_menu_components;
create policy "ff_menu_components_read_by_role" on public.fast_food_menu_components
for select to authenticated using (
 exists(
  select 1 from public.shop_members sm
  where sm.shop_id=fast_food_menu_components.shop_id
    and sm.user_id=auth.uid()
    and (
      sm.role in ('owner','manager','gestionnaire','preparer')
      or (sm.role='cashier' and fast_food_menu_components.component_type='packaging')
    )
 )
);
drop policy if exists "ff_menu_components_manage_shop" on public.fast_food_menu_components;
create policy "ff_menu_components_manage_shop" on public.fast_food_menu_components
for all to authenticated using (
 exists(select 1 from public.shop_members sm
 where sm.shop_id=fast_food_menu_components.shop_id and sm.user_id=auth.uid()
 and sm.role in ('owner','manager','gestionnaire'))
) with check (
 exists(select 1 from public.shop_members sm
 where sm.shop_id=fast_food_menu_components.shop_id and sm.user_id=auth.uid()
 and sm.role in ('owner','manager','gestionnaire'))
);

grant select on public.fast_food_menu_items, public.fast_food_menu_components to authenticated;
grant insert,update,delete on public.fast_food_menu_items, public.fast_food_menu_components to authenticated;
