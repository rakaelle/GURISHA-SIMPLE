-- GURISHA — Admin et propriétaire sont le même niveau d'accès.
-- Migration additive : aucune donnée ni aucun rôle existant n'est modifié.
create or replace function public.gurisha_has_shop_access(
  p_shop_id uuid,
  p_roles text[] default array[]::text[]
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.shop_members sm
     where sm.shop_id = p_shop_id
       and sm.user_id = auth.uid()
       and (
         sm.role in ('admin','owner','manager','gestionnaire')
         or sm.role = any(coalesce(p_roles, array[]::text[]))
         or (
           coalesce(auth.jwt()->'user_metadata'->'gurisha_roles', '[]'::jsonb)
           ?| coalesce(p_roles, array[]::text[])
         )
         or coalesce(auth.jwt()->'user_metadata'->'gurisha_roles', '[]'::jsonb) ? 'admin'
       )
  );
$$;
