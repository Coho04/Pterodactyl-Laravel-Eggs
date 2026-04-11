# Unified Laravel Image with Runtime Web Server Selection

**Date:** 2026-04-11
**Status:** Draft
**Scope:** Pterodactyl-Laravel-Eggs

## Motivation

Today the repository produces six Docker images — three PHP versions (8.2, 8.3, 8.4) each built in two variants (`artisan` and `nginx`). The Pelican/Pterodactyl user picks one of these at egg-setup time, which locks them into a web server choice and doubles the Dockerfile maintenance surface.

The egg already exposes a `WEB_SERVER` environment variable (`nginx`/`artisan`), but it is only meaningful in one direction: the `nginx` images cannot run `artisan serve` meaningfully (the `artisan` flow works anyway), and the `artisan` images don't ship Nginx at all, so setting `WEB_SERVER=nginx` there is a no-op. The runtime switch is a lie.

On top of that, the bundled `etc/nginx/nginx.conf` works for Laravel in isolation, but it is not tuned for the typical Pelican deployment reality: behind a reverse proxy (Cloudflare / NPM / Traefik) that terminates HTTPS and rewrites client IPs. Out of the box Laravel sees the proxy IP and generates `http://` URLs even when the public endpoint is HTTPS.

This spec collapses the image matrix to one image per PHP version, makes `WEB_SERVER` a real runtime switch, and brings the bundled Nginx config up to a Pelican-friendly baseline with escape hatches for power users.

## Goals

1. Halve the Docker image matrix from six to three — one unified image per PHP version that contains both Nginx + PHP-FPM and the toolchain for `artisan serve`.
2. Make `WEB_SERVER` a real runtime switch with two valid values (`nginx`, `artisan`) and a clear error for anything else.
3. Ship an Nginx configuration that works correctly both behind a reverse proxy and when directly exposed, without requiring the user to edit anything.
4. Expose the most commonly-tuned Nginx knobs (body size, document root, timeouts, trusted proxies) as environment variables so that 90% of customization needs are handled without config edits.
5. Provide a full-config override escape hatch at `/home/container/.nginx/nginx.conf` for power users who want total control.
6. Keep the split of responsibilities clean: the entrypoint owns infrastructure (Redis, FPM, Nginx, log streaming), the egg `STARTUP` command owns application lifecycle (git, composer, npm, migrations, optional `artisan serve`).

## Non-Goals

- **No supervisor / process manager.** PHP-FPM and Nginx run as background daemons alongside the foreground shell loop, same as today. If they crash silently, the container keeps running. Adding `supervisord` or `wait -n`-based lifecycle management is out of scope and can be revisited later.
- **No Laravel Octane support.** The mode switch is specifically between `artisan serve` and `nginx + php-fpm`. Octane is a different execution model and would need its own design.
- **No built-in HTTPS / HTTP/2 in the container.** The deployment model assumes a reverse proxy terminates TLS. Directly exposed containers still work over plain HTTP/1.1 on the allocated port.
- **No rate limiting.** That belongs in the reverse proxy in front of the container, not inside it.
- **No FastCGI response caching.** Laravel apps generally handle their own caching at the application layer.
- **No migration path to maintain the old 6-image tags.** The old `_nginx` suffixed tags stop being built. Existing servers can switch to the new unified tag by changing their image in the panel.

## Design

### Image Architecture

Three Dockerfiles survive the refactor:

```
11/php_82/Dockerfile
11/php_83/Dockerfile
11/php_84/Dockerfile
```

The `11/php_82/nginx/`, `11/php_83/nginx/`, and `11/php_84/nginx/` subdirectories and their Dockerfiles are deleted.

Each surviving Dockerfile installs:

- Base `php:8.X-fpm` image
- System packages: `git curl zip unzip tar sqlite3 libzip-dev libonig-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev iproute2 default-mysql-client redis-server nginx gettext-base` (`gettext-base` provides `envsubst` for config rendering)
- Node.js 20 via NodeSource
- PHP extensions as per each version's existing matrix (8.3 and 8.4 additionally get `sockets ftp`; 8.4 additionally gets `redis` via PECL)
- Composer via `COPY --from=composer:latest`

PHP-FPM is unconditionally reconfigured to run as the `container` user, with PID and error log redirected to `/tmp` (mirroring what the current `nginx/Dockerfile` variant already does):

```dockerfile
RUN useradd -m -d /home/container -s /bin/bash container \
    && mkdir -p /var/lib/nginx /var/log/nginx \
    && chown -R container:container /var/lib/nginx /var/log/nginx \
    && sed -i 's/user = www-data/user = container/g' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/group = www-data/group = container/g' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/;error_log = log\/php-fpm.log/error_log = \/tmp\/php-fpm.log/g' /usr/local/etc/php-fpm.conf \
    && sed -i 's/;pid = run\/php-fpm.pid/pid = \/tmp\/php-fpm.pid/g' /usr/local/etc/php-fpm.conf
```

This runs in the non-nginx images too, which is harmless — PHP-FPM's user change just means it can run under the same process ownership regardless of whether it's actually started.

The Dockerfile still copies `entrypoint.sh` to `/entrypoint.sh` and `etc/nginx/nginx.conf` to `/etc/nginx/nginx.conf` (as a template), and sets `ENTRYPOINT [ "/bin/bash", "/entrypoint.sh" ]`.

### Entrypoint Flow

`entrypoint.sh` is restructured so that infrastructure concerns (Redis, FPM, Nginx rendering, log streaming) are all handled here and the `WEB_SERVER` case-switch is the single source of truth for mode selection.

Rough shape:

```bash
#!/bin/bash
set -e

TZ=${TZ:-UTC}
export TZ

# Port resolution (unchanged)
if [ -n "${SERVER_PORT}" ]; then
    PORT_TO_USE="${SERVER_PORT}"
elif [ -n "${PORT}" ]; then
    PORT_TO_USE="${PORT}"
else
    PORT_TO_USE="8080"
fi
export SERVER_PORT="${PORT_TO_USE}"

INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2);exit}' || echo "127.0.0.1")
export INTERNAL_IP

# Redis (unchanged)
echo -e "\033[1m\033[33m[SETUP] Starting Redis server\033[0m"
redis-server --daemonize yes --bind 127.0.0.1 --protected-mode yes || echo "[ERROR] Failed to start Redis"

# Nginx tunables with defaults
export NGINX_DOCUMENT_ROOT="${NGINX_DOCUMENT_ROOT:-/home/container/public}"
export NGINX_CLIENT_MAX_BODY_SIZE="${NGINX_CLIENT_MAX_BODY_SIZE:-100M}"
export NGINX_WORKER_CONNECTIONS="${NGINX_WORKER_CONNECTIONS:-1024}"
export NGINX_FASTCGI_READ_TIMEOUT="${NGINX_FASTCGI_READ_TIMEOUT:-300}"

WEB_SERVER="${WEB_SERVER:-nginx}"

case "$WEB_SERVER" in
    nginx)
        render_nginx_config
        echo -e "\033[1m\033[33m[SETUP] Starting PHP-FPM\033[0m"
        php-fpm -D
        echo -e "\033[1m\033[33m[SETUP] Starting Nginx\033[0m"
        nginx -c /tmp/nginx.conf
        ;;
    artisan)
        echo -e "\033[1m\033[33m[SETUP] Web server mode: artisan serve (started by STARTUP)\033[0m"
        ;;
    *)
        echo -e "\033[1m\033[31m[ERROR] Unknown WEB_SERVER value '${WEB_SERVER}' (allowed: nginx, artisan)\033[0m"
        exit 1
        ;;
esac

# Log streaming (unchanged)
echo -e "\033[1m\033[33m[SETUP] Streaming Laravel logs\033[0m"
mkdir -p storage/logs
touch storage/logs/laravel.log
tail -f storage/logs/laravel.log &

echo -e "\033[1m\033[32m[SETUP] Laravel environment ready\033[0m"
cd /home/container || exit 1
php -v

PARSED=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo -e "\033[1m\033[33mcontainer@pterodactyl~ \033[0m${PARSED}"
eval "$PARSED"
```

`render_nginx_config` is a bash function defined earlier in the script:

```bash
render_nginx_config() {
    mkdir -p /home/container/.nginx

    # Power-user full override path
    if [ -f /home/container/.nginx/nginx.conf ]; then
        echo -e "\033[1m\033[33m[SETUP] Using custom nginx.conf from /home/container/.nginx/nginx.conf\033[0m"
        envsubst '${SERVER_PORT}' < /home/container/.nginx/nginx.conf > /tmp/nginx.conf
        return
    fi

    # Render trusted-proxies snippet (empty if unset)
    if [ -n "$TRUSTED_PROXIES" ]; then
        {
            for proxy in ${TRUSTED_PROXIES//,/ }; do
                echo "    set_real_ip_from $proxy;"
            done
            echo "    real_ip_header X-Forwarded-For;"
            echo "    real_ip_recursive on;"
        } > /tmp/nginx_realip.conf
    else
        : > /tmp/nginx_realip.conf
    fi

    # Render main config template
    envsubst '${SERVER_PORT} ${NGINX_DOCUMENT_ROOT} ${NGINX_CLIENT_MAX_BODY_SIZE} ${NGINX_WORKER_CONNECTIONS} ${NGINX_FASTCGI_READ_TIMEOUT}' \
        < /etc/nginx/nginx.conf > /tmp/nginx.conf
}
```

Note: `envsubst` is given an explicit allowlist of variables to substitute, so Nginx's own `$uri`, `$query_string`, `$fastcgi_script_name` etc. are preserved verbatim. This is the key trick that makes envsubst safe for Nginx configs.

The egg `STARTUP` command in `egg-laravel.json` is left alone — it already does the right thing:

```
... if [ "$WEB_SERVER" = "artisan" ]; then php artisan serve --host=0.0.0.0 --port="$SERVER_PORT" & fi; while true; do read -r cmd; if [ -n "$cmd" ]; then eval "$cmd"; fi; done;
```

### Nginx Config Template

The new `etc/nginx/nginx.conf` template, rendered by `envsubst` at container start:

```nginx
worker_processes auto;
pid /tmp/nginx.pid;
daemon on;

events {
    worker_connections ${NGINX_WORKER_CONNECTIONS};
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /dev/stdout;
    error_log /dev/stderr;

    client_body_temp_path /tmp/nginx_client_body;
    proxy_temp_path       /tmp/nginx_proxy;
    fastcgi_temp_path     /tmp/nginx_fastcgi;
    uwsgi_temp_path       /tmp/nginx_uwsgi;
    scgi_temp_path        /tmp/nginx_scgi;

    client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript
               image/svg+xml;

    map $http_x_forwarded_proto $https_forwarded {
        https on;
        default off;
    }

    server {
        listen ${SERVER_PORT} default_server;
        server_name _;
        root ${NGINX_DOCUMENT_ROOT};

        include /tmp/nginx_realip.conf;

        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        index index.php;
        charset utf-8;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location = /favicon.ico { access_log off; log_not_found off; }
        location = /robots.txt  { access_log off; log_not_found off; }

        # Long-cache static assets
        location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)$ {
            expires 30d;
            add_header Cache-Control "public, immutable";
            access_log off;
            try_files $uri =404;
        }

        # Block PHP execution under user-writable paths
        location ~ ^/(storage|uploads)/.*\.php$ {
            deny all;
        }

        error_page 404 /index.php;

        location ~ \.php$ {
            fastcgi_split_path_info ^(.+\.php)(/.+)$;
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
            fastcgi_param PATH_INFO $fastcgi_path_info;
            fastcgi_param HTTPS $https_forwarded;
            fastcgi_read_timeout ${NGINX_FASTCGI_READ_TIMEOUT};
            fastcgi_buffers 16 16k;
            fastcgi_buffer_size 32k;
            include fastcgi_params;
        }

        location ~ /\.(?!well-known).* {
            deny all;
        }
    }
}
```

Behavior notes:

- `daemon on;` combined with `nginx -c /tmp/nginx.conf` (no `&`) means Nginx forks off the master and returns control to the script — same effective behavior as the current `daemon off; nginx &` pattern, but cleaner.
- `include /tmp/nginx_realip.conf` is always present; the file is either populated or empty, so the config is valid either way.
- `$https_forwarded` resolves to `on` when the proxy sets `X-Forwarded-Proto: https`, otherwise `off`. Laravel's `TrustProxies` middleware reads the `HTTPS` FastCGI param to decide URL scheme.
- Static asset cache is aggressive (`30d`, `immutable`). Laravel Mix/Vite output is content-hashed so immutable is safe. Users whose apps serve non-hashed asset names should use the full override mechanism to relax or disable this block.

### Config Override Mechanism

One override mechanism only: a complete config replacement.

If `/home/container/.nginx/nginx.conf` exists at container start, the entrypoint uses it instead of the bundled template. The user file still goes through `envsubst` for `${SERVER_PORT}` so that Pelican's dynamic port allocation works, but no other variables are substituted — power users are responsible for their own file in full.

No drop-in snippet mechanism. No partial merging. If you touch the config file, you own the whole thing. This keeps the mental model simple: either you tune via the env var knobs, or you bring your own config.

### Egg JSON Changes

`egg-laravel.json` gets:

1. **Image map reduced to 3 entries:**
   ```json
   "docker_images": {
       "PHP 8.2": "ghcr.io/coho04/pterodactyl-docker-images:laravel_11_php_82",
       "PHP 8.3": "ghcr.io/coho04/pterodactyl-docker-images:laravel_11_php_83",
       "PHP 8.4": "ghcr.io/coho04/pterodactyl-docker-images:laravel_11_php_84"
   }
   ```

2. **`WEB_SERVER` variable description clarified:**
   > Choose the web server for this Laravel application. Use `nginx` (recommended, default) for Nginx + PHP-FPM, or `artisan` for `php artisan serve` (development / simple apps only).

3. **New optional variables** (all `user_viewable: true`, `user_editable: true`, with empty or sensible defaults):
   - `TRUSTED_PROXIES` — comma-separated list of IPs/CIDRs. Leave empty if not behind a reverse proxy.
   - `NGINX_CLIENT_MAX_BODY_SIZE` — default `100M`.
   - `NGINX_DOCUMENT_ROOT` — default `/home/container/public`.
   - `NGINX_FASTCGI_READ_TIMEOUT` — default `300`.

   (`NGINX_WORKER_CONNECTIONS` is not exposed in the egg — it's rarely tuned and the default is fine.)

### README Updates

The `README.md` gets a new section documenting:

- The two `WEB_SERVER` modes and when to pick which
- All Nginx-related env vars with defaults and what they do
- The `/home/container/.nginx/nginx.conf` full-override mechanism, with a worked example of a user bringing their own config
- A note that `TRUSTED_PROXIES` is the thing you almost certainly want to set if the container sits behind Cloudflare/NPM/Traefik

## File Structure After Refactor

```
/
├── 11/
│   ├── php_82/Dockerfile
│   ├── php_83/Dockerfile
│   └── php_84/Dockerfile
├── etc/
│   └── nginx/
│       └── nginx.conf              # envsubst template
├── entrypoint.sh                   # WEB_SERVER case-switch, render_nginx_config
├── egg-laravel.json                # 3 images, new optional vars
├── README.md                       # updated modes + override docs
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-04-11-unified-webserver-design.md
```

Deleted:
- `11/php_82/nginx/`
- `11/php_83/nginx/`
- `11/php_84/nginx/`

## Testing Strategy

Manual verification per PHP version, since CI for Pterodactyl egg images is trust-based and end-to-end validation happens in an actual Pelican panel:

1. **Build all three images locally** via `docker build` and confirm no errors.
2. **Nginx mode smoke test:** Run the image with a tiny Laravel skeleton mounted at `/home/container`, `WEB_SERVER=nginx` (default), curl the port — expect `200` on `/` and a real Laravel response.
3. **Artisan mode smoke test:** Same app, `WEB_SERVER=artisan`, egg STARTUP command runs `php artisan serve`, curl the port — expect `200`.
4. **Invalid mode test:** `WEB_SERVER=garbage` → container exits with the error message, does not silently fall through.
5. **TRUSTED_PROXIES test:** Set `TRUSTED_PROXIES=10.0.0.0/8`, start with `X-Forwarded-For: 1.2.3.4` header and verify PHP sees `1.2.3.4` in `$_SERVER['REMOTE_ADDR']`.
6. **X-Forwarded-Proto test:** Send request with `X-Forwarded-Proto: https` and verify `$_SERVER['HTTPS'] === 'on'` in PHP.
7. **Full override test:** Drop a minimal custom `nginx.conf` at `/home/container/.nginx/nginx.conf`, restart, verify logs show the override message and the custom config is in effect.
8. **Upload test:** POST a 50MB file to an upload endpoint — should succeed with the default `100M` limit.
9. **Static asset cache test:** GET a `.css` file — verify `Cache-Control: public, immutable` and `Expires` headers.

After local smokes pass, publish a pre-release image tag (`laravel_11_php_8X:testing`) and validate in an actual Pelican panel before updating the egg's `docker_images` map to point at the new tags.

## Migration Notes for Existing Users

- Users on old `laravel_11_php_8X_nginx` tags: switch their server's Docker Image in Pelican to the new unified tag. No data changes needed.
- Users on old `laravel_11_php_8X` (artisan) tags: same switch, and set `WEB_SERVER=artisan` to preserve current behavior. If they leave it unset, they'll silently switch to Nginx mode — this is the one behavioral compatibility hazard and should be called out in the README migration note.

## Open Questions

None at this time — all resolved during brainstorming.
