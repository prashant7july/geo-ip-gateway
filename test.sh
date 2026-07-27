#!/bin/bash
# End-to-end test of gateway-level IP + GeoIP restriction, exceptions, and
# schedules. Run after `docker compose up -d --build` and give it ~10s to
# become healthy.
set -e

ADMIN=http://localhost:4000/api
GATEWAY=http://localhost:8080

pass=0
fail=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc (got $actual)"
    pass=$((pass+1))
  else
    echo "  FAIL: $desc (expected $expected, got $actual)"
    fail=$((fail+1))
  fi
}

reset_rules() {
  curl -s -X PUT "$ADMIN/ip/mode" -H 'Content-Type: application/json' -d '{"mode":"off"}' >/dev/null
  curl -s -X PUT "$ADMIN/geo/mode" -H 'Content-Type: application/json' -d '{"mode":"off"}' >/dev/null
  curl -s -X PUT "$ADMIN/ip/schedule" -H 'Content-Type: application/json' -d '{"enabled":false}' >/dev/null
  curl -s -X PUT "$ADMIN/geo/schedule" -H 'Content-Type: application/json' -d '{"enabled":false}' >/dev/null
}

echo "== Waiting for services =="
until curl -sf "$GATEWAY/healthz" >/dev/null 2>&1; do sleep 1; done
until curl -sf "$ADMIN/rules" >/dev/null 2>&1; do sleep 1; done
echo "  gateway + admin-api are up"
echo "  Admin UI available at http://localhost:4000"

echo ""
echo "== Reset rules to a known state =="
reset_rules

echo ""
echo "== Baseline: no restrictions =="
code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY/")
check "unrestricted request succeeds" "200" "$code"

echo ""
echo "== IP blocklist test =="
curl -s -X PUT "$ADMIN/ip/mode" -H 'Content-Type: application/json' -d '{"mode":"blocklist"}' >/dev/null
curl -s -X POST "$ADMIN/ip/block" -H 'Content-Type: application/json' -d '{"ip":"203.0.113.9"}' >/dev/null

code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: 203.0.113.9" "$GATEWAY/")
check "blocked IP gets 403" "403" "$code"

code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: 203.0.113.55" "$GATEWAY/")
check "non-blocked IP still gets 200" "200" "$code"

echo ""
echo "== IP exception overrides blocklist =="
curl -s -X POST "$ADMIN/ip/exception" -H 'Content-Type: application/json' -d '{"ip":"203.0.113.9"}' >/dev/null
code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: 203.0.113.9" "$GATEWAY/")
check "excepted IP bypasses blocklist" "200" "$code"
curl -s -X DELETE "$ADMIN/ip/exception/203.0.113.9" >/dev/null

reset_rules

echo ""
echo "== IP allowlist test =="
curl -s -X PUT "$ADMIN/ip/mode" -H 'Content-Type: application/json' -d '{"mode":"allowlist"}' >/dev/null
curl -s -X POST "$ADMIN/ip/allow" -H 'Content-Type: application/json' -d '{"ip":"203.0.113.9"}' >/dev/null

code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: 203.0.113.9" "$GATEWAY/")
check "allowlisted IP gets 200" "200" "$code"

code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: 203.0.113.55" "$GATEWAY/")
check "non-allowlisted IP gets 403" "403" "$code"

reset_rules

echo ""
echo "== Schedule test: block active only outside current hour =="
CURRENT_UTC_HOUR=$(date -u +%H)
NEXT_HOUR=$(( (10#$CURRENT_UTC_HOUR + 1) % 24 ))
NEXT_HOUR2=$(( (10#$CURRENT_UTC_HOUR + 2) % 24 ))

curl -s -X PUT "$ADMIN/ip/mode" -H 'Content-Type: application/json' -d '{"mode":"blocklist"}' >/dev/null
curl -s -X POST "$ADMIN/ip/block" -H 'Content-Type: application/json' -d '{"ip":"203.0.113.9"}' >/dev/null
# Schedule window set to a future hour range that does NOT include right now
curl -s -X PUT "$ADMIN/ip/schedule" -H 'Content-Type: application/json' \
  -d "{\"enabled\":true,\"days\":[1,2,3,4,5,6,7],\"start_hour\":$NEXT_HOUR,\"end_hour\":$NEXT_HOUR2}" >/dev/null

code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: 203.0.113.9" "$GATEWAY/")
check "block outside its scheduled window is NOT enforced (200)" "200" "$code"

# Now set the window to include the current hour
curl -s -X PUT "$ADMIN/ip/schedule" -H 'Content-Type: application/json' \
  -d "{\"enabled\":true,\"days\":[1,2,3,4,5,6,7],\"start_hour\":0,\"end_hour\":24}" >/dev/null

code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: 203.0.113.9" "$GATEWAY/")
check "block inside its scheduled window IS enforced (403)" "403" "$code"

reset_rules

echo ""
echo "== GeoIP test =="
echo "  Resolving a MaxMind test-fixture IP's country from the bundled test DB..."
TEST_IP="81.2.69.142"
LOOKUP_OUT=$(docker compose exec -T gateway mmdblookup --file /etc/openresty/geoip/GeoIP2-Country-Test.mmdb --ip "$TEST_IP" country iso_code 2>/dev/null || true)
COUNTRY=$(echo "$LOOKUP_OUT" | grep -oE '"[A-Z]{2}"' | tr -d '"' | head -1)

if [ -z "$COUNTRY" ]; then
  echo "  Could not resolve $TEST_IP against the test DB — skipping geo tests."
else
  echo "  $TEST_IP -> $COUNTRY (per MaxMind's test fixture data)"

  curl -s -X PUT "$ADMIN/geo/mode" -H 'Content-Type: application/json' -d '{"mode":"blocklist"}' >/dev/null
  curl -s -X POST "$ADMIN/geo/block" -H 'Content-Type: application/json' -d "{\"country\":\"$COUNTRY\"}" >/dev/null

  code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: $TEST_IP" "$GATEWAY/")
  check "request from blocked country ($COUNTRY) gets 403" "403" "$code"

  echo ""
  echo "== Geo exception overrides blocklist =="
  curl -s -X POST "$ADMIN/geo/exception" -H 'Content-Type: application/json' -d "{\"country\":\"$COUNTRY\"}" >/dev/null
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: $TEST_IP" "$GATEWAY/")
  check "excepted country bypasses blocklist" "200" "$code"
  curl -s -X DELETE "$ADMIN/geo/exception/$COUNTRY" >/dev/null

  code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Test-Client-IP: 10.0.0.5" "$GATEWAY/")
  check "unresolvable/private test IP fails open (200)" "200" "$code"
fi

reset_rules

echo ""
echo "== Admin API test-proxy endpoint =="
resp=$(curl -s -X POST "$ADMIN/test" -H 'Content-Type: application/json' -d '{"ip":"203.0.113.55"}')
status=$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null || echo "parse_error")
check "admin-api /test proxy reports 200 for unrestricted IP" "200" "$status"

echo ""
echo "== Cleanup =="
reset_rules

echo ""
echo "============================================================"
echo "Results: $pass passed, $fail failed"
echo "Admin UI: http://localhost:4000"
echo "============================================================"

[ "$fail" -eq 0 ]
