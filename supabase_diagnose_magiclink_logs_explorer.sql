-- Run in Dashboard → Logs → Logs Explorer (NOT the SQL Editor — this queries
-- the auth_logs log source, which is where GoTrue's internal error detail
-- lives; the Edge Logs entry you already have only shows the HTTP transaction,
-- not the reason). Source picker in the Explorer UI should be set to "auth".

-- ── 1. Everything GoTrue logged in the ~30s window around the failed request ──
-- (request hit at 2026-07-07T18:13:28.673Z per your edge log)
select
  cast(timestamp as datetime) as ts,
  event_message,
  metadata
from auth_logs
where timestamp between timestamp('2026-07-07T18:13:15Z')
                    and timestamp('2026-07-07T18:13:40Z')
order by timestamp asc;

-- ── 2. If (1) is noisy, filter to error-level lines only ──
select
  cast(timestamp as datetime) as ts,
  event_message,
  metadata
from auth_logs
where timestamp between timestamp('2026-07-07T18:13:15Z')
                    and timestamp('2026-07-07T18:13:40Z')
  and (event_message ilike '%error%' or event_message ilike '%fail%')
order by timestamp asc;
