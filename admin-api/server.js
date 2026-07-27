// Admin API for managing gateway-level IP/GeoIP access rules, plus the
// static admin UI (served from ./public). This is the only optional layer
// per the requirement — enforcement itself lives entirely in the gateway's
// Lua script and works with zero UI involvement.

const path = require('path');
const express = require('express');
const { createClient } = require('redis');

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const REDIS_URL = process.env.REDIS_URL || 'redis://redis:6379';
const GATEWAY_URL = process.env.GATEWAY_URL || 'http://gateway:8080';

const redisClient = createClient({ url: REDIS_URL });
redisClient.on('error', (err) => console.error('Redis error', err));

const MODES = ['off', 'allowlist', 'blocklist'];

function validMode(mode) {
  return MODES.includes(mode);
}

function validSchedule(s) {
  if (typeof s !== 'object' || s === null) return false;
  if (typeof s.enabled !== 'boolean') return false;
  if (s.days !== undefined) {
    if (!Array.isArray(s.days)) return false;
    for (const d of s.days) {
      const n = Number(d);
      if (!Number.isInteger(n) || n < 1 || n > 7) return false;
    }
  }
  if (s.start_hour !== undefined) {
    const n = Number(s.start_hour);
    if (!Number.isInteger(n) || n < 0 || n > 23) return false;
  }
  if (s.end_hour !== undefined) {
    const n = Number(s.end_hour);
    if (!Number.isInteger(n) || n < 0 || n > 23) return false;
  }
  return true;
}

async function main() {
  await redisClient.connect();

  // ── Full rule set ────────────────────────────────────────────────────
  app.get('/api/rules', async (req, res) => {
    const [
      ipMode, geoMode,
      ipAllow, ipBlock,
      geoAllow, geoBlock,
      ipException, geoException,
      ipScheduleRaw, geoScheduleRaw,
    ] = await Promise.all([
      redisClient.get('ip:mode'),
      redisClient.get('geo:mode'),
      redisClient.sMembers('ip:allow'),
      redisClient.sMembers('ip:block'),
      redisClient.sMembers('geo:allow'),
      redisClient.sMembers('geo:block'),
      redisClient.sMembers('ip:exception'),
      redisClient.sMembers('geo:exception'),
      redisClient.get('ip:schedule'),
      redisClient.get('geo:schedule'),
    ]);

    const parseSchedule = (raw) => {
      if (!raw) return { enabled: false };
      try {
        return JSON.parse(raw);
      } catch {
        return { enabled: false };
      }
    };

    res.json({
      ip_mode: ipMode || 'off',
      geo_mode: geoMode || 'off',
      ip_allow: ipAllow,
      ip_block: ipBlock,
      geo_allow: geoAllow,
      geo_block: geoBlock,
      ip_exception: ipException,
      geo_exception: geoException,
      ip_schedule: parseSchedule(ipScheduleRaw),
      geo_schedule: parseSchedule(geoScheduleRaw),
    });
  });

  // ── IP mode / allow / block ─────────────────────────────────────────
  app.put('/api/ip/mode', async (req, res) => {
    const { mode } = req.body;
    if (!validMode(mode)) {
      return res.status(400).json({ error: 'mode must be off|allowlist|blocklist' });
    }
    await redisClient.set('ip:mode', mode);
    res.json({ ok: true, ip_mode: mode });
  });

  app.post('/api/ip/allow', async (req, res) => {
    const { ip } = req.body;
    if (!ip) return res.status(400).json({ error: 'ip required' });
    await redisClient.sAdd('ip:allow', ip);
    res.json({ ok: true });
  });

  app.delete('/api/ip/allow/:ip', async (req, res) => {
    await redisClient.sRem('ip:allow', req.params.ip);
    res.json({ ok: true });
  });

  app.post('/api/ip/block', async (req, res) => {
    const { ip } = req.body;
    if (!ip) return res.status(400).json({ error: 'ip required' });
    await redisClient.sAdd('ip:block', ip);
    res.json({ ok: true });
  });

  app.delete('/api/ip/block/:ip', async (req, res) => {
    await redisClient.sRem('ip:block', req.params.ip);
    res.json({ ok: true });
  });

  // ── IP exceptions (always-allow, overrides mode entirely) ──────────
  app.post('/api/ip/exception', async (req, res) => {
    const { ip } = req.body;
    if (!ip) return res.status(400).json({ error: 'ip required' });
    await redisClient.sAdd('ip:exception', ip);
    res.json({ ok: true });
  });

  app.delete('/api/ip/exception/:ip', async (req, res) => {
    await redisClient.sRem('ip:exception', req.params.ip);
    res.json({ ok: true });
  });

  // ── IP schedule ──────────────────────────────────────────────────────
  app.put('/api/ip/schedule', async (req, res) => {
    if (!validSchedule(req.body)) {
      return res.status(400).json({
        error: 'schedule must be { enabled: bool, days?: [1-7], start_hour?: 0-23, end_hour?: 0-23 }',
      });
    }
    await redisClient.set('ip:schedule', JSON.stringify(req.body));
    res.json({ ok: true, ip_schedule: req.body });
  });

  // ── Geo mode / allow / block ─────────────────────────────────────────
  app.put('/api/geo/mode', async (req, res) => {
    const { mode } = req.body;
    if (!validMode(mode)) {
      return res.status(400).json({ error: 'mode must be off|allowlist|blocklist' });
    }
    await redisClient.set('geo:mode', mode);
    res.json({ ok: true, geo_mode: mode });
  });

  app.post('/api/geo/allow', async (req, res) => {
    const { country } = req.body;
    if (!country) return res.status(400).json({ error: 'country (ISO code) required' });
    await redisClient.sAdd('geo:allow', country.toUpperCase());
    res.json({ ok: true });
  });

  app.delete('/api/geo/allow/:country', async (req, res) => {
    await redisClient.sRem('geo:allow', req.params.country.toUpperCase());
    res.json({ ok: true });
  });

  app.post('/api/geo/block', async (req, res) => {
    const { country } = req.body;
    if (!country) return res.status(400).json({ error: 'country (ISO code) required' });
    await redisClient.sAdd('geo:block', country.toUpperCase());
    res.json({ ok: true });
  });

  app.delete('/api/geo/block/:country', async (req, res) => {
    await redisClient.sRem('geo:block', req.params.country.toUpperCase());
    res.json({ ok: true });
  });

  // ── Geo exceptions (always-allow, overrides mode entirely) ─────────
  app.post('/api/geo/exception', async (req, res) => {
    const { country } = req.body;
    if (!country) return res.status(400).json({ error: 'country (ISO code) required' });
    await redisClient.sAdd('geo:exception', country.toUpperCase());
    res.json({ ok: true });
  });

  app.delete('/api/geo/exception/:country', async (req, res) => {
    await redisClient.sRem('geo:exception', req.params.country.toUpperCase());
    res.json({ ok: true });
  });

  // ── Geo schedule ─────────────────────────────────────────────────────
  app.put('/api/geo/schedule', async (req, res) => {
    if (!validSchedule(req.body)) {
      return res.status(400).json({
        error: 'schedule must be { enabled: bool, days?: [1-7], start_hour?: 0-23, end_hour?: 0-23 }',
      });
    }
    await redisClient.set('geo:schedule', JSON.stringify(req.body));
    res.json({ ok: true, geo_schedule: req.body });
  });

  // ── Live test — proxies a request to the gateway with a simulated
  // client IP, so the admin UI can show "would this IP be allowed?"
  // without the browser needing direct/CORS access to the gateway.
  app.post('/api/test', async (req, res) => {
    const { ip } = req.body;
    if (!ip) return res.status(400).json({ error: 'ip required' });
    try {
      const r = await fetch(GATEWAY_URL + '/', {
        headers: { 'X-Test-Client-IP': ip },
      });
      let body = {};
      try {
        body = await r.json();
      } catch {
        // non-JSON response, leave body empty
      }
      res.json({ status: r.status, body });
    } catch (err) {
      res.status(502).json({ error: 'gateway unreachable', detail: String(err) });
    }
  });

  app.listen(4000, () => console.log('admin-api (+ admin UI) listening on :4000'));
}

main().catch((err) => {
  console.error('fatal startup error', err);
  process.exit(1);
});
