-- Stock Fast-Food GURISHA : module totalement indépendant du stock boutique existant.
-- Les quantités sont conservées dans une unité de base (g, ml ou pièce).
create table if not exists public.fast_food_ingredients (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null,
  category text not null default 'Autres',
  base_unit text not null check (base_unit in ('g','ml','piece')),
  purchase_unit text not null default 'piece',
  default_conversion_factor numeric(14,3) not null default 1 check (default_conversion_factor > 0),
  minimum_stock numeric(14,3) not null default 0 check (minimum_stock >= 0),
  notes text,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fast_food_ingredients_name_shop_unique unique (shop_id, name)
);

create table if not exists public.fast_food_ingredient_lots (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  ingredient_id uuid not null references public.fast_food_ingredients(id) on delete restrict,
  lot_code text,
  supplier text,
  purchase_date date not null default current_date,
  expiration_date date,
  purchase_quantity numeric(14,3) not null check (purchase_quantity > 0),
  purchase_unit text not null,
  conversion_factor numeric(14,3) not null check (conversion_factor > 0),
  initial_quantity_base numeric(14,3) not null check (initial_quantity_base > 0),
  remaining_quantity_base numeric(14,3) not null check (remaining_quantity_base >= 0),
  unit_cost numeric(14,2) not null default 0 check (unit_cost >= 0),
  total_cost numeric(14,2) generated always as (round(purchase_quantity * unit_cost, 2)) stored,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint fast_food_lots_shop_id_id_unique unique (shop_id, id),
  constraint fast_food_lots_quantity_check check (remaining_quantity_base <= initial_quantity_base)
);

create table if not exists public.fast_food_stock_movements (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  ingredient_id uuid not null references public.fast_food_ingredients(id) on delete restrict,
  lot_id uuid references public.fast_food_ingredient_lots(id) on delete restrict,
  movement_type text not null check (movement_type in ('purchase','consumption','waste','adjustment_in','adjustment_out')),
  quantity_base numeric(14,3) not null check (quantity_base > 0),
  unit_cost_base numeric(14,4) not null default 0 check (unit_cost_base >= 0),
  reference text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists fast_food_ingredients_shop_active_idx
  on public.fast_food_ingredients(shop_id, is_active, category);
create index if not exists fast_food_lots_shop_ingredient_expiry_idx
  on public.fast_food_ingredient_lots(shop_id, ingredient_id, expiration_date);
create index if not exists fast_food_movements_shop_created_idx
  on public.fast_food_stock_movements(shop_id, created_at desc);
create index if not exists fast_food_movements_ingredient_idx
  on public.fast_food_stock_movements(ingredient_id, created_at desc);

alter table public.fast_food_ingredients enable row level security;
alter table public.fast_food_ingredient_lots enable row level security;
alter table public.fast_food_stock_movements enable row level security;

drop policy if exists "ff_ingredients_manage_shop" on public.fast_food_ingredients;
create policy "ff_ingredients_manage_shop"
on public.fast_food_ingredients for all to authenticated
using (
  exists (select 1 from public.shop_members sm
    where sm.shop_id = fast_food_ingredients.shop_id
      and sm.user_id = auth.uid()
      and sm.role in ('owner','manager'))
)
with check (
  exists (select 1 from public.shop_members sm
    where sm.shop_id = fast_food_ingredients.shop_id
      and sm.user_id = auth.uid()
      and sm.role in ('owner','manager'))
);

drop policy if exists "ff_lots_manage_shop" on public.fast_food_ingredient_lots;
create policy "ff_lots_manage_shop"
on public.fast_food_ingredient_lots for all to authenticated
using (
  exists (select 1 from public.shop_members sm
    where sm.shop_id = fast_food_ingredient_lots.shop_id
      and sm.user_id = auth.uid()
      and sm.role in ('owner','manager'))
)
with check (
  exists (
    select 1 from public.shop_members sm
    join public.fast_food_ingredients i on i.id = fast_food_ingredient_lots.ingredient_id
    where sm.shop_id = fast_food_ingredient_lots.shop_id
      and sm.user_id = auth.uid()
      and sm.role in ('owner','manager')
      and i.shop_id = fast_food_ingredient_lots.shop_id
  )
);

drop policy if exists "ff_movements_manage_shop" on public.fast_food_stock_movements;
create policy "ff_movements_manage_shop"
on public.fast_food_stock_movements for all to authenticated
using (
  exists (select 1 from public.shop_members sm
    where sm.shop_id = fast_food_stock_movements.shop_id
      and sm.user_id = auth.uid()
      and sm.role in ('owner','manager'))
)
with check (
  exists (
    select 1 from public.shop_members sm
    join public.fast_food_ingredients i on i.id = fast_food_stock_movements.ingredient_id
    where sm.shop_id = fast_food_stock_movements.shop_id
      and sm.user_id = auth.uid()
      and sm.role in ('owner','manager')
      and i.shop_id = fast_food_stock_movements.shop_id
  )
);

grant select, insert, update, delete on public.fast_food_ingredients to authenticated;
grant select, insert, update, delete on public.fast_food_ingredient_lots to authenticated;
grant select, insert on public.fast_food_stock_movements to authenticated;

-- Chaque lot créé génère automatiquement une entrée d'achat dans son journal.
create or replace function public.fast_food_log_lot_purchase()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  insert into public.fast_food_stock_movements (
    shop_id, ingredient_id, lot_id, movement_type,
    quantity_base, unit_cost_base, reference, notes, created_by
  ) values (
    new.shop_id, new.ingredient_id, new.id, 'purchase',
    new.initial_quantity_base,
    case when new.conversion_factor > 0 then new.unit_cost / new.conversion_factor else 0 end,
    coalesce(new.lot_code, 'Achat du ' || new.purchase_date::text),
    new.notes, new.created_by
  );
  return new;
end;
$$;

drop trigger if exists fast_food_lot_purchase_log on public.fast_food_ingredient_lots;
create trigger fast_food_lot_purchase_log
after insert on public.fast_food_ingredient_lots
for each row execute function public.fast_food_log_lot_purchase();
