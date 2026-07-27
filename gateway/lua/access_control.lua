-- ─────────────────────────────────────────────────────────────────────────
-- Gateway-level access control: IP allow/block + GeoIP allow/block, with
-- exceptions (always-allow overrides) and time-based schedules.
--
-- Rules live in Redis (managed via admin-api / the admin UI) and are cached
-- in a shared dict for CACHE_TTL seconds to avoid a Redis round-trip on
-- every request.
--
-- FAIL-OPEN vs FAIL-CLOSED: this demo fails OPEN if Redis is unreachable
-- (requests allowed through so a Redis outage doesn't take the gateway
-- down). For a production enterprise product this should be a per-tenant
-- configurable choice.
--
-- Evaluation order per request:
--   1. IP exception?  -> skip IP mode check entirely, request proceeds
--   2. else, IP mode active (per schedule)? -> apply allow/block
--   3. GeoIP exception (country)? -> skip geo mode check entirely
--   4. else, geo mode active (per schedule)? -> apply allow/block
-- ─────────────────────────────────────────────────────────────────────────

local redis = require "resty.redis"
local maxminddb = require "resty.maxminddb"
local cjson = require "cjson"

local cache = ngx.shared.rules_cache
local CACHE_TTL = 5 -- seconds

-- ── Determine client IP ────────────────────────────────────────────────
-- X-Test-Client-IP lets you simulate requests from arbitrary source IPs
-- without changing your machine's IP — LOCAL TESTING ONLY. In production,
-- trust real_ip_header / X-Forwarded-For only from known, trusted upstream
-- proxies (ALB/Cloudflare), never from an arbitrary client-supplied header.
local client_ip = ngx.var.remote_addr
local test_override = ngx.req.get_headers()["X-Test-Client-IP"]
if test_override then
    client_ip = test_override
end

-- ── Helpers ─────────────────────────────────────────────────────────────
local function normalize_set(v)
    if v == nil or v == ngx.null then
        return {}
    end
    return v
end

local function decode_schedule(raw)
    if raw == nil or raw == ngx.null or raw == "" then
        return { enabled = false }
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return { enabled = false }
    end
    return decoded
end

-- schedule = { enabled: bool, days: [1..7] (ISO, 1=Mon..7=Sun), start_hour: 0-23, end_hour: 0-23 }
-- All times evaluated in UTC. If enabled=false (or schedule missing), the
-- restriction is always active (unrestricted by time).
local function schedule_active(schedule)
    if not schedule or not schedule.enabled then
        return true
    end

    local now = os.date("!*t") -- UTC

    -- os.date wday: 1=Sunday..7=Saturday. Convert to ISO: 1=Monday..7=Sunday.
    local iso_wday = now.wday - 1
    if iso_wday == 0 then iso_wday = 7 end

    if schedule.days and #schedule.days > 0 then
        local day_match = false
        for _, d in ipairs(schedule.days) do
            if tonumber(d) == iso_wday then
                day_match = true
                break
            end
        end
        if not day_match then
            return false
        end
    end

    local start_h = tonumber(schedule.start_hour)
    local end_h = tonumber(schedule.end_hour)
    if start_h == nil or end_h == nil then
        return true -- no valid hour window = active all day on matched days
    end

    local hour = now.hour
    if start_h <= end_h then
        return hour >= start_h and hour < end_h
    else
        -- window wraps past midnight, e.g. 22 -> 6
        return hour >= start_h or hour < end_h
    end
end

-- ── Load rules (cached) ────────────────────────────────────────────────
local function fetch_rules()
    local red = redis:new()
    red:set_timeout(200) -- ms

    local ok, err = red:connect("redis", 6379)
    if not ok then
        return nil, "redis connect failed: " .. tostring(err)
    end

    local ip_mode   = red:get("ip:mode")
    local geo_mode  = red:get("geo:mode")
    local ip_allow  = red:smembers("ip:allow")
    local ip_block  = red:smembers("ip:block")
    local geo_allow = red:smembers("geo:allow")
    local geo_block = red:smembers("geo:block")
    local ip_exception  = red:smembers("ip:exception")
    local geo_exception = red:smembers("geo:exception")
    local ip_schedule_raw  = red:get("ip:schedule")
    local geo_schedule_raw = red:get("geo:schedule")

    red:set_keepalive(10000, 100)

    local rules = {
        ip_mode  = (ip_mode == ngx.null or not ip_mode) and "off" or ip_mode,
        geo_mode = (geo_mode == ngx.null or not geo_mode) and "off" or geo_mode,
        ip_allow  = normalize_set(ip_allow),
        ip_block  = normalize_set(ip_block),
        geo_allow = normalize_set(geo_allow),
        geo_block = normalize_set(geo_block),
        ip_exception  = normalize_set(ip_exception),
        geo_exception = normalize_set(geo_exception),
        ip_schedule  = decode_schedule(ip_schedule_raw),
        geo_schedule = decode_schedule(geo_schedule_raw),
    }
    return rules
end

local function get_rules()
    local cached = cache:get("rules")
    if cached then
        local ok, decoded = pcall(cjson.decode, cached)
        if ok then
            return decoded
        end
    end

    local rules, err = fetch_rules()
    if not rules then
        return nil, err
    end

    cache:set("rules", cjson.encode(rules), CACHE_TTL)
    return rules
end

local function in_list(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

local function deny(reason)
    ngx.status = 403
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        allowed = false,
        reason = reason,
        ip = client_ip,
    }))
    return ngx.exit(403)
end

-- ── Evaluate ────────────────────────────────────────────────────────────
local rules, err = get_rules()
if not rules then
    ngx.log(ngx.WARN, "rules unavailable, failing OPEN: ", err)
    return
end

-- IP: exception overrides everything, then mode (only if schedule active)
if in_list(rules.ip_exception, client_ip) then
    -- explicitly excepted — skip IP enforcement
elseif schedule_active(rules.ip_schedule) then
    if rules.ip_mode == "allowlist" then
        if not in_list(rules.ip_allow, client_ip) then
            return deny("ip_not_in_allowlist")
        end
    elseif rules.ip_mode == "blocklist" then
        if in_list(rules.ip_block, client_ip) then
            return deny("ip_in_blocklist")
        end
    end
end

-- GeoIP: exception overrides everything, then mode (only if schedule active)
if rules.geo_mode ~= "off" or #rules.geo_exception > 0 then
    local res, geo_err = maxminddb.lookup(client_ip)

    ngx.log(ngx.ERR, "========== GEO DEBUG ==========")
    ngx.log(ngx.ERR, "Client IP: ", client_ip)
    ngx.log(ngx.ERR, "Geo Mode: ", rules.geo_mode)

    local country_code = nil

    if res then
        ngx.log(ngx.ERR, "Lookup result: ", cjson.encode(res))

        -- Try both country and registered_country
        if res.country and res.country.iso_code then
            country_code = res.country.iso_code
        elseif res.registered_country and res.registered_country.iso_code then
            country_code = res.registered_country.iso_code
        end

        ngx.log(ngx.ERR, "Country Code: ", tostring(country_code))
    else
        ngx.log(ngx.ERR, "Lookup failed: ", tostring(geo_err))
    end

    ngx.log(ngx.ERR, "Allowlist: ", table.concat(rules.geo_allow, ","))
    ngx.log(ngx.ERR, "Blocklist: ", table.concat(rules.geo_block, ","))
    ngx.log(ngx.ERR, "Exceptions: ", table.concat(rules.geo_exception, ","))
    ngx.log(ngx.ERR, "===============================")

    if not country_code then
        ngx.log(ngx.WARN, "geoip lookup failed for ", client_ip, ": ", tostring(geo_err))
        -- Fail open
    elseif in_list(rules.geo_exception, country_code) then
        ngx.log(ngx.ERR, "Country is in exception list")
    elseif schedule_active(rules.geo_schedule) then

        if rules.geo_mode == "allowlist" then
            if not in_list(rules.geo_allow, country_code) then
                ngx.log(ngx.ERR, "DENY: Country not in allowlist")
                return deny("country_not_in_allowlist:" .. country_code)
            else
                ngx.log(ngx.ERR, "ALLOW: Country in allowlist")
            end

        elseif rules.geo_mode == "blocklist" then
            if in_list(rules.geo_block, country_code) then
                ngx.log(ngx.ERR, "DENY: Country in blocklist")
                return deny("country_in_blocklist:" .. country_code)
            else
                ngx.log(ngx.ERR, "ALLOW: Country not in blocklist")
            end
        end
    end
end

-- allowed — falls through to proxy_pass in nginx.conf
