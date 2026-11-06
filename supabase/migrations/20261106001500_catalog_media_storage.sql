-- GURISHA SIMPLE: stockage des images et vidéos du catalogue.
-- Les fichiers sont rangés sous <shop_id>/products/...
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'gurisha-catalog-media',
  'gurisha-catalog-media',
  true,
  52428800,
  array['image/jpeg','image/png','image/webp','image/avif','video/mp4','video/webm','video/quicktime']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Gurisha members upload catalog media" on storage.objects;
create policy "Gurisha members upload catalog media"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'gurisha-catalog-media'
  and exists (
    select 1
    from public.shop_members sm
    where sm.user_id = auth.uid()
      and sm.shop_id::text = (storage.foldername(name))[1]
  )
);
