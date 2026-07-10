// ============================================================
// Key Wellness — Browser-side RLS isolation test
// Paste into the DevTools console while LOGGED IN as a normal member.
// Uses the page's existing anon `sb` client, so it tests the real boundary.
// ============================================================
// `sb` is a top-level const on the portal page, reachable here in global scope.
// It is passed into the async runner below as `sb`.
(async (sb) => {
  if (!sb) { console.error('No `sb` client found — run on the portal while logged in.'); return; }

  const { data: { user } } = await sb.auth.getUser();
  if (!user) { console.error('Not logged in. Sign in first, then re-run.'); return; }
  const uid = user.id;
  const pass = [], fail = [];
  const ok  = (m) => pass.push('✅ ' + m);
  const bad = (m) => fail.push('❌ ' + m);

  console.log('%cRunning RLS isolation tests as ' + user.email, 'font-weight:bold');

  // 1. I can read my OWN profile
  {
    const { data } = await sb.from('profiles').select('id').eq('id', uid).maybeSingle();
    data ? ok('Can read my own profile') : bad('Cannot read my own profile (RLS too strict?)');
  }

  // 2. Selecting ALL rows returns ONLY mine (RLS silently filters others)
  for (const t of ['assessments','checkins','badges','emergency_fund']) {
    const { data, error } = await sb.from(t).select('user_id');
    if (error) { bad(`${t}: query errored — ${error.message}`); continue; }
    const foreign = (data || []).filter(r => r.user_id && r.user_id !== uid);
    foreign.length === 0
      ? ok(`${t}: no foreign rows leaked (${data.length} row(s), all mine)`)
      : bad(`${t}: LEAK — ${foreign.length} row(s) belong to other users`);
  }

  // 3. profiles: selecting all returns only my row
  {
    const { data } = await sb.from('profiles').select('id');
    const foreign = (data || []).filter(r => r.id !== uid);
    foreign.length === 0
      ? ok(`profiles: no foreign rows leaked (${(data||[]).length} visible)`)
      : bad(`profiles: LEAK — ${foreign.length} other profile(s) visible`);
  }

  // 4. Targeted probe: try to read a definitely-not-me id → must be empty
  {
    const fakeId = '00000000-0000-0000-0000-000000000000';
    const { data } = await sb.from('assessments').select('user_id').eq('user_id', fakeId);
    (data || []).length === 0
      ? ok('Targeted read of another user_id returns empty')
      : bad('Targeted read returned rows for a foreign user_id');
  }

  // 5. org_id is locked: try to set my own org_id → trigger must revert it
  {
    const before = (await sb.from('profiles').select('org_id').eq('id', uid).maybeSingle()).data?.org_id ?? null;
    await sb.from('profiles').update({ org_id: '11111111-1111-1111-1111-111111111111' }).eq('id', uid);
    const after = (await sb.from('profiles').select('org_id').eq('id', uid).maybeSingle()).data?.org_id ?? null;
    (before === after)
      ? ok(`org_id is locked (stayed ${before})`)
      : bad(`org_id CHANGED from ${before} to ${after} — lock trigger not working`);
  }

  // 6. org_overview for an org I don't manage → must be denied/empty
  {
    const { data, error } = await sb.rpc('org_overview', { target_org: '11111111-1111-1111-1111-111111111111' });
    (error || data == null)
      ? ok('org_overview() denied for an org I do not manage')
      : bad('org_overview() returned data for an org I should not access');
  }

  console.log('%c\n— PASS —', 'color:green;font-weight:bold');  pass.forEach(m => console.log(m));
  if (fail.length) { console.log('%c\n— FAIL —', 'color:red;font-weight:bold'); fail.forEach(m => console.log(m)); }
  else console.log('%c\nAll isolation checks passed. 🎉', 'color:green;font-weight:bold');
})(typeof sb !== 'undefined' ? sb : (window.sb || window.supabaseClient));
