# vendored garmin-connect-mcp

`index.js` is the built bundle of `teddythetri/garmin-connect-mcp` (private),
copied from `~/garmin-connect-mcp/dist/index.js`.

It is vendored rather than cloned in CI because the source repo is private and
cloning it would mean carrying a second PAT with access to someone else's repo.
The bundle is self-contained ESM with no runtime deps beyond Node 20+.

**It does not auto-update.** If Garmin changes its SSO flow and the upstream
repo is patched (see `src/garmin/auth.ts` — the CSRF and ticket regexes are the
fragile part), rebuild there and re-copy:

    cd ~/garmin-connect-mcp && npm run build
    cp dist/index.js ~/workspace/personal-dashboard/vendor/garmin-mcp/index.js

Verify it only talks to Garmin:

    grep -ohE 'https?://[a-zA-Z0-9._-]+' index.js | sed -E 's#https?://([^/]+).*#\1#' | sort -u
