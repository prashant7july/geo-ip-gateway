# ─────────────────────────────────────────────────────────────────────────────
# Gateway-level IP + GeoIP enforcement, OpenResty (NGINX + Lua).
# ─────────────────────────────────────────────────────────────────────────────
FROM openresty/openresty:1.25.3.2-2-bookworm-fat

# Install dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        luarocks \
        lua5.1 \
        liblua5.1-dev \
        libmaxminddb0 \
        libmaxminddb-dev \
        mmdb-bin \
        ca-certificates \
        curl && \
    rm -rf /var/lib/apt/lists/*

# Install Lua module
RUN luarocks install lua-resty-maxminddb

# Download MaxMind test database
RUN mkdir -p /etc/openresty/geoip

COPY GeoLite2-Country.mmdb /etc/openresty/geoip/GeoLite2-Country.mmdb

# Copy configuration
# COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY nginx-gateway.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY lua/ /etc/openresty/lua/

EXPOSE 8080

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]