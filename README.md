# Gateway-level IP + GeoIP restriction (OpenResty demo, with Admin UI)

Enforces IP and country allow/block rules **at the gateway** (OpenResty/NGINX
+ Lua) — the backend Node.js service never sees a rejected request.
Enforcement requires no UI and no admin-api at all to keep working; the
admin UI is purely an optional convenience layer for configuring rules
dynamically, exactly as specified:

- IP allowlists / blocklists
- GeoIP allowlists / blocklists (by ISO country code)
- **Exceptions** — always-allow overrides regardless of mode or schedule
- **Schedules** — restrict *when* a mode is enforced (e.g. only 9am–6pm
  weekdays, UTC); outside the window requests are always allowed

## Architecture

```
client → gateway (OpenResty, :8080) → backend (Node, :3000)
              │
              ├─ access_control.lua checks IP + GeoIP rules,
              │  exceptions, and schedules
              │
         Redis (:6379) ← admin-api (:4000) — REST API + Admin UI
```

The admin UI is served by `admin-api` itself (plain HTML/CSS/JS, no build
step, no external CDN dependency — works fully offline) at
**http://localhost:4000**.

## Quickstart

```bash
cd geo-ip-gateway
docker compose up -d --build
./test.sh
```

`test.sh` exercises: baseline passthrough, IP blocklist, IP allowlist, IP
exceptions, schedule enforcement (both inside and outside the active
window), GeoIP blocklist, geo exceptions, and the admin-api's live-test
proxy endpoint — all against real running containers.

Then open **http://localhost:4000** in a browser for the admin UI.

## What's already been tested

The admin API + Redis logic (all endpoints: mode changes, allow/block
add/remove, exceptions, schedules, validation, and the gateway-test proxy)
was run live against a real Redis instance during development — every
endpoint above was exercised with real HTTP requests, not just read for
syntax. The one piece that needs to run on your machine is the OpenResty
gateway container itself, since building it requires pulling from Docker
Hub (not available in the environment these files were authored in). Once
you run `docker compose up -d --build`, `test.sh` will validate the full
path including the gateway.

## Admin UI

Four panels, all backed by the same REST API a future integration could
call directly:

- **IP Rules** — set mode (off/allowlist/blocklist), add/remove IPs
- **GeoIP Rules** — set mode, add/remove ISO country codes
- **Exceptions** — IPs/countries that are always allowed, overriding
  everything else (blocklist, allowlist, and schedule)
- **Schedules** — per-rule-type (IP or Geo) day-of-week + hour-of-day
  window (UTC) during which the mode is actually enforced; disabled by
  default (always enforced)
- **Live Test** — sends a real request through the gateway with a
  simulated source IP and shows the actual HTTP status + reason returned

The UI polls `/api/rules` every 10s so it reflects changes made via the
API directly (e.g. from a script or another admin's session).

## Manually driving it via API

Requests to the gateway use your real source IP by default. For local
testing, override it with `X-Test-Client-IP` (demo-only mechanism — see
the warning in `gateway/lua/access_control.lua`; never trust an arbitrary
client-supplied header for this in production).

```bash
# Block an IP
curl -X PUT http://localhost:4000/api/ip/mode -H 'Content-Type: application/json' -d '{"mode":"blocklist"}'
curl -X POST http://localhost:4000/api/ip/block -H 'Content-Type: application/json' -d '{"ip":"203.0.113.9"}'

# Confirm it's blocked
curl -i -H "X-Test-Client-IP: 203.0.113.9" http://localhost:8080/
# -> 403

# Add an exception that overrides the block
curl -X POST http://localhost:4000/api/ip/exception -H 'Content-Type: application/json' -d '{"ip":"203.0.113.9"}'
curl -i -H "X-Test-Client-IP: 203.0.113.9" http://localhost:8080/
# -> 200 (exception wins)

# Restrict the block to business hours only (UTC)
curl -X PUT http://localhost:4000/api/ip/schedule -H 'Content-Type: application/json' \
  -d '{"enabled":true,"days":[1,2,3,4,5],"start_hour":9,"end_hour":18}'

# Reset everything
curl -X PUT http://localhost:4000/api/ip/mode -H 'Content-Type: application/json' -d '{"mode":"off"}'
curl -X PUT http://localhost:4000/api/ip/schedule -H 'Content-Type: application/json' -d '{"enabled":false}'
```

To find which country a MaxMind **test** IP resolves to:
```bash
docker compose exec gateway mmdblookup \
  --file /etc/openresty/geoip/GeoIP2-Country-Test.mmdb \
  --ip 81.2.69.142 country iso_code
```

## Admin API reference

| Method | Path | Body | Purpose |
|---|---|---|---|
| GET | `/api/rules` | — | Current full rule set |
| PUT | `/api/ip/mode` | `{"mode":"off\|allowlist\|blocklist"}` | Set IP enforcement mode |
| POST | `/api/ip/allow` | `{"ip":"1.2.3.4"}` | Add IP to allowlist |
| DELETE | `/api/ip/allow/:ip` | — | Remove from allowlist |
| POST | `/api/ip/block` | `{"ip":"1.2.3.4"}` | Add IP to blocklist |
| DELETE | `/api/ip/block/:ip` | — | Remove from blocklist |
| POST | `/api/ip/exception` | `{"ip":"1.2.3.4"}` | Always-allow this IP |
| DELETE | `/api/ip/exception/:ip` | — | Remove exception |
| PUT | `/api/ip/schedule` | `{"enabled":bool,"days":[1-7],"start_hour":0-23,"end_hour":0-23}` | Set when IP mode is enforced |
| PUT | `/api/geo/mode` | `{"mode":"off\|allowlist\|blocklist"}` | Set geo enforcement mode |
| POST | `/api/geo/allow` | `{"country":"US"}` | Add country to allowlist |
| DELETE | `/api/geo/allow/:country` | — | Remove from allowlist |
| POST | `/api/geo/block` | `{"country":"US"}` | Add country to blocklist |
| DELETE | `/api/geo/block/:country` | — | Remove from blocklist |
| POST | `/api/geo/exception` | `{"country":"US"}` | Always-allow this country |
| DELETE | `/api/geo/exception/:country` | — | Remove exception |
| PUT | `/api/geo/schedule` | same shape as IP schedule | Set when geo mode is enforced |
| POST | `/api/test` | `{"ip":"1.2.3.4"}` | Proxies a real request through the gateway with that IP, returns the result |

**Schedule semantics**: `days` uses ISO weekday numbering (1=Monday ...
7=Sunday), all times UTC. If `enabled` is `false` (default), the mode is
always enforced regardless of time. `start_hour`/`end_hour` support
wrapping past midnight (e.g. `start_hour: 22, end_hour: 6` = 10pm–6am).

**Evaluation order** in the gateway (`access_control.lua`): exception check
first (bypasses everything if matched) → schedule check (skip enforcement
entirely if outside the active window) → mode check (allow/block).

## Before using this for real traffic

1. **Swap the test MaxMind DB for a real one.** The bundled
   `GeoIP2-Country-Test.mmdb` only has a small fixed set of fixture IPs —
   not real geolocation data. Get a free MaxMind account + license key,
   download `GeoLite2-Country.mmdb`, and mount/copy it to
   `/etc/openresty/geoip/` in place of the test file (update the path in
   `nginx.conf`'s `maxminddb.init(...)` call). Refresh it periodically
   (MaxMind updates GeoLite2 weekly).
2. **Remove or lock down the `X-Test-Client-IP` override** in
   `access_control.lua`. In production, derive the client IP from
   `ngx.var.remote_addr` plus NGINX's `real_ip_header`/`set_real_ip_from`
   directives scoped to your actual trusted upstream (ALB, Cloudflare) —
   never from a header any client can set.
3. **Put authentication in front of the admin UI/API.** Right now
   `admin-api` has zero auth — anyone who can reach port 4000 can change
   your access rules. Add at minimum basic auth or a reverse-proxy-level
   auth check before exposing this beyond localhost.
4. **Decide fail-open vs fail-closed per tenant.** Right now
   `access_control.lua` always fails open when Redis is unreachable. For
   an enterprise product this should very likely be configurable per
   customer.
5. **Add audit logging.** Denials currently only go to the gateway's error
   log. For a real product, ship structured allow/deny decisions (with
   reason and matched rule) to wherever customers can see "why was my
   request blocked."
6. **Put a real WAF/CDN in front of this** (Cloudflare, AWS WAF) for
   DDoS/bot mitigation — this gateway is the tenant-configurable policy
   layer, not a replacement for edge-level protection.

---

# Option 1 (Recommended): Restrict in NGINX

```text
Internet
      │
      ▼
Host NGINX (GeoIP)
      │
      ├── Block USA
      ├── Block China
      └── Allow India
            │
            ▼
Docker App :8012
```

---

# Option 2: Your Architecture [URLShort](https://github.com/miyorisoft/URLShort)

```
Internet
      │
      ▼
NGINX (Host EC2)
      │
      │  X-Real-IP: 103.xx.xx.xx
      ▼
Docker App (8012)
      │
      ├── GeoLite2-City.mmdb
      ├── Lookup IP
      ├── Country = IN ?
      └── Allow / Deny
```

# Option 3

```
Internet
   │
   ▼
NGINX (host EC2, port 80/443)  ← unchanged, still your public entry point
   │
   │  proxy_pass → 127.0.0.1:8080   (instead of straight to your app)
   ▼
geo-ip-gateway container (OpenResty, port 8080, docker)
   │  checks IP/GeoIP rules via access_control.lua + Redis
   ▼
your frontend/backend (host EC2, non-docker, e.g. port 8012/3000)
```

# Option 4

```
Internet
   │
   ▼
NGINX (host)
   │
   ├── auth_request → geo-ip-gateway "/check" (subrequest, no body)
   │        200 = country OK        403 = country blocked
   │
   ├── if 200 → proxy_pass → Front/Backend (host, non-docker)
   └── if 403 → return 403, request never reaches Front/Backend
```
