-- Vaccinator Resource Hub: database setup
-- Paste this whole file into Supabase → SQL Editor → New query, then click Run.
-- It is safe to run more than once.

-- ─── People and roles ─────────────────────────────────────────────
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  email text,
  full_name text,
  role text not null default 'vaccinator' check (role in ('vaccinator', 'editor')),
  created_at timestamptz not null default now()
);

-- True when the signed-in person is an editor.
create or replace function public.is_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'editor');
$$;

-- Every new account gets a profile. The very first account becomes an editor.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', ''),
    case when exists (select 1 from public.profiles where role = 'editor') then 'vaccinator' else 'editor' end
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─── Library ──────────────────────────────────────────────────────
create table if not exists public.resources (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  category text,
  description text,
  kind text not null default 'file' check (kind in ('file', 'link')),
  url text,
  storage_path text,
  file_name text,
  content_type text,
  size_bytes bigint,
  page_count int,
  has_text boolean not null default false,
  added_at timestamptz not null default now(),
  updated_at timestamptz
);

-- Text pulled out of each PDF page, used by the assistant's search.
create table if not exists public.resource_pages (
  id bigserial primary key,
  resource_id uuid not null references public.resources on delete cascade,
  page int not null,
  content text not null,
  fts tsvector generated always as (to_tsvector('simple', content)) stored
);
create index if not exists resource_pages_resource_idx on public.resource_pages (resource_id, page);
create index if not exists resource_pages_fts_idx on public.resource_pages using gin (fts);

-- Ranked keyword search across pages. Any of the words can match.
create or replace function public.search_pages(q text, rid uuid default null, n int default 8)
returns table (resource_id uuid, title text, page int, snippet text)
language sql stable security invoker set search_path = public as $$
  with words as (
    select distinct w from regexp_split_to_table(lower(q), '[^[:alnum:]°]+') w
    where length(w) > 1 and w not in (
      'the','and','or','of','to','in','on','for','with','is','are','was','be','by','at','as','it',
      'this','that','from','what','which','who','how','when','where','do','does','should','can','my','an','if','about')
  ),
  query as (select to_tsquery('simple', string_agg(quote_literal(w) || ':*', ' | ')) as tsq from words)
  select p.resource_id, r.title, p.page,
         ts_headline('simple', p.content, query.tsq, 'MaxWords=90, MinWords=40, MaxFragments=2') as snippet
  from public.resource_pages p
  join public.resources r on r.id = p.resource_id
  cross join query
  where query.tsq is not null and p.fts @@ query.tsq and (rid is null or p.resource_id = rid)
  order by ts_rank(p.fts, query.tsq) desc
  limit least(greatest(n, 1), 20);
$$;

-- ─── Training ─────────────────────────────────────────────────────
create table if not exists public.modules (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  sort_order int not null default 0,
  steps jsonb not null default '[]',
  updated_at timestamptz default now()
);

-- Correct quiz answers, kept apart so vaccinators can't read them.
create table if not exists public.quiz_answers (
  module_id uuid not null references public.modules on delete cascade,
  step_id text not null,
  answer int not null,
  primary key (module_id, step_id)
);

create or replace function public.check_quiz_answer(module_id uuid, step_id text, choice int) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (
    select 1 from public.quiz_answers a
    where a.module_id = check_quiz_answer.module_id and a.step_id = check_quiz_answer.step_id and a.answer = choice);
$$;

create table if not exists public.progress (
  user_id uuid primary key references auth.users on delete cascade,
  done jsonb not null default '{}',
  modules_done jsonb not null default '{}',
  updated_at timestamptz not null default now()
);

-- Counts assistant questions so one person can't run up the bill.
create table if not exists public.chat_log (
  id bigserial primary key,
  user_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists chat_log_user_idx on public.chat_log (user_id, created_at);

-- ─── Security rules ───────────────────────────────────────────────
alter table public.profiles enable row level security;
alter table public.resources enable row level security;
alter table public.resource_pages enable row level security;
alter table public.modules enable row level security;
alter table public.quiz_answers enable row level security;
alter table public.progress enable row level security;
alter table public.chat_log enable row level security;

drop policy if exists "See own profile, editors see all" on public.profiles;
create policy "See own profile, editors see all" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_editor());
drop policy if exists "Editors change roles" on public.profiles;
create policy "Editors change roles" on public.profiles
  for update to authenticated using (public.is_editor()) with check (public.is_editor());

drop policy if exists "Signed-in users read the library" on public.resources;
create policy "Signed-in users read the library" on public.resources for select to authenticated using (true);
drop policy if exists "Editors manage the library" on public.resources;
create policy "Editors manage the library" on public.resources for all to authenticated using (public.is_editor()) with check (public.is_editor());

drop policy if exists "Signed-in users read page text" on public.resource_pages;
create policy "Signed-in users read page text" on public.resource_pages for select to authenticated using (true);
drop policy if exists "Editors manage page text" on public.resource_pages;
create policy "Editors manage page text" on public.resource_pages for all to authenticated using (public.is_editor()) with check (public.is_editor());

drop policy if exists "Signed-in users read modules" on public.modules;
create policy "Signed-in users read modules" on public.modules for select to authenticated using (true);
drop policy if exists "Editors manage modules" on public.modules;
create policy "Editors manage modules" on public.modules for all to authenticated using (public.is_editor()) with check (public.is_editor());

drop policy if exists "Editors manage quiz answers" on public.quiz_answers;
create policy "Editors manage quiz answers" on public.quiz_answers for all to authenticated using (public.is_editor()) with check (public.is_editor());

drop policy if exists "See own progress, editors see all" on public.progress;
create policy "See own progress, editors see all" on public.progress
  for select to authenticated using (user_id = auth.uid() or public.is_editor());
drop policy if exists "Record own progress" on public.progress;
create policy "Record own progress" on public.progress
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "Update own progress" on public.progress;
create policy "Update own progress" on public.progress
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
-- chat_log has no policies on purpose: only the assistant function writes to it.

-- ─── File storage ─────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit)
values ('resources', 'resources', false, 52428800)
on conflict (id) do nothing;

drop policy if exists "Signed-in users open hub files" on storage.objects;
create policy "Signed-in users open hub files" on storage.objects
  for select to authenticated using (bucket_id = 'resources');
drop policy if exists "Editors upload hub files" on storage.objects;
create policy "Editors upload hub files" on storage.objects
  for insert to authenticated with check (bucket_id = 'resources' and public.is_editor());
drop policy if exists "Editors update hub files" on storage.objects;
create policy "Editors update hub files" on storage.objects
  for update to authenticated using (bucket_id = 'resources' and public.is_editor());
drop policy if exists "Editors delete hub files" on storage.objects;
create policy "Editors delete hub files" on storage.objects
  for delete to authenticated using (bucket_id = 'resources' and public.is_editor());

-- ─── Example training module (edit or delete it in the app) ───────
insert into public.modules (id, title, description, sort_order, steps)
select '00000000-0000-4000-8000-000000000001',
  'Example: Cold chain basics',
  'Sample module to show how training works. Edit it to link your own SOP, or delete it.',
  1,
  '[
    {"id":"s1read","kind":"read","title":"Read your cold chain SOP","instructions":"Read the storage and handling SOP for your facility. (Editors: link the SOP from the Library in Edit.)"},
    {"id":"s2task","kind":"task","title":"Record the refrigerator temperature twice a day","instructions":"Read the thermometer at the start and end of your shift for one full week and write each reading on the temperature log."},
    {"id":"s3quiz","kind":"quiz","title":"Check: storage temperature","instructions":"","question":"At what temperature should most routine vaccines be stored in the refrigerator?","options":["Between +2 °C and +8 °C","Below 0 °C","Room temperature (about +25 °C)"]},
    {"id":"s4quiz","kind":"quiz","title":"Check: vaccine vial monitor (VVM)","instructions":"","question":"When can you use a vial with a VVM?","options":["When the inner square is lighter than the outer circle","When the inner square matches or is darker than the outer circle","Whenever the vial is within its expiry date"]}
  ]'::jsonb
where not exists (select 1 from public.modules);

insert into public.quiz_answers (module_id, step_id, answer)
select '00000000-0000-4000-8000-000000000001', s, 0 from unnest(array['s3quiz', 's4quiz']) s
where exists (select 1 from public.modules where id = '00000000-0000-4000-8000-000000000001')
on conflict do nothing;
