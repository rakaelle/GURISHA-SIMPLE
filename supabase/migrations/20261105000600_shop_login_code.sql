-- GURISHA SIMPLE: unique code used by employees to identify their shop at sign-in.
alter table public.shops add column if not exists login_code text;
update public.shops set login_code = upper(encode(gen_random_bytes(4), 'hex')) where login_code is null;
alter table public.shops alter column login_code set default upper(encode(gen_random_bytes(4), 'hex'));
alter table public.shops alter column login_code set not null;
create unique index if not exists shops_login_code_unique on public.shops(login_code);
