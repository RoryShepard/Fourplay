// =============================================================================
// Fourplay sync — pulls lines & scores from ESPN into Supabase.
//
//   node scripts/sync.mjs auto              scheduled run (snapshot if Tue 9am ET, then refresh)
//   node scripts/sync.mjs snapshot          force the Tuesday line snapshot for the upcoming week
//   node scripts/sync.mjs import <week>     import/backfill a specific week (lines + scores), grades it if final
//   node scripts/sync.mjs refresh           refresh scores + live lines only
//
// Env: SUPABASE_URL, SUPABASE_SERVICE_KEY (service role — never put this in the HTML)
// =============================================================================
import { createClient } from '@supabase/supabase-js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false },
});
const ESPN = 'https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard';
const ET = 'America/New_York';

const [mode = 'auto', arg] = process.argv.slice(2);
const log = (...a) => console.log(new Date().toISOString(), ...a);

// ----------------------------------------------------------------------------
async function espn(params = '') {
  const res = await fetch(`${ESPN}${params}`, { headers: { 'User-Agent': 'fourplay-sync' } });
  if (!res.ok) throw new Error(`ESPN ${res.status}`);
  return res.json();
}

function etParts(date = new Date()) {
  const f = new Intl.DateTimeFormat('en-US', {
    timeZone: ET, weekday: 'short', hour: 'numeric', hour12: false,
  }).formatToParts(date);
  const get = (t) => f.find((p) => p.type === t)?.value;
  return { weekday: get('weekday'), hour: Number(get('hour')) % 24 };
}

// Parse a Vegas line into "home team spread" (negative = home favored).
function parseHomeSpread(odds, homeAbbr, awayAbbr) {
  if (!odds) return null;
  const details = (odds.details || '').trim().toUpperCase();
  if (details === 'EVEN' || details === 'PK' || details === 'PICK') return 0;
  const m = details.match(/^([A-Z]{2,4})\s*([+-]?\d+(?:\.\d+)?)$/);
  if (m) {
    const num = Number(m[2]);
    if (m[1] === homeAbbr) return num;
    if (m[1] === awayAbbr) return -num;
  }
  if (typeof odds.spread === 'number') return odds.spread; // ESPN's spread is home-relative
  return null;
}

function toGame(ev) {
  const comp = ev.competitions[0];
  const home = comp.competitors.find((c) => c.homeAway === 'home');
  const away = comp.competitors.find((c) => c.homeAway === 'away');
  const state = comp.status?.type?.state; // pre | in | post
  const status = state === 'post' ? 'final' : state === 'in' ? 'in_progress' : 'scheduled';
  const spread = parseHomeSpread(comp.odds?.[0], home.team.abbreviation, away.team.abbreviation);
  return {
    id: String(ev.id),
    kickoff: ev.date,
    home_abbr: home.team.abbreviation, home_name: home.team.displayName,
    away_abbr: away.team.abbreviation, away_name: away.team.displayName,
    live_spread: spread,
    home_score: status === 'scheduled' ? null : Number(home.score),
    away_score: status === 'scheduled' ? null : Number(away.score),
    status,
  };
}

// Deadline = first kickoff on a Sunday (ET). Falls back to earliest game.
function computeDeadline(games) {
  const sundays = games.filter((g) => etParts(new Date(g.kickoff)).weekday === 'Sun');
  const pool = sundays.length ? sundays : games;
  return pool.map((g) => g.kickoff).sort()[0];
}

async function fetchWeek(season, week) {
  const data = await espn(`?seasontype=2&week=${week}&dates=${season}`);
  return (data.events || []).map(toGame);
}

// Which week are we about to pick for? ESPN's default scoreboard, bumped forward
// if every game in it is already final (Monday night is over).
async function upcomingWeek() {
  const data = await espn('');
  let week = data.week?.number;
  const season = data.season?.year;
  const events = data.events || [];
  if (events.length && events.every((e) => e.competitions[0].status?.type?.state === 'post')) week += 1;
  return { season, week };
}

// ----------------------------------------------------------------------------
async function ensureWeek(season, week, games) {
  const { error } = await sb.from('weeks').upsert(
    { season, week, deadline: computeDeadline(games) },
    { onConflict: 'season,week', ignoreDuplicates: false },
  );
  if (error) throw error;
}

async function snapshot(season, week) {
  const { data: wk } = await sb.from('weeks').select('*').eq('season', season).eq('week', week).maybeSingle();
  if (wk?.lines_locked_at) { log(`Week ${week} lines already locked at ${wk.lines_locked_at}`); return; }

  const games = await fetchWeek(season, week);
  if (!games.length) throw new Error(`ESPN returned no games for week ${week}`);
  await ensureWeek(season, week, games);

  const rows = games.map((g) => ({ ...g, season, week, home_spread: g.live_spread }));
  const { error } = await sb.from('games').upsert(rows, { onConflict: 'id' });
  if (error) throw error;

  await sb.from('weeks').update({ lines_locked_at: new Date().toISOString() }).eq('season', season).eq('week', week);
  const missing = rows.filter((r) => r.home_spread == null).map((r) => `${r.away_abbr}@${r.home_abbr}`);
  log(`Snapshot week ${week}: ${rows.length} games.` + (missing.length ? ` NO LINE for ${missing.join(', ')} — set in admin.` : ''));
}

// Refresh scores + live lines for every week that isn't graded yet (and grade when done).
async function refresh() {
  const { data: weeks, error } = await sb.from('weeks').select('*').eq('graded', false).order('week');
  if (error) throw error;
  for (const wk of weeks || []) {
    const games = await fetchWeek(wk.season, wk.week);
    for (const g of games) {
      const patch = { live_spread: g.live_spread, home_score: g.home_score, away_score: g.away_score, status: g.status, kickoff: g.kickoff };
      if (g.live_spread == null) delete patch.live_spread; // don't wipe a known line when ESPN pulls odds after kickoff
      await sb.from('games').update(patch).eq('id', g.id);
    }
    if (games.length && games.every((g) => g.status === 'final')) {
      const { error: ge } = await sb.rpc('grade_week', { p_season: wk.season, p_week: wk.week });
      log(ge ? `Grade week ${wk.week} failed: ${ge.message}` : `Graded week ${wk.week}`);
    } else {
      log(`Refreshed week ${wk.week}: ${games.filter((g) => g.status === 'final').length}/${games.length} final`);
    }
  }
}

// Back-fill: import a past (or future) week wholesale.
async function importWeek(season, week) {
  const games = await fetchWeek(season, week);
  if (!games.length) throw new Error(`No games for week ${week}`);
  await ensureWeek(season, week, games);
  const { data: existing } = await sb.from('games').select('id, home_spread').eq('season', season).eq('week', week);
  const known = new Map((existing || []).map((g) => [g.id, g.home_spread]));
  const rows = games.map((g) => ({ ...g, season, week, home_spread: known.get(g.id) ?? g.live_spread }));
  const { error } = await sb.from('games').upsert(rows, { onConflict: 'id' });
  if (error) throw error;
  await sb.from('weeks').update({ lines_locked_at: new Date().toISOString() }).eq('season', season).eq('week', week).is('lines_locked_at', null);
  log(`Imported week ${week}: ${rows.length} games`);
  if (rows.every((g) => g.status === 'final')) {
    const { error: ge } = await sb.rpc('grade_week', { p_season: season, p_week: week });
    log(ge ? `Grade failed: ${ge.message}` : `Graded week ${week}`);
  }
}

// ----------------------------------------------------------------------------
(async () => {
  const { data: league } = await sb.from('league').select('*').eq('id', 1).single();
  const season = league?.season ?? new Date().getFullYear();

  if (mode === 'auto') {
    const { weekday, hour } = etParts();
    if (weekday === 'Tue' && (hour === 9 || hour === 10)) { // 10 is a fallback if the 9am run was late or failed
      const up = await upcomingWeek();
      await snapshot(up.season ?? season, up.week);
    }
    await refresh();
  } else if (mode === 'snapshot') {
    const up = await upcomingWeek();
    await snapshot(up.season ?? season, arg ? Number(arg) : up.week);
  } else if (mode === 'import') {
    if (!arg) throw new Error('usage: import <week>');
    await importWeek(season, Number(arg));
  } else if (mode === 'refresh') {
    await refresh();
  } else {
    throw new Error(`unknown mode ${mode}`);
  }
})().catch((e) => { console.error(e); process.exit(1); });
