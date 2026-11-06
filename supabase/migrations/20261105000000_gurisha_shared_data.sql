-- GURISHA SIMPLE : stockage partagé par boutique
-- À exécuter une seule fois dans Supabase > SQL Editor.

create table if not exists public.gurisha_shop_data (
  shop_id uuid primary key,
  payload jsonb not null default '{"categories":[],"products":[]}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.gurisha_shop_data enable row level security;

-- Les utilisateurs ne peuvent pas lire/écrire directement la table.
revoke all on public.gurisha_shop_data from anon, authenticated;

create or replace function public.gurisha_get_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop_id uuid;
  v_payload jsonb;
begin
  select sm.shop_id
    into v_shop_id
    from public.shop_members sm
   where sm.user_id = auth.uid()
   limit 1;

  if v_shop_id is null then
    raise exception 'Aucune boutique associée à ce compte.';
  end if;

  select d.payload
    into v_payload
    from public.gurisha_shop_data d
   where d.shop_id = v_shop_id;

  return v_payload;
end;
$$;

create or replace function public.gurisha_save_data(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop_id uuid;
begin
  select sm.shop_id
    into v_shop_id
    from public.shop_members sm
   where sm.user_id = auth.uid()
   limit 1;

  if v_shop_id is null then
    raise exception 'Aucune boutique associée à ce compte.';
  end if;

  if p_payload is null
     or jsonb_typeof(p_payload) <> 'object'
     or jsonb_typeof(p_payload->'categories') <> 'array'
     or jsonb_typeof(p_payload->'products') <> 'array' then
    raise exception 'Données GURISHA invalides.';
  end if;

  insert into public.gurisha_shop_data (shop_id, payload, updated_at)
  values (v_shop_id, p_payload, now())
  on conflict (shop_id)
  do update set payload = excluded.payload, updated_at = now();

  return jsonb_build_object('success', true);
end;
$$;

revoke all on function public.gurisha_get_data() from public, anon;
revoke all on function public.gurisha_save_data(jsonb) from public, anon;
grant execute on function public.gurisha_get_data() to authenticated;
grant execute on function public.gurisha_save_data(jsonb) to authenticated;
