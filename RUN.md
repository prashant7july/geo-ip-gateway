# 0. Check your NGINX has `auth_request` compiled in (needed before anything else)
```bash
nginx -V 2>&1 | grep -o with-http_auth_request_module
```
If nothing prints, this won't work until you install a build with it (Ubuntu: `apt install nginx-extras` or `nginx-full` instead of `nginx-light`).

### 1. Bring up the gateway (EC2, Docker)

```bash
git clone https://github.com/prashant7july/geo-ip-gateway.git
cd geo-ip-gateway
```

```bash
docker compose -f docker-compose.gateway-auth.yml up -d --build redis gateway admin-api
```

Sanity check the gateway directly before touching host NGINX:

```bash
curl -i http://127.0.0.1:8080/geo-check
# expect: HTTP/1.1 200 OK  (assuming no rules set yet, everything passes)
```

### 2. Edit your host `nginx.conf`

Add one `location` (internal) and one `auth_request` line to your existing `443` server block:

```nginx
server {
    listen 80;
    server_name aibackend.ienergydigital.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name aibackend.ienergydigital.com;

    ssl_certificate /etc/nginx/ssl/fullchain.crt;
    ssl_certificate_key /etc/nginx/ssl/privkey.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';

    client_max_body_size 2G;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "DENY" always;
    add_header Permissions-Policy "microphone=(self), camera=(self), geolocation=(self)";
    add_header X-XSS-Protection "1; mode=block" always;

    # --- NEW: internal subrequest to the geo-ip-gateway container ---
    location = /internal/geo-check {
        internal;
        proxy_pass http://127.0.0.1:8080/geo-check;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        auth_request /internal/geo-check;
        error_page 403 = @blocked;

        proxy_pass http://localhost:8110;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_cache_bypass $http_upgrade;

        proxy_connect_timeout 300;
        proxy_send_timeout 3600;
        proxy_read_timeout 3600;
        send_timeout 300;
    }

    location @blocked {
        return 403 "Access denied for your region";
    }
}
```

Test and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

### 3. Test it

**a) Confirm the happy path still works** (no rules configured yet, everything allowed):
```bash
curl -I https://aibackend.ienergydigital.com/
# expect: 200, your app responds normally
```

**b) Set a country rule via the admin API** (bind it to `127.0.0.1:4000` — tunnel over SSH if hitting from your laptop: `ssh -L 4000:127.0.0.1:4000 ec2-user@your-ec2`):
```bash
# only allow India
curl -X PUT http://127.0.0.1:4000/api/geo/mode -H 'Content-Type: application/json' -d '{"mode":"allowlist"}'
curl -X POST http://127.0.0.1:4000/api/geo/allow -H 'Content-Type: application/json' -d '{"country":"IN"}'
```

**c) Verify the block from a non-IN IP.** Since real traffic uses your actual client IP, the clean way to test is from a VPN endpoint outside India — hit `https://aibackend.ienergydigital.com/` and confirm you get the `403 "Access denied for your region"` page instead of your app.

**d) Verify allow from an Indian IP** (e.g. your own EC2 region or a normal request from India) — should pass through to `localhost:8110` as before.

If you want to test rule logic without needing a real foreign IP, use the gateway's demo override directly against the container (not through host NGINX, since that path uses your real IP):
```bash
curl -i -H "X-Test-Client-IP: 203.0.113.9" http://127.0.0.1:8080/geo-check
```
Just remember the README explicitly flags this header as demo-only — don't leave it trusted in `access_control.lua` once you go live; lock it down per the repo's "before using this for real traffic" checklist.