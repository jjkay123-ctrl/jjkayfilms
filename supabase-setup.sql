-- JJ Kay Films: complete, repeatable Supabase setup and migration.
-- Run this entire file in Supabase SQL Editor while signed in as project owner.
begin;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role text not null default 'user' check (role in ('user','owner')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists role text not null default 'user';
alter table public.profiles add column if not exists created_at timestamptz not null default now();
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

create or replace function public.jjkay_create_profile()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name',''))
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists jjkay_auth_user_created on auth.users;
create trigger jjkay_auth_user_created after insert on auth.users
for each row execute procedure public.jjkay_create_profile();

create table if not exists public.videos (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  category text not null default 'Drama',
  year integer,
  storage_path text,
  video_url text,
  poster_url text,
  uploader_id uuid references auth.users(id) on delete cascade,
  is_published boolean not null default false,
  published boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.videos add column if not exists description text;
alter table public.videos add column if not exists category text not null default 'Drama';
alter table public.videos add column if not exists year integer;
alter table public.videos add column if not exists storage_path text;
alter table public.videos add column if not exists video_url text;
alter table public.videos add column if not exists poster_url text;
alter table public.videos add column if not exists uploader_id uuid references auth.users(id) on delete cascade;
alter table public.videos add column if not exists is_published boolean not null default false;
alter table public.videos add column if not exists published boolean not null default false;
alter table public.videos add column if not exists created_at timestamptz not null default now();
update public.videos set is_published = true where published = true and is_published = false;
update public.videos set published = true where is_published = true and published = false;

create table if not exists public.favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  video_id uuid not null references public.videos(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);

alter table public.profiles enable row level security;
alter table public.videos enable row level security;
alter table public.favorites enable row level security;

drop policy if exists "Profiles view own" on public.profiles;
drop policy if exists "Profiles insert own" on public.profiles;
drop policy if exists "Profiles update own" on public.profiles;
drop policy if exists "Profiles select own" on public.profiles;
create policy "Profiles select own" on public.profiles
for select to authenticated using (auth.uid() = id);
create policy "Profiles insert own" on public.profiles
for insert to authenticated with check (auth.uid() = id);
revoke all on public.profiles from anon;
revoke update on public.profiles from authenticated;
grant select, insert on public.profiles to authenticated;
grant update (id, display_name, updated_at) on public.profiles to authenticated;

drop policy if exists "Published videos or own uploads readable" on public.videos;
drop policy if exists "Authenticated users submit videos" on public.videos;
drop policy if exists "Uploader can update own pending videos" on public.videos;
drop policy if exists "Uploader can delete own pending videos" on public.videos;
drop policy if exists "Owners can insert videos" on public.videos;
drop policy if exists "Owners can update videos" on public.videos;
drop policy if exists "Owners can delete videos" on public.videos;
create policy "Published videos or own uploads readable" on public.videos
for select to anon, authenticated using (
  is_published = true or auth.uid() = uploader_id
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'owner')
);
create policy "Authenticated users submit videos" on public.videos
for insert to authenticated with check (auth.uid() = uploader_id and is_published = false);
create policy "Uploader can update own pending videos" on public.videos
for update to authenticated using (auth.uid() = uploader_id and is_published = false)
with check (auth.uid() = uploader_id and is_published = false);
create policy "Uploader can delete own pending videos" on public.videos
for delete to authenticated using (auth.uid() = uploader_id and is_published = false);
create policy "Owners can insert videos" on public.videos
for insert to authenticated with check (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'owner')
);
create policy "Owners can update videos" on public.videos
for update to authenticated using (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'owner')
) with check (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'owner')
);
create policy "Owners can delete videos" on public.videos
for delete to authenticated using (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'owner')
);

drop policy if exists "Users read own favorites" on public.favorites;
drop policy if exists "Users add own favorites" on public.favorites;
drop policy if exists "Users remove own favorites" on public.favorites;
create policy "Users read own favorites" on public.favorites
for select to authenticated using (auth.uid() = user_id);
create policy "Users add own favorites" on public.favorites
for insert to authenticated with check (auth.uid() = user_id);
create policy "Users remove own favorites" on public.favorites
for delete to authenticated using (auth.uid() = user_id);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('jjkay-videos', 'jjkay-videos', false, 52428800, array['video/mp4','video/webm','video/ogg'])
on conflict (id) do update set public = false, file_size_limit = 52428800,
allowed_mime_types = array['video/mp4','video/webm','video/ogg'];

drop policy if exists "Users upload own video files" on storage.objects;
drop policy if exists "Users read own video files" on storage.objects;
drop policy if exists "Users read published video files" on storage.objects;
drop policy if exists "Users delete own video files" on storage.objects;
create policy "Users upload own video files" on storage.objects
for insert to authenticated with check (
  bucket_id = 'jjkay-videos' and (storage.foldername(name))[1] = auth.uid()::text
);
create policy "Users read own video files" on storage.objects
for select to authenticated using (
  bucket_id = 'jjkay-videos' and (storage.foldername(name))[1] = auth.uid()::text
);
create policy "Users read published video files" on storage.objects
for select to anon, authenticated using (
  bucket_id = 'jjkay-videos' and exists (
    select 1 from public.videos v
    where v.storage_path = storage.objects.name and v.is_published = true
  )
);
create policy "Users delete own video files" on storage.objects
for delete to authenticated using (
  bucket_id = 'jjkay-videos' and (storage.foldername(name))[1] = auth.uid()::text
);

-- After creating your account on the website, replace the email below
-- with the email you used to register, then run this statement to grant owner access:
-- update public.profiles p set role = 'owner'
-- where p.id = (select u.id from auth.users u where u.email = 'YOUR_LOGIN_EMAIL');

commit;
