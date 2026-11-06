-- Commandes fast-food GURISHA : table séparée des ventes et du stock général.
create table if not exists public.fast_food_orders (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  order_number text not null,
  items jsonb not null default '[]'::jsonb,
  notes text,
  status text not null default 'received'
    check (status in ('received','preparing','ready','cancelled')),
  payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid','paid')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fast_food_orders_items_array check (jsonb_typeof(items) = 'array'),
  constraint fast_food_orders_shop_number_unique unique (shop_id, order_number)
);

create index if not exists fast_food_orders_shop_status_created_idx
  on public.fast_food_orders (shop_id, status, created_at);

alter table public.fast_food_orders enable row level security;

drop policy if exists "fast_food_orders_select_shop_members" on public.fast_food_orders;
create policy "fast_food_orders_select_shop_members"
  on public.fast_food_orders for select to authenticated
  using (
    exists (
      select 1 from public.shop_members sm
      where sm.shop_id = fast_food_orders.shop_id
        and sm.user_id = auth.uid()
    )
  );

drop policy if exists "fast_food_orders_insert_cashier_manager" on public.fast_food_orders;
create policy "fast_food_orders_insert_cashier_manager"
  on public.fast_food_orders for insert to authenticated
  with check (
    created_by = auth.uid()
    and exists (
      select 1 from public.shop_members sm
      where sm.shop_id = fast_food_orders.shop_id
        and sm.user_id = auth.uid()
        and sm.role in ('owner','manager','cashier')
    )
  );

drop policy if exists "fast_food_orders_update_cashier_manager" on public.fast_food_orders;
create policy "fast_food_orders_update_cashier_manager"
  on public.fast_food_orders for update to authenticated
  using (
    exists (
      select 1 from public.shop_members sm
      where sm.shop_id = fast_food_orders.shop_id
        and sm.user_id = auth.uid()
        and sm.role in ('owner','manager','cashier')
    )
  )
  with check (
    exists (
      select 1 from public.shop_members sm
      where sm.shop_id = fast_food_orders.shop_id
        and sm.user_id = auth.uid()
        and sm.role in ('owner','manager','cashier')
    )
  );

grant select, insert, update on public.fast_food_orders to authenticated;

create or replace function public.preparer_update_fast_food_order_status(
  p_order_id uuid,
  p_status text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop_id uuid;
  v_current_status text;
begin
  if auth.uid() is null then
    return jsonb_build_object('error', 'Connexion requise.');
  end if;

  if p_status not in ('preparing','ready') then
    return jsonb_build_object('error', 'Statut non autorisé.');
  end if;

  select shop_id, status
    into v_shop_id, v_current_status
    from public.fast_food_orders
    where id = p_order_id;

  if v_shop_id is null then
    return jsonb_build_object('error', 'Commande introuvable.');
  end if;

  if not exists (
    select 1 from public.shop_members sm
    where sm.shop_id = v_shop_id
      and sm.user_id = auth.uid()
      and sm.role = 'preparer'
  ) then
    return jsonb_build_object('error', 'Accès réservé au préparateur de cette boutique.');
  end if;

  if (p_status = 'preparing' and v_current_status <> 'received')
     or (p_status = 'ready' and v_current_status <> 'preparing') then
    return jsonb_build_object('error', 'Cette étape ne correspond pas au statut actuel.');
  end if;

  update public.fast_food_orders
    set status = p_status, updated_at = now()
    where id = p_order_id and shop_id = v_shop_id;

  return jsonb_build_object('success', true, 'status', p_status);
end;
$$;

revoke all on function public.preparer_update_fast_food_order_status(uuid,text) from public;
grant execute on function public.preparer_update_fast_food_order_status(uuid,text) to authenticated;
