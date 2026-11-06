-- Autoriser le rôle préparateur sans lui donner accès aux données commerciales classiques.
alter table public.shop_members drop constraint if exists shop_members_role_check;
alter table public.shop_members
  add constraint shop_members_role_check
  check (role in ('owner','manager','cashier','preparer'));

alter table public.staff_profiles drop constraint if exists staff_profiles_role_check;
alter table public.staff_profiles
  add constraint staff_profiles_role_check
  check (role in ('manager','cashier','preparer'));

-- Le préparateur ne reçoit aucun accès supplémentaire aux fonctions de stock,
-- ventes, achats ou historiques de GURISHA.
