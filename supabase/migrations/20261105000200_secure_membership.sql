-- GURISHA SIMPLE: tighten membership and owner provisioning
-- Apply after the initial schema. Safe to run more than once.

-- Remove direct membership writes: they could allow role escalation.
drop policy if exists "owners and managers can add members" on public.shop_members;
drop policy if exists "owners and managers can update members" on public.shop_members;
drop policy if exists "owners and managers can remove members" on public.shop_members;

-- Shop creation and owner membership are performed atomically by this function.
drop policy if exists "authenticated users can create a shop for themselves" on public.shops;

create or replace function public.create_shop_for_current_user(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_shop_id uuid;
  v_name text := trim(coalesce(p_name, ''));
begin
  if v_user is null then
    raise exception 'Connexion requise';
  end if;
  if length(v_name) < 2 or length(v_name) > 100 then
    raise exception 'Le nom de la boutique doit contenir entre 2 et 100 caractères';
  end if;

  insert into public.shops(name, owner_id, currency)
  values (v_name, v_user, 'FBu')
  returning id into v_shop_id;

  insert into public.shop_members(shop_id, user_id, role)
  values (v_shop_id, v_user, 'owner');

  return v_shop_id;
end;
$$;

-- Only the owner may assign manager/cashier roles. Nobody can assign owner via this RPC.
create or replace function public.set_shop_member_role(
  p_shop_id uuid,
  p_user_id uuid,
  p_role text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Connexion requise';
  end if;
  if not public.has_shop_role(p_shop_id, array['owner']) then
    raise exception 'Seul le propriétaire peut gérer les rôles';
  end if;
  if p_role not in ('manager', 'cashier') then
    raise exception 'Rôle non autorisé';
  end if;

  update public.shop_members
  set role = p_role
  where shop_id = p_shop_id
    and user_id = p_user_id
    and role <> 'owner';

  if not found then
    raise exception 'Membre introuvable ou rôle propriétaire protégé';
  end if;
end;
$$;

create or replace function public.remove_shop_member(
  p_shop_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Connexion requise';
  end if;
  if not public.has_shop_role(p_shop_id, array['owner']) then
    raise exception 'Seul le propriétaire peut retirer un membre';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'Le propriétaire ne peut pas se retirer lui-même';
  end if;

  delete from public.shop_members
  where shop_id = p_shop_id
    and user_id = p_user_id
    and role <> 'owner';

  if not found then
    raise exception 'Membre introuvable ou rôle propriétaire protégé';
  end if;
end;
$$;

revoke all on function public.create_shop_for_current_user(text) from public;
revoke all on function public.set_shop_member_role(uuid, uuid, text) from public;
revoke all on function public.remove_shop_member(uuid, uuid) from public;

grant execute on function public.create_shop_for_current_user(text) to authenticated;
grant execute on function public.set_shop_member_role(uuid, uuid, text) to authenticated;
grant execute on function public.remove_shop_member(uuid, uuid) to authenticated;
