-- Autoriser le propriétaire (administrateur), le gestionnaire et le préparateur
-- à faire avancer les commandes dans l'espace préparation.
create or replace function public.preparer_update_fast_food_order_status(
  p_order_id uuid,
  p_status text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
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
      and sm.role in ('owner','manager','preparer')
  ) then
    return jsonb_build_object('error', 'Accès réservé au propriétaire, au gestionnaire ou au préparateur de cet établissement.');
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
$function$;

revoke all on function public.preparer_update_fast_food_order_status(uuid,text) from public;
grant execute on function public.preparer_update_fast_food_order_status(uuid,text) to authenticated;
