# Schema

`migrations/20261112000000_baseline.sql` is the whole schema, dumped from the
live database on 2026-11-12. It replays clean onto an empty Supabase project
(`auth.users` must exist first — every `user_id` FK points at it).

Apply it with `python3 tools/run_sql.py < supabase/migrations/<file>.sql`,
which needs `SUPABASE_DB_URL` in `.env`.

## Why a baseline instead of the migration history

`kanban` and `personal-dashboard` each kept a `supabase/migrations/` directory
pointed at the **same** Postgres. By the time they merged, the live database
had 19 applied migrations against 34 files on disk, and neither set replayed
to what was actually running — the two repos had been editing the same schema
without seeing each other's files, and several changes were applied ad hoc
through `run_sql.py` with no file at all.

Rather than reconcile three divergent histories, the live schema is the source
of truth and this is its snapshot. The 34 pre-merge files are preserved
verbatim in `archive/` for history. **Nothing in `archive/` should be replayed**
— several of those files contradict the baseline.

## Going forward

One directory, one history. New changes get a timestamped file in
`migrations/`, applied with `run_sql.py` in the same commit that updates
`mcp/mcp_server.py` and `web/index.html`.
