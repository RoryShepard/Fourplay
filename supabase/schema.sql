-- =============================================================================
-- FOURPLAY — Supabase schema
-- Paste this whole file into the Supabase SQL editor and run it once.
-- =============================================================================

-- ---------- League settings (single row) -------------------------------------
create table if not exists league (
  id        int primary key default 1 check (id = 1),
  name      text not null default 'Fourplay',
  season    int not null default 2026,
  stake     numeric not null default 25,   -- $ each loser pays each winner
  bonus     numeric not null default 14,   -- points added to every team
  picks_per_week int not null default 4
);
insert into league (id) values (1) on conflict do nothing;

-- ---------- Players ----------------------------------------------------------
create table if not exists profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null,
  is_admin   boolean not null default false,
  created_at timestamptz not null default now()
);

-- Auto-create a profile when the commissioner adds a user in the Auth dashboard.
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- Weeks & games ----------------------------------------------------
create table if not exists weeks (
  season          int not null,
  week            int not null,
  deadline        timestamptz,                 -- first Sunday kickoff
  lines_locked_at timestamptz,                 -- Tuesday 9am ET snapshot
  graded          boolean not null default false,
  primary key (season, week)
);

create table if not exists games (
  id          text primary key,                -- ESPN event id
  season      int not null,
  week        int not null,
  kickoff     timestamptz not null,
  home_abbr   text not null,
  home_name   text not null,
  away_abbr   text not null,
  away_name   text not null,
  home_spread numeric,        -- Vegas line for the HOME team, frozen Tuesday (negative = home favored)
  live_spread numeric,        -- most recent line seen (for movement alerts)
  home_score  int,
  away_score  int,
  status      text not null default 'scheduled' check (status in ('scheduled','in_progress','final')),
  foreign key (season, week) references weeks(season, week) on delete cascade
);
create index if not exists games_week_idx on games(season, week);

-- ---------- Picks ------------------------------------------------------------
create table if not exists submissions (
  user_id      uuid not null references profiles(id) on delete cascade,
  season       int not null,
  week         int not null,
  submitted_at timestamptz not null default now(),
  primary key (user_id, season, week),
  foreign key (season, week) references weeks(season, week) on delete cascade
);

create table if not exists picks (
  id       bigint generated always as identity primary key,
  user_id  uuid not null references profiles(id) on delete cascade,
  season   int not null,
  week     int not null,
  game_id  text not null references games(id) on delete cascade,
  side     text not null check (side in ('home','away')),
  unique (user_id, game_id, side)
);
create index if not exists picks_week_idx on picks(season, week);

-- ---------- Results ----------------------------------------------------------
create table if not exists week_results (
  user_id   uuid not null references profiles(id) on delete cascade,
  season    int not null,
  week      int not null,
  submitted boolean not null,
  wins      int not null default 0,
  pushes    int not null default 0,
  losses    int not null default 0,
  won       boolean not null default false,
  net       numeric not null default 0,
  primary key (user_id, season, week)
);

-- =============================================================================
-- Helper functions
-- =============================================================================
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false)
$$;

create or replace function has_submitted(p_season int, p_week int) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from submissions
                 where user_id = auth.uid() and season = p_season and week = p_week)
$$;

create or replace function week_closed(p_season int, p_week int) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select deadline < now() from weeks where season = p_season and week = p_week), false)
$$;

-- =============================================================================
-- submit_picks: the only way a player can enter picks. Validates everything.
-- =============================================================================
create or replace function submit_picks(p_season int, p_week int, p_picks jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  uid    uuid := auth.uid();
  n      int  := (select picks_per_week from league where id = 1);
  wk     weeks%rowtype;
  p      jsonb;
  g      games%rowtype;
begin
  if uid is null then raise exception 'Not signed in'; end if;

  select * into wk from weeks where season = p_season and week = p_week;
  if not found then raise exception 'Week % is not open yet', p_week; end if;
  if wk.lines_locked_at is null then raise exception 'Lines for week % have not been posted yet', p_week; end if;
  if wk.deadline is not null and wk.deadline < now() then
    raise exception 'Week % is closed — the deadline has passed', p_week;
  end if;
  if exists (select 1 from submissions where user_id = uid and season = p_season and week = p_week) then
    raise exception 'Your picks for week % are already locked', p_week;
  end if;

  if jsonb_typeof(p_picks) <> 'array' or jsonb_array_length(p_picks) <> n then
    raise exception 'You must submit exactly % picks', n;
  end if;
  if (select count(distinct (x->>'game_id') || ':' || (x->>'side')) from jsonb_array_elements(p_picks) x) <> n then
    raise exception 'Duplicate pick';
  end if;

  for p in select * from jsonb_array_elements(p_picks) loop
    select * into g from games where id = p->>'game_id';
    if not found or g.season <> p_season or g.week <> p_week then
      raise exception 'Game % is not in week %', p->>'game_id', p_week;
    end if;
    if p->>'side' not in ('home','away') then raise exception 'Bad side'; end if;
    if g.home_spread is null then raise exception 'No line posted for % @ %', g.away_abbr, g.home_abbr; end if;
    if g.kickoff <= now() then
      raise exception '% @ % has already started', g.away_abbr, g.home_abbr;
    end if;
    insert into picks (user_id, season, week, game_id, side)
    values (uid, p_season, p_week, g.id, p->>'side');
  end loop;

  insert into submissions (user_id, season, week) values (uid, p_season, p_week);
end $$;

-- =============================================================================
-- admin_set_picks: commissioner enters/replaces picks for any player, any week
-- (used for back-filling). No time checks.
-- =============================================================================
create or replace function admin_set_picks(p_user uuid, p_season int, p_week int, p_picks jsonb, p_submitted_at timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
declare p jsonb;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  delete from picks where user_id = p_user and season = p_season and week = p_week;
  delete from submissions where user_id = p_user and season = p_season and week = p_week;
  if p_picks is null or jsonb_array_length(p_picks) = 0 then return; end if;
  for p in select * from jsonb_array_elements(p_picks) loop
    insert into picks (user_id, season, week, game_id, side)
    values (p_user, p_season, p_week, p->>'game_id', p->>'side');
  end loop;
  insert into submissions (user_id, season, week, submitted_at) values (p_user, p_season, p_week, p_submitted_at);
end $$;

-- =============================================================================
-- grade_week: scores every pick, decides winners, computes money.
-- Callable by admins and by the sync script (service role).
-- Re-running it is safe — it recomputes from scratch.
-- =============================================================================
create or replace function grade_week(p_season int, p_week int, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  bonus_pts numeric := (select bonus from league where id = 1);
  stake_amt numeric := (select stake  from league where id = 1);
  n_picks   int     := (select picks_per_week from league where id = 1);
  n_winners int;
  n_losers  int;
begin
  if auth.uid() is not null and not is_admin() then raise exception 'Admins only'; end if;

  if not p_force and exists (select 1 from games where season = p_season and week = p_week and status <> 'final') then
    raise exception 'Not every game in week % is final yet', p_week;
  end if;

  delete from week_results where season = p_season and week = p_week;

  -- Every player is graded. No submission = loss.
  insert into week_results (user_id, season, week, submitted, wins, pushes, losses, won, net)
  select
    pr.id, p_season, p_week,
    s.user_id is not null,
    coalesce(r.wins, 0), coalesce(r.pushes, 0), coalesce(r.losses, 0),
    (s.user_id is not null and coalesce(r.wins, 0) = n_picks),
    0
  from profiles pr
  left join submissions s on s.user_id = pr.id and s.season = p_season and s.week = p_week
  left join lateral (
    select
      count(*) filter (where m > 0) as wins,
      count(*) filter (where m = 0) as pushes,
      count(*) filter (where m < 0) as losses
    from (
      select
        case when g.home_score is null or g.away_score is null then -1
             when pk.side = 'home'
               then (g.home_score - g.away_score) + ( g.home_spread + bonus_pts)
               else (g.away_score - g.home_score) + (-g.home_spread + bonus_pts)
        end as m
      from picks pk join games g on g.id = pk.game_id
      where pk.user_id = pr.id and pk.season = p_season and pk.week = p_week
    ) x
  ) r on true;

  select count(*) filter (where won), count(*) filter (where not won)
    into n_winners, n_losers
  from week_results where season = p_season and week = p_week;

  -- Winners collect `stake` from each loser. Everyone wins / everyone loses = no blood.
  update week_results
     set net = case when won then stake_amt * n_losers else -stake_amt * n_winners end
   where season = p_season and week = p_week;

  update weeks set graded = true where season = p_season and week = p_week;
end $$;

-- =============================================================================
-- Row-level security
-- =============================================================================
alter table league       enable row level security;
alter table profiles     enable row level security;
alter table weeks        enable row level security;
alter table games        enable row level security;
alter table submissions  enable row level security;
alter table picks        enable row level security;
alter table week_results enable row level security;

-- Everyone signed in can read league config, players, weeks, games, who has submitted, results.
create policy "read league"   on league       for select to authenticated using (true);
create policy "read profiles" on profiles     for select to authenticated using (true);
create policy "read weeks"    on weeks        for select to authenticated using (true);
create policy "read games"    on games        for select to authenticated using (true);
create policy "read subs"     on submissions  for select to authenticated using (true);
create policy "read results"  on week_results for select to authenticated using (true);

-- Picks are hidden until YOU have submitted for that week (or the week has closed).
create policy "read picks" on picks for select to authenticated using (
  user_id = auth.uid()
  or has_submitted(season, week)
  or week_closed(season, week)
  or is_admin()
);

-- Admin can edit config, players, weeks and games directly from the app.
create policy "admin league"   on league   for update to authenticated using (is_admin());
create policy "admin profiles" on profiles for update to authenticated using (is_admin());
create policy "admin weeks"    on weeks    for all    to authenticated using (is_admin()) with check (is_admin());
create policy "admin games"    on games    for all    to authenticated using (is_admin()) with check (is_admin());

-- No direct insert/update/delete on picks or submissions: only through submit_picks / admin_set_picks.

grant execute on function submit_picks(int,int,jsonb) to authenticated;
grant execute on function admin_set_picks(uuid,int,int,jsonb,timestamptz) to authenticated;
grant execute on function grade_week(int,int,boolean) to authenticated;
