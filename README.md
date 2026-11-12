# Rocky OS

Personal operating system. One Supabase database holds every health and life
metric; a static dashboard on GitHub Pages reads it; scheduled Python syncs keep
it current from Oura, Garmin, Readwise, Notion and Beeminder.

**Dashboard:** https://rgowni1.github.io/rocky-os/

```
web/        Static dashboard (Pages) + iOS Scriptable widget
sync/       Scheduled ETL, one GitHub Actions workflow per script
tools/      Local operator scripts (SQL runner, password reset)
mcp/        stdio MCP server exposing task tools to Claude Code
supabase/   Schema baseline + archived pre-merge migrations
legacy/     Dead code, kept for reference
```

Merged on 2026-11-12 from `kanban` (dashboard) and `personal-dashboard` (ETL),
with full history from both preserved.

## Setup

```bash
cp .env.example .env     # fill in — every value is also a GitHub Actions secret
pip install -r sync/requirements.txt
python3 -m http.server 8000 --directory web
```

Architecture, schema, scheduling and the non-obvious invariants are documented
in [CLAUDE.md](CLAUDE.md).
