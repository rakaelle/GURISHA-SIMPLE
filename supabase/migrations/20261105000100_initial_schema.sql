-- GURISHA SIMPLE - initial database schema
-- Currency: FBu. This migration is intended for the dedicated GURISHA-SIMPLE project.

create extension if not exists pgcrypto;

create table if not exists public.shops (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null references auth.users(id),
  currency text not null default 'FBu',
  created_at timestamptz not null default now()
);

create table if not exists public.shop_members (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'manager', 'cashier')),
  created_at timestamptz not null default now(),
  unique (shop_id, user_id)
);

create or replace function public.is_shop_member(p_shop_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = auth.uid()
  );
$$;

create or replace function public.has_shop_role(p_shop_id uuid, p_roles text[])
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.shop_members
    where shop_id = p_shop_id
      and user_id = auth.uid()
      and role = any(p_roles)
  );
$$;

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (shop_id, name)
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  category_id uuid references public.categories(id) on delete set null,
  name text not null,
  unit text not null default 'unité',
  lot_a numeric(12,2) not null default 0 check (lot_a >= 0),
  lot_b numeric(12,2) not null default 0 check (lot_b >= 0),
  purchase_price numeric(12,2) not null default 0 check (purchase_price >= 0),
  sale_price numeric(12,2) not null default 0 check (sale_price >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid references auth.users(id),
  total numeric(14,2) not null default 0,
  status text not null default 'completed'
    check (status in ('completed', 'cancelled')),
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id),
  quantity numeric(12,2) not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  line_total numeric(14,2) generated always as (quantity * unit_price) stored,
  created_at timestamptz not null default now()
);

create table if not exists public.purchases (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid references auth.users(id),
  supplier text,
  total numeric(14,2) not null default 0,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  purchase_id uuid not null references public.purchases(id) on delete cascade,
  product_id uuid not null references public.products(id),
  quantity numeric(12,2) not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  lot text not null default 'B' check (lot in ('A', 'B')),
  line_total numeric(14,2) generated always as (quantity * unit_price) stored,
  created_at timestamptz not null default now()
);

-- FIFO: sales consume Lot A first, then Lot B. Lot B moves to A when A is empty.
create or replace function public.gurisha_consume_stock()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_a numeric(12,2);
  v_b numeric(12,2);
  v_remaining numeric(12,2);
begin
  select lot_a, lot_b into v_a, v_b
  from public.products
  where id = new.product_id and shop_id = new.shop_id
  for update;

  if not found then
    raise exception 'Article introuvable dans cette boutique';
  end if;

  if v_a + v_b < new.quantity then
    raise exception 'Stock insuffisant pour cet article';
  end if;

  v_remaining := new.quantity;

  if v_a >= v_remaining then
    v_a := v_a - v_remaining;
    v_remaining := 0;
  else
    v_remaining := v_remaining - v_a;
    v_a := 0;
  end if;

  if v_remaining > 0 then
    v_b := v_b - v_remaining;
  end if;

  if v_a = 0 and v_b > 0 then
    v_a := v_b;
    v_b := 0;
  end if;

  update public.products
  set lot_a = v_a, lot_b = v_b, updated_at = now()
  where id = new.product_id and shop_id = new.shop_id;

  return new;
end;
$$;

drop trigger if exists trg_gurisha_consume_stock on public.sale_items;
create trigger trg_gurisha_consume_stock
before insert on public.sale_items
for each row execute function public.gurisha_consume_stock();

-- New purchase quantities are added to the selected lot.
create or replace function public.gurisha_add_stock()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if new.lot = 'A' then
    update public.products
    set lot_a = lot_a + new.quantity,
        purchase_price = new.unit_price,
        updated_at = now()
    where id = new.product_id and shop_id = new.shop_id;
  else
    update public.products
    set lot_b = lot_b + new.quantity,
        purchase_price = new.unit_price,
        updated_at = now()
    where id = new.product_id and shop_id = new.shop_id;
  end if;

  if not found then
    raise exception 'Article introuvable dans cette boutique';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_gurisha_add_stock on public.purchase_items;
create trigger trg_gurisha_add_stock
before insert on public.purchase_items
for each row execute function public.gurisha_add_stock();

create index if not exists idx_shop_members_user on public.shop_members(user_id);
create index if not exists idx_categories_shop on public.categories(shop_id);
create index if not exists idx_products_shop on public.products(shop_id);
create index if not exists idx_sales_shop_date on public.sales(shop_id, created_at);
create index if not exists idx_purchases_shop_date on public.purchases(shop_id, created_at);
create index if not exists idx_sale_items_sale on public.sale_items(sale_id);
create index if not exists idx_purchase_items_purchase on public.purchase_items(purchase_id);

alter table public.shops enable row level security;
alter table public.shop_members enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_items enable row level security;

create policy "shop members can view their shops"
on public.shops for select to authenticated
using (public.is_shop_member(id));

create policy "authenticated users can create a shop for themselves"
on public.shops for insert to authenticated
with check (owner_id = auth.uid());

create policy "shop owners and managers can update shop"
on public.shops for update to authenticated
using (public.has_shop_role(id, array['owner','manager']))
with check (public.has_shop_role(id, array['owner','manager']));

create policy "members can view shop memberships"
on public.shop_members for select to authenticated
using (public.is_shop_member(shop_id));

create policy "owners and managers can add members"
on public.shop_members for insert to authenticated
with check (
  public.has_shop_role(shop_id, array['owner','manager'])
  or exists (select 1 from public.shops s where s.id = shop_id and s.owner_id = auth.uid())
);

create policy "owners and managers can update members"
on public.shop_members for update to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']))
with check (public.has_shop_role(shop_id, array['owner','manager']));

create policy "owners and managers can remove members"
on public.shop_members for delete to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']));

create policy "members can view categories"
on public.categories for select to authenticated
using (public.is_shop_member(shop_id));

create policy "members can add categories"
on public.categories for insert to authenticated
with check (public.is_shop_member(shop_id));

create policy "managers can update categories"
on public.categories for update to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']))
with check (public.has_shop_role(shop_id, array['owner','manager']));

create policy "managers can delete categories"
on public.categories for delete to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']));

create policy "members can view products"
on public.products for select to authenticated
using (public.is_shop_member(shop_id));

create policy "members can add products"
on public.products for insert to authenticated
with check (public.is_shop_member(shop_id));

create policy "managers can update products"
on public.products for update to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']))
with check (public.has_shop_role(shop_id, array['owner','manager']));

create policy "managers can delete products"
on public.products for delete to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']));

create policy "managers can read sales history"
on public.sales for select to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']));

create policy "members can record sales"
on public.sales for insert to authenticated
with check (public.is_shop_member(shop_id) and (user_id is null or user_id = auth.uid()));

create policy "members can cancel or delete sales"
on public.sales for delete to authenticated
using (public.is_shop_member(shop_id));

create policy "managers can update sales"
on public.sales for update to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']))
with check (public.has_shop_role(shop_id, array['owner','manager']));

create policy "managers can read sale details"
on public.sale_items for select to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']));

create policy "members can add sale details"
on public.sale_items for insert to authenticated
with check (
  public.is_shop_member(shop_id)
  and exists (select 1 from public.sales s where s.id = sale_id and s.shop_id = shop_id)
);

create policy "members can delete sale details"
on public.sale_items for delete to authenticated
using (public.is_shop_member(shop_id));

create policy "managers can read purchase history"
on public.purchases for select to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']));

create policy "members can record purchases"
on public.purchases for insert to authenticated
with check (public.is_shop_member(shop_id) and (user_id is null or user_id = auth.uid()));

create policy "managers can read purchase details"
on public.purchase_items for select to authenticated
using (public.has_shop_role(shop_id, array['owner','manager']));

create policy "members can add purchase details"
on public.purchase_items for insert to authenticated
with check (
  public.is_shop_member(shop_id)
  and exists (select 1 from public.purchases p where p.id = purchase_id and p.shop_id = shop_id)
);
