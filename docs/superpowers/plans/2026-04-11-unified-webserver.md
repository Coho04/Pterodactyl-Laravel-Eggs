# Unified Laravel Webserver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the 6-image Docker matrix (3 PHP versions × 2 web server variants) into 3 unified images per PHP version, where `WEB_SERVER` environment variable picks the mode (`nginx` or `artisan`) at runtime, and the bundled Nginx config is tuned for Pelican deployments.

**Architecture:** Three Dockerfiles (`11/php_82/Dockerfile`, `11/php_83/Dockerfile`, `11/php_84/Dockerfile`) each install both Nginx and PHP-FPM plus the tooling for `artisan serve`. `entrypoint.sh` contains a case-switch on `WEB_SERVER` that either starts `php-fpm` + `nginx` (rendering the Nginx config from a template via `envsubst` with a curated allowlist of variables) or does nothing (`artisan` mode, where the egg's `STARTUP` command runs `php artisan serve` itself). Power users can drop a full replacement config at `/home/container/.nginx/nginx.conf`.

**Tech Stack:** Docker, bash, Nginx, PHP-FPM, `envsubst` (from `gettext-base`), Pterodactyl/Pelican egg JSON.

**Reference Spec:** `docs/superpowers/specs/2026-04-11-unified-webserver-design.md`

**Current Repo State:**
- Uncommitted improvements to all six existing Dockerfiles (`CMD` → `ENTRYPOINT`) and to `entrypoint.sh` (colored output, `INTERNAL_IP` fallback, Redis error handling). **Preserve these changes as the baseline** when rewriting files.
- Branch: `main`. Work directly on main since this is an infrastructure refactor.

**Testing Philosophy:** This is a Docker/shell refactor — there are no unit tests. Verification is done via:
1. `bash -n entrypoint.sh` for syntax check of shell scripts
2. `docker build` for Dockerfile validity
3. Manual smoke tests in a running container (Task 8)

Commit after each task so that the git history shows one logical change per commit.

---

## File Structure

**Files to modify:**
- `etc/nginx/nginx.conf` — rewrite as envsubst template with Pelican-tuned settings (Task 1)
- `entrypoint.sh` — rewrite with `WEB_SERVER` case-switch and `render_nginx_config` helper (Task 1)
- `11/php_82/Dockerfile` — merge Nginx install + PHP-FPM reconfig into the base Dockerfile (Task 2)
- `11/php_83/Dockerfile` — same pattern as Task 2 (Task 3)
- `11/php_84/Dockerfile` — same pattern as Task 2, keeping the `pecl install redis` extension (Task 4)
- `egg-laravel.json` — reduce `docker_images` to 3 entries, update `WEB_SERVER` description, add 4 new optional variables (Task 6)
- `README.md` — add web server modes section, env var reference, override docs (Task 7)

**Files/directories to delete:**
- `11/php_82/nginx/` (directory with its `Dockerfile`) (Task 5)
- `11/php_83/nginx/` (directory with its `Dockerfile`) (Task 5)
- `11/php_84/nginx/` (directory with its `Dockerfile`) (Task 5)

**Files to create:** None beyond the plan itself.

---

## Task 1: Rewrite nginx.conf template and entrypoint.sh

This task is the core of the refactor. The two files are tightly coupled (the entrypoint renders the template with `envsubst`), so they land together in one commit.

**Files:**
- Modify: `etc/nginx/nginx.conf` (full rewrite)
- Modify: `entrypoint.sh` (full rewrite, preserving the colored-output and error-handling improvements that are already uncommitted)

- [ ] **Step 1: Rewrite `etc/nginx/nginx.conf` as an envsubst template**

The old file uses `{{SERVER_PORT}}` with a sed substitution. The new file uses `${VAR}` syntax so `envsubst` can render it, and adds Pelican-friendly settings (security headers, static asset caching, X-Forwarded-Proto mapping, FastCGI path info, etc.).

Replace the entire contents of `etc/nginx/nginx.conf` with:

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

        # Long-cache static assets (Laravel Mix/Vite output is content-hashed)
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

**Important:** Do NOT change `$uri`, `$query_string`, `$fastcgi_script_name`, `$realpath_root`, `$http_x_forwarded_proto`, `$https_forwarded`, `$fastcgi_path_info` into `${VAR}` syntax. These are Nginx-internal variables and must stay as `$var`. Only the five template variables (`${SERVER_PORT}`, `${NGINX_DOCUMENT_ROOT}`, `${NGINX_CLIENT_MAX_BODY_SIZE}`, `${NGINX_WORKER_CONNECTIONS}`, `${NGINX_FASTCGI_READ_TIMEOUT}`) use `${}` syntax. The `envsubst` call in the entrypoint uses an explicit allowlist to guarantee this.

- [ ] **Step 2: Rewrite `entrypoint.sh` with WEB_SERVER case-switch**

Replace the entire contents of `entrypoint.sh` with:

```bash
#!/bin/bash

#
# Copyright (c) 2024 Collin Ilgner
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

set -e

# Honour TZ if provided, otherwise default to UTC.
TZ=${TZ:-UTC}
export TZ

# Determine the port that the web server should bind to. Pterodactyl/Pelican
# exposes the primary allocation as SERVER_PORT; some panels use PORT; fall
# back to 8080 if neither is set.
if [ -n "${SERVER_PORT}" ]; then
    PORT_TO_USE="${SERVER_PORT}"
elif [ -n "${PORT}" ]; then
    PORT_TO_USE="${PORT}"
else
    PORT_TO_USE="8080"
fi
export SERVER_PORT="${PORT_TO_USE}"

# Determine the internal Docker IP (used by some applications).
INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2);exit}' || echo "127.0.0.1")
export INTERNAL_IP

# Nginx tunables with sensible defaults. Users can override any of these via
# Pelican environment variables.
export NGINX_DOCUMENT_ROOT="${NGINX_DOCUMENT_ROOT:-/home/container/public}"
export NGINX_CLIENT_MAX_BODY_SIZE="${NGINX_CLIENT_MAX_BODY_SIZE:-100M}"
export NGINX_WORKER_CONNECTIONS="${NGINX_WORKER_CONNECTIONS:-1024}"
export NGINX_FASTCGI_READ_TIMEOUT="${NGINX_FASTCGI_READ_TIMEOUT:-300}"

# Render the Nginx configuration either from the bundled template or from a
# user-provided override at /home/container/.nginx/nginx.conf. The override
# path is given minimal treatment (only SERVER_PORT is substituted) so that
# power users retain full control over the rest of the file.
render_nginx_config() {
    mkdir -p /home/container/.nginx

    if [ -f /home/container/.nginx/nginx.conf ]; then
        echo -e "\033[1m\033[33m[SETUP] Using custom nginx.conf from /home/container/.nginx/nginx.conf\033[0m"
        envsubst '${SERVER_PORT}' < /home/container/.nginx/nginx.conf > /tmp/nginx.conf
        return
    fi

    # Render trusted-proxies snippet. Empty file when TRUSTED_PROXIES is unset
    # so the `include` directive in the main template is always valid.
    if [ -n "${TRUSTED_PROXIES}" ]; then
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

    # Render the main template. The allowlist prevents envsubst from touching
    # Nginx-internal variables like $uri, $query_string, $fastcgi_script_name.
    envsubst '${SERVER_PORT} ${NGINX_DOCUMENT_ROOT} ${NGINX_CLIENT_MAX_BODY_SIZE} ${NGINX_WORKER_CONNECTIONS} ${NGINX_FASTCGI_READ_TIMEOUT}' \
        < /etc/nginx/nginx.conf > /tmp/nginx.conf
}

# Start Redis in the background for cache and queue operations.
echo -e "\033[1m\033[33m[SETUP] Starting Redis server\033[0m"
redis-server --daemonize yes --bind 127.0.0.1 --protected-mode yes || echo "[ERROR] Failed to start Redis"

# Pick the web server mode. Default to nginx. The egg STARTUP command is
# responsible for launching `php artisan serve` in artisan mode; here we only
# handle the nginx/php-fpm side.
WEB_SERVER="${WEB_SERVER:-nginx}"

case "$WEB_SERVER" in
    nginx)
        echo -e "\033[1m\033[33m[SETUP] Rendering Nginx configuration for port ${SERVER_PORT}\033[0m"
        render_nginx_config

        echo -e "\033[1m\033[33m[SETUP] Starting PHP-FPM\033[0m"
        php-fpm -D

        echo -e "\033[1m\033[33m[SETUP] Starting Nginx\033[0m"
        nginx -c /tmp/nginx.conf
        ;;
    artisan)
        echo -e "\033[1m\033[33m[SETUP] Web server mode: artisan serve (launched by STARTUP command)\033[0m"
        ;;
    *)
        echo -e "\033[1m\033[31m[ERROR] Unknown WEB_SERVER value '${WEB_SERVER}' (allowed: nginx, artisan)\033[0m"
        exit 1
        ;;
esac

# Stream Laravel logs to stdout so that they appear in the container logs.
echo -e "\033[1m\033[33m[SETUP] Streaming Laravel logs\033[0m"
mkdir -p storage/logs
touch storage/logs/laravel.log
tail -f storage/logs/laravel.log &

echo -e "\033[1m\033[32m[SETUP] Laravel environment ready\033[0m"

# Change to the application directory. Exit if it does not exist.
cd /home/container || exit 1

# Show PHP version for troubleshooting.
printf "\033[1m\033[33mcontainer@pterodactyl~ \033[0mphp -v\n"
php -v

# Prepare the startup command. The panel passes the command via the STARTUP
# environment variable with double curly braces (e.g. {{SERVER_PORT}}). Convert
# them to shell variable syntax and evaluate.
PARSED=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')

echo -e "\033[1m\033[33mcontainer@pterodactyl~ \033[0m${PARSED}"

# Execute the startup command.
eval "$PARSED"
```

- [ ] **Step 3: Syntax-check the shell script**

Run: `bash -n entrypoint.sh`

Expected: no output (exit code 0). Any syntax error means the file was typed wrong — fix before proceeding.

- [ ] **Step 4: Commit Task 1**

```bash
git add etc/nginx/nginx.conf entrypoint.sh
git commit -m "Rewrite nginx template and entrypoint for unified WEB_SERVER switch

- etc/nginx/nginx.conf becomes an envsubst template with \${VAR} syntax
  for the five tunable knobs (SERVER_PORT, NGINX_DOCUMENT_ROOT,
  NGINX_CLIENT_MAX_BODY_SIZE, NGINX_WORKER_CONNECTIONS,
  NGINX_FASTCGI_READ_TIMEOUT); Nginx-internal vars stay as \$var
- entrypoint.sh gains a WEB_SERVER case-switch (nginx/artisan/error),
  a render_nginx_config helper with a TRUSTED_PROXIES real-ip snippet,
  and support for a full-config override at /home/container/.nginx/nginx.conf
- Config additions: X-Forwarded-Proto -> HTTPS mapping, security headers,
  static asset caching, PHP-execution block under /storage and /uploads,
  fastcgi_split_path_info for PATH_INFO handling, gzip tuning"
```

---

## Task 2: Update `11/php_82/Dockerfile` to unified image

Merge the content from the deprecated `11/php_82/nginx/Dockerfile` into the base `11/php_82/Dockerfile` so the single image contains both Nginx and PHP-FPM. Add `gettext-base` for `envsubst`. Preserve the uncommitted `CMD` → `ENTRYPOINT` change.

**Files:**
- Modify: `11/php_82/Dockerfile` (full rewrite)

- [ ] **Step 1: Replace `11/php_82/Dockerfile` contents**

```dockerfile
#
# Copyright (c) 2024 Collin Ilgner
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

FROM --platform=$TARGETOS/$TARGETARCH php:8.2-fpm

LABEL author="Collin Ilgner" maintainer="cohohohn04@gmail.com"

# Install system dependencies (including Nginx + gettext-base for envsubst)
RUN apt-get update -y \
    && apt-get install -y git curl zip unzip tar sqlite3 libzip-dev libonig-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev iproute2 default-mysql-client nginx redis-server gettext-base \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js and npm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# Install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install pdo pdo_mysql mbstring zip exif pcntl bcmath gd

# Install Composer globally
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Set up the working directory and reconfigure PHP-FPM + Nginx to run as the
# unprivileged `container` user with temp paths under /tmp.
RUN useradd -m -d /home/container -s /bin/bash container \
    && mkdir -p /var/lib/nginx /var/log/nginx \
    && chown -R container:container /var/lib/nginx /var/log/nginx \
    && sed -i 's/user = www-data/user = container/g' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/group = www-data/group = container/g' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/;error_log = log\/php-fpm.log/error_log = \/tmp\/php-fpm.log/g' /usr/local/etc/php-fpm.conf \
    && sed -i 's/;pid = run\/php-fpm.pid/pid = \/tmp\/php-fpm.pid/g' /usr/local/etc/php-fpm.conf

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

# Copy the entrypoint script and Nginx config template
COPY entrypoint.sh /entrypoint.sh
COPY etc/nginx/nginx.conf /etc/nginx/nginx.conf

# Set entrypoint
ENTRYPOINT [ "/bin/bash", "/entrypoint.sh" ]
```

- [ ] **Step 2: Verify the Dockerfile builds**

Run from the repo root:

```bash
docker build -f 11/php_82/Dockerfile -t laravel_11_php_82:test .
```

Expected: build completes with no errors. If it fails on `COPY etc/nginx/nginx.conf` that means the build context is wrong — make sure you run from repo root, not from `11/php_82/`.

- [ ] **Step 3: Commit Task 2**

```bash
git add 11/php_82/Dockerfile
git commit -m "Unify 11/php_82/Dockerfile: install nginx + gettext-base in base image

Merges the content of the (soon-deleted) 11/php_82/nginx/Dockerfile
into the base so one image now serves both WEB_SERVER=nginx and
WEB_SERVER=artisan modes. Adds gettext-base for envsubst so the
entrypoint can render etc/nginx/nginx.conf as a template."
```

---

## Task 3: Update `11/php_83/Dockerfile` to unified image

Same pattern as Task 2 but for PHP 8.3. The PHP extension list includes the extra `sockets ftp` extensions that the 8.3 variant already had.

**Files:**
- Modify: `11/php_83/Dockerfile` (full rewrite)

- [ ] **Step 1: Replace `11/php_83/Dockerfile` contents**

```dockerfile
#
# Copyright (c) 2024 Collin Ilgner
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

FROM --platform=$TARGETOS/$TARGETARCH php:8.3-fpm

LABEL author="Collin Ilgner" maintainer="cohohohn04@gmail.com"

# Install system dependencies (including Nginx + gettext-base for envsubst)
RUN apt-get update -y \
    && apt-get install -y git curl zip unzip tar sqlite3 libzip-dev libonig-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev iproute2 default-mysql-client nginx redis-server gettext-base \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js and npm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# Install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install pdo pdo_mysql mbstring zip exif pcntl bcmath gd sockets ftp

# Install Composer globally
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Set up the working directory and reconfigure PHP-FPM + Nginx to run as the
# unprivileged `container` user with temp paths under /tmp.
RUN useradd -m -d /home/container -s /bin/bash container \
    && mkdir -p /var/lib/nginx /var/log/nginx \
    && chown -R container:container /var/lib/nginx /var/log/nginx \
    && sed -i 's/user = www-data/user = container/g' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/group = www-data/group = container/g' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/;error_log = log\/php-fpm.log/error_log = \/tmp\/php-fpm.log/g' /usr/local/etc/php-fpm.conf \
    && sed -i 's/;pid = run\/php-fpm.pid/pid = \/tmp\/php-fpm.pid/g' /usr/local/etc/php-fpm.conf

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

# Copy the entrypoint script and Nginx config template
COPY entrypoint.sh /entrypoint.sh
COPY etc/nginx/nginx.conf /etc/nginx/nginx.conf

# Set entrypoint
ENTRYPOINT [ "/bin/bash", "/entrypoint.sh" ]
```

- [ ] **Step 2: Verify the Dockerfile builds**

Run from the repo root:

```bash
docker build -f 11/php_83/Dockerfile -t laravel_11_php_83:test .
```

Expected: build completes with no errors.

- [ ] **Step 3: Commit Task 3**

```bash
git add 11/php_83/Dockerfile
git commit -m "Unify 11/php_83/Dockerfile: install nginx + gettext-base in base image

Same pattern as the PHP 8.2 unification; retains the sockets + ftp
PHP extensions that are specific to the 8.3 variant."
```

---

## Task 4: Update `11/php_84/Dockerfile` to unified image

Same pattern as Tasks 2 and 3 but for PHP 8.4. Retains the `pecl install redis` + `docker-php-ext-enable redis` steps that the 8.4 variant already had.

**Files:**
- Modify: `11/php_84/Dockerfile` (full rewrite)

- [ ] **Step 1: Replace `11/php_84/Dockerfile` contents**

```dockerfile
#
# Copyright (c) 2024 Collin Ilgner
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

FROM --platform=$TARGETOS/$TARGETARCH php:8.4-fpm

LABEL author="Collin Ilgner" maintainer="cohohohn04@gmail.com"

# Install system dependencies (including Nginx + gettext-base for envsubst)
RUN apt-get update -y \
    && apt-get install -y git curl zip unzip tar sqlite3 libzip-dev libonig-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev iproute2 default-mysql-client nginx redis-server gettext-base \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js and npm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# Install PHP extensions (including the Redis extension via PECL)
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install pdo pdo_mysql mbstring zip exif pcntl bcmath gd sockets ftp \
    && pecl install redis \
    && docker-php-ext-enable redis

# Install Composer globally
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Set up the working directory and reconfigure PHP-FPM + Nginx to run as the
# unprivileged `container` user with temp paths under /tmp.
RUN useradd -m -d /home/container -s /bin/bash container \
    && mkdir -p /var/lib/nginx /var/log/nginx \
    && chown -R container:container /var/lib/nginx /var/log/nginx \
    && sed -i 's/user = www-data/user = container/g' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/group = www-data/group = container/g' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/;error_log = log\/php-fpm.log/error_log = \/tmp\/php-fpm.log/g' /usr/local/etc/php-fpm.conf \
    && sed -i 's/;pid = run\/php-fpm.pid/pid = \/tmp\/php-fpm.pid/g' /usr/local/etc/php-fpm.conf

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

# Copy the entrypoint script and Nginx config template
COPY entrypoint.sh /entrypoint.sh
COPY etc/nginx/nginx.conf /etc/nginx/nginx.conf

# Set entrypoint
ENTRYPOINT [ "/bin/bash", "/entrypoint.sh" ]
```

- [ ] **Step 2: Verify the Dockerfile builds**

Run from the repo root:

```bash
docker build -f 11/php_84/Dockerfile -t laravel_11_php_84:test .
```

Expected: build completes with no errors. `pecl install redis` can take a minute — that's normal.

- [ ] **Step 3: Commit Task 4**

```bash
git add 11/php_84/Dockerfile
git commit -m "Unify 11/php_84/Dockerfile: install nginx + gettext-base in base image

Same pattern as the PHP 8.2 / 8.3 unification; retains the pecl redis
extension install + enable that is specific to the 8.4 variant."
```

---

## Task 5: Delete deprecated `nginx/` subdirectories

The `11/php_82/nginx/`, `11/php_83/nginx/`, and `11/php_84/nginx/` directories and their Dockerfiles are no longer needed because their content has been absorbed into the unified base Dockerfiles.

**Files:**
- Delete: `11/php_82/nginx/Dockerfile` (and the now-empty `11/php_82/nginx/` directory)
- Delete: `11/php_83/nginx/Dockerfile` (and the now-empty `11/php_83/nginx/` directory)
- Delete: `11/php_84/nginx/Dockerfile` (and the now-empty `11/php_84/nginx/` directory)

- [ ] **Step 1: Remove the old Dockerfiles via git**

```bash
git rm 11/php_82/nginx/Dockerfile
git rm 11/php_83/nginx/Dockerfile
git rm 11/php_84/nginx/Dockerfile
```

- [ ] **Step 2: Remove the now-empty directories**

```bash
rmdir 11/php_82/nginx 11/php_83/nginx 11/php_84/nginx
```

Expected: empty directories are removed. If `rmdir` complains that a directory is not empty, list its contents (`ls -la 11/php_XX/nginx`) — there shouldn't be anything there after `git rm`.

- [ ] **Step 3: Verify only the base Dockerfiles remain**

Run: `ls 11/php_82 11/php_83 11/php_84`

Expected output: each directory contains only `Dockerfile`, no `nginx/` subdirectory.

- [ ] **Step 4: Commit Task 5**

```bash
git commit -m "Remove deprecated 11/php_XX/nginx/Dockerfiles

These stand-alone nginx variants have been superseded by unified
images that carry both nginx and the artisan-serve toolchain.
The WEB_SERVER environment variable now picks the mode at runtime."
```

---

## Task 6: Update `egg-laravel.json`

Reduce `docker_images` from 6 entries to 3, update the `WEB_SERVER` variable description to reflect the runtime switch, and add four new optional variables that expose the Nginx knobs.

**Files:**
- Modify: `egg-laravel.json`

- [ ] **Step 1: Update `docker_images` map**

Find the `docker_images` block in `egg-laravel.json` and replace it with:

```json
  "docker_images": {
    "PHP 8.2": "ghcr.io/coho04/pterodactyl-docker-images:laravel_11_php_82",
    "PHP 8.3": "ghcr.io/coho04/pterodactyl-docker-images:laravel_11_php_83",
    "PHP 8.4": "ghcr.io/coho04/pterodactyl-docker-images:laravel_11_php_84"
  },
```

(This removes the `_nginx` tag entries entirely; users switch modes via `WEB_SERVER`.)

- [ ] **Step 2: Update the `WEB_SERVER` variable description**

Find the existing `WEB_SERVER` variable object inside `variables` and replace the `description` field with:

```json
"description": "Choose the web server. Use 'nginx' (recommended, default) for Nginx + PHP-FPM, or 'artisan' for `php artisan serve` (development / simple apps). Changes take effect on server restart.",
```

Leave `default_value`, `rules`, and the other fields unchanged (`default_value` stays `"nginx"`, `rules` stays `"required|string|in:nginx,artisan"`).

- [ ] **Step 3: Add four new optional variables**

Append the following four variable objects to the `variables` array (after the existing `WEB_SERVER` entry, before the closing `]`):

```json
    {
      "name": "Trusted Proxies",
      "description": "Comma-separated list of proxy IPs or CIDR ranges that are allowed to set X-Forwarded-* headers (e.g. '10.0.0.0/8,172.16.0.0/12'). Leave empty if the container is exposed directly. Required for correct client IP detection behind Cloudflare, Nginx Proxy Manager, Traefik, etc.",
      "env_variable": "TRUSTED_PROXIES",
      "default_value": "",
      "user_viewable": true,
      "user_editable": true,
      "rules": "nullable|string",
      "field_type": "text"
    },
    {
      "name": "Nginx Max Upload Size",
      "description": "Maximum request body size Nginx will accept (e.g. '100M', '500M', '1G'). Controls Laravel file upload size limits at the web server layer.",
      "env_variable": "NGINX_CLIENT_MAX_BODY_SIZE",
      "default_value": "100M",
      "user_viewable": true,
      "user_editable": true,
      "rules": "required|string",
      "field_type": "text"
    },
    {
      "name": "Nginx Document Root",
      "description": "Directory Nginx serves as the document root. Defaults to Laravel's public/ directory. Change only if your application structure is non-standard.",
      "env_variable": "NGINX_DOCUMENT_ROOT",
      "default_value": "/home/container/public",
      "user_viewable": true,
      "user_editable": true,
      "rules": "required|string",
      "field_type": "text"
    },
    {
      "name": "Nginx FastCGI Read Timeout",
      "description": "Seconds Nginx will wait for a PHP-FPM response before timing out. Increase for long-running requests like imports or reports.",
      "env_variable": "NGINX_FASTCGI_READ_TIMEOUT",
      "default_value": "300",
      "user_viewable": true,
      "user_editable": true,
      "rules": "required|integer|min:1",
      "field_type": "text"
    }
```

Make sure each new object except the last is followed by a comma, and the closing `]` of the `variables` array is still in place.

- [ ] **Step 4: Validate the JSON**

Run: `python3 -m json.tool egg-laravel.json > /dev/null`

Expected: no output (exit code 0). If it reports a parse error, fix the trailing comma / syntax issue before committing.

- [ ] **Step 5: Commit Task 6**

```bash
git add egg-laravel.json
git commit -m "Update egg-laravel.json for unified image matrix

- Reduce docker_images to 3 entries (PHP 8.2 / 8.3 / 8.4); drop the
  now-deprecated _nginx tag variants
- Clarify the WEB_SERVER variable description to reflect the runtime
  switch between nginx and artisan modes
- Add four new optional variables: TRUSTED_PROXIES,
  NGINX_CLIENT_MAX_BODY_SIZE, NGINX_DOCUMENT_ROOT, and
  NGINX_FASTCGI_READ_TIMEOUT, all exposed in the panel UI"
```

---

## Task 7: Update `README.md`

Document the two `WEB_SERVER` modes, the new Nginx env vars, and the full-override mechanism.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read current README to locate the right insertion point**

Run: `cat README.md` (or use your editor's Read tool) and identify where to insert the new section. Look for a configuration/usage section that makes sense to extend. If no such section exists, append at the bottom before any contact/license section.

- [ ] **Step 2: Add the new "Web Server Modes" section**

Insert the following content into `README.md` at the appropriate place (a good spot is directly after any existing installation/usage section, or at the bottom of the file if the README is short):

````markdown
## Web Server Modes

Each Laravel image ships with both **Nginx + PHP-FPM** and **`php artisan serve`**. Pick which one runs via the `WEB_SERVER` environment variable in the Pelican panel:

| `WEB_SERVER` | Web Server | When to use |
|---|---|---|
| `nginx` (default) | Nginx + PHP-FPM | Production, staging, anything public-facing |
| `artisan` | `php artisan serve` | Quick dev instances, simple single-process apps |

Changes take effect on server restart.

## Nginx Configuration

The bundled Nginx configuration is tuned for the typical Pelican deployment (behind a reverse proxy like Cloudflare, Nginx Proxy Manager, or Traefik). Most users only need to adjust a handful of environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `TRUSTED_PROXIES` | *(empty)* | Comma-separated proxy IPs/CIDRs that are allowed to set `X-Forwarded-*` headers. **Set this if the container sits behind a reverse proxy**, otherwise Laravel will see the proxy IP as the client IP. Example: `10.0.0.0/8,172.16.0.0/12`. |
| `NGINX_CLIENT_MAX_BODY_SIZE` | `100M` | Max request body size. Raise this for apps that handle large file uploads. |
| `NGINX_DOCUMENT_ROOT` | `/home/container/public` | Document root served by Nginx. Change only for non-standard Laravel layouts. |
| `NGINX_FASTCGI_READ_TIMEOUT` | `300` | Seconds Nginx waits for PHP-FPM. Raise for long-running requests. |
| `NGINX_WORKER_CONNECTIONS` | `1024` | Max connections per Nginx worker. Rarely needs tuning. |

HTTPS detection works automatically when the reverse proxy forwards `X-Forwarded-Proto: https` — Laravel's `request()->isSecure()` will return `true` and URL generation will produce `https://` links.

### Full Configuration Override

If the env vars aren't enough, you can drop a complete replacement Nginx config at **`/home/container/.nginx/nginx.conf`** (create the `.nginx` directory via the Pelican file manager if it doesn't exist). When the container starts, it will:

1. Detect the user-supplied file
2. Substitute `${SERVER_PORT}` so Pelican's dynamic port allocation still works
3. Use the file as the complete Nginx configuration, ignoring the bundled template entirely

All other Nginx environment variables are **not** applied to a user-supplied config — if you override, you own the whole file.

Example minimal override:

```nginx
worker_processes auto;
pid /tmp/nginx.pid;
daemon on;

events { worker_connections 1024; }

http {
    include /etc/nginx/mime.types;
    access_log /dev/stdout;
    error_log /dev/stderr;

    client_body_temp_path /tmp/nginx_client_body;
    fastcgi_temp_path     /tmp/nginx_fastcgi;

    server {
        listen ${SERVER_PORT} default_server;
        root /home/container/public;
        index index.php;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~ \.php$ {
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
            include fastcgi_params;
        }
    }
}
```

### Migration from Legacy `_nginx` Tags

Earlier versions of this egg shipped separate `laravel_11_php_8X_nginx` and `laravel_11_php_8X` (artisan) Docker image tags. Those tags are no longer built. To migrate an existing server:

1. Update the Docker Image in the Pelican panel to the new unified tag (`laravel_11_php_82`, `laravel_11_php_83`, or `laravel_11_php_84`).
2. If you were using the artisan-only tag, set `WEB_SERVER=artisan` on the server so it keeps running `php artisan serve`. **The default is `nginx`, so if you leave `WEB_SERVER` unset your server will silently switch to Nginx mode on restart.**
3. Restart the server.
````

- [ ] **Step 3: Commit Task 7**

```bash
git add README.md
git commit -m "Document WEB_SERVER modes and Nginx configuration in README

Adds three new sections:
- Web Server Modes table (nginx vs artisan, when to use each)
- Nginx Configuration env var reference with Pelican-specific notes
  on TRUSTED_PROXIES and reverse-proxy HTTPS detection
- Full Configuration Override docs explaining the
  /home/container/.nginx/nginx.conf escape hatch, plus migration
  notes for users on the legacy _nginx image tags"
```

---

## Task 8: Local smoke tests

No unit tests exist for this project. Validate the refactor manually by running each built image through a minimal scenario and verifying the observable behavior matches the spec's Testing Strategy section.

**Prerequisites:**
- All three images built successfully in Tasks 2-4 (tags `laravel_11_php_82:test`, `laravel_11_php_83:test`, `laravel_11_php_84:test`)
- A tiny Laravel skeleton to bind-mount. You can use a fresh `composer create-project laravel/laravel laravel-smoke` in a scratch directory, or any existing Laravel app.

**This task does NOT commit anything.** It's pure validation. If any test fails, stop and diagnose before considering the implementation complete.

- [ ] **Step 1: Prepare a Laravel skeleton for smoke testing**

```bash
cd /tmp
composer create-project --prefer-dist laravel/laravel laravel-smoke
cd laravel-smoke
php artisan key:generate
```

Expected: a working Laravel install at `/tmp/laravel-smoke` with `public/index.php` and a generated `APP_KEY`.

- [ ] **Step 2: Nginx mode smoke test (PHP 8.2)**

```bash
docker run --rm -d --name laravel-smoke \
  -p 8080:8080 \
  -e SERVER_PORT=8080 \
  -e STARTUP='while true; do sleep 3600; done' \
  -v /tmp/laravel-smoke:/home/container \
  laravel_11_php_82:test

sleep 3
curl -sI http://localhost:8080/ | head -1
docker logs laravel-smoke 2>&1 | tail -20
docker stop laravel-smoke
```

Expected: `HTTP/1.1 200 OK` (or a Laravel welcome response). Logs should contain `[SETUP] Starting Nginx` and no error lines. If `502 Bad Gateway`, PHP-FPM didn't start or the socket path is wrong — check `docker logs` for fpm errors.

- [ ] **Step 3: Artisan mode smoke test (PHP 8.2)**

```bash
docker run --rm -d --name laravel-smoke \
  -p 8081:8081 \
  -e SERVER_PORT=8081 \
  -e WEB_SERVER=artisan \
  -e STARTUP='php artisan serve --host=0.0.0.0 --port=$SERVER_PORT & while true; do sleep 3600; done' \
  -v /tmp/laravel-smoke:/home/container \
  laravel_11_php_82:test

sleep 3
curl -sI http://localhost:8081/ | head -1
docker logs laravel-smoke 2>&1 | tail -20
docker stop laravel-smoke
```

Expected: `HTTP/1.1 200 OK`. Logs should contain `[SETUP] Web server mode: artisan serve` and no Nginx startup lines.

- [ ] **Step 4: Invalid mode test**

```bash
docker run --rm --name laravel-smoke \
  -e SERVER_PORT=8080 \
  -e WEB_SERVER=garbage \
  -e STARTUP='echo hi' \
  -v /tmp/laravel-smoke:/home/container \
  laravel_11_php_82:test
```

Expected: container exits non-zero with the exact log line `[ERROR] Unknown WEB_SERVER value 'garbage' (allowed: nginx, artisan)`.

- [ ] **Step 5: TRUSTED_PROXIES smoke test**

```bash
docker run --rm -d --name laravel-smoke \
  -p 8080:8080 \
  -e SERVER_PORT=8080 \
  -e TRUSTED_PROXIES='10.0.0.0/8,172.16.0.0/12' \
  -e STARTUP='while true; do sleep 3600; done' \
  -v /tmp/laravel-smoke:/home/container \
  laravel_11_php_82:test

sleep 3
docker exec laravel-smoke cat /tmp/nginx_realip.conf
docker stop laravel-smoke
```

Expected: the file should contain the two `set_real_ip_from` lines plus `real_ip_header X-Forwarded-For;` and `real_ip_recursive on;`. If the file is empty, the `TRUSTED_PROXIES` branch in `render_nginx_config` isn't firing — re-check the env var name in `entrypoint.sh`.

- [ ] **Step 6: X-Forwarded-Proto smoke test**

```bash
docker run --rm -d --name laravel-smoke \
  -p 8080:8080 \
  -e SERVER_PORT=8080 \
  -e STARTUP='while true; do sleep 3600; done' \
  -v /tmp/laravel-smoke:/home/container \
  laravel_11_php_82:test

sleep 3
# Create a tiny probe script that echoes $_SERVER['HTTPS']
docker exec laravel-smoke bash -c 'echo "<?php echo \$_SERVER[\"HTTPS\"] ?? \"off\"; " > /home/container/public/probe.php'
curl -s -H 'X-Forwarded-Proto: https' http://localhost:8080/probe.php
echo
curl -s http://localhost:8080/probe.php
echo
docker exec laravel-smoke rm /home/container/public/probe.php
docker stop laravel-smoke
```

Expected output: first curl returns `on`, second returns `off`. If both return `off`, the `map` block or the `fastcgi_param HTTPS` line is wrong in the Nginx template.

- [ ] **Step 7: Full override smoke test**

```bash
mkdir -p /tmp/laravel-smoke/.nginx
cat > /tmp/laravel-smoke/.nginx/nginx.conf <<'EOF'
worker_processes auto;
pid /tmp/nginx.pid;
daemon on;
events { worker_connections 256; }
http {
    include /etc/nginx/mime.types;
    access_log /dev/stdout;
    error_log /dev/stderr;
    client_body_temp_path /tmp/nginx_client_body;
    fastcgi_temp_path /tmp/nginx_fastcgi;
    server {
        listen ${SERVER_PORT} default_server;
        add_header X-Override-Active "yes";
        root /home/container/public;
        index index.php;
        location / { try_files $uri $uri/ /index.php?$query_string; }
        location ~ \.php$ {
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
            include fastcgi_params;
        }
    }
}
EOF

docker run --rm -d --name laravel-smoke \
  -p 8080:8080 \
  -e SERVER_PORT=8080 \
  -e STARTUP='while true; do sleep 3600; done' \
  -v /tmp/laravel-smoke:/home/container \
  laravel_11_php_82:test

sleep 3
curl -sI http://localhost:8080/ | grep -i x-override
docker logs laravel-smoke 2>&1 | grep -i 'custom nginx.conf'
docker stop laravel-smoke
rm -rf /tmp/laravel-smoke/.nginx
```

Expected: curl returns a line containing `X-Override-Active: yes`, and the docker logs contain `[SETUP] Using custom nginx.conf from /home/container/.nginx/nginx.conf`.

- [ ] **Step 8: Repeat the nginx mode smoke test for PHP 8.3 and 8.4**

```bash
# PHP 8.3
docker run --rm -d --name laravel-smoke -p 8080:8080 \
  -e SERVER_PORT=8080 -e STARTUP='while true; do sleep 3600; done' \
  -v /tmp/laravel-smoke:/home/container laravel_11_php_83:test
sleep 3 && curl -sI http://localhost:8080/ | head -1 && docker stop laravel-smoke

# PHP 8.4
docker run --rm -d --name laravel-smoke -p 8080:8080 \
  -e SERVER_PORT=8080 -e STARTUP='while true; do sleep 3600; done' \
  -v /tmp/laravel-smoke:/home/container laravel_11_php_84:test
sleep 3 && curl -sI http://localhost:8080/ | head -1 && docker stop laravel-smoke
```

Expected: both return `HTTP/1.1 200 OK`.

- [ ] **Step 9: Clean up test images**

```bash
docker rmi laravel_11_php_82:test laravel_11_php_83:test laravel_11_php_84:test
rm -rf /tmp/laravel-smoke
```

- [ ] **Step 10: Final sanity check — view the completed commit history**

Run: `git log --oneline -n 10`

Expected: seven new commits (one per Task 1-7) plus the earlier spec commit and any pre-existing commits. Verify the commit messages match the task numbering and tell a coherent story.

---

## Completion Criteria

The plan is complete when:

1. All 7 implementation commits are landed (Tasks 1-7)
2. All 9 smoke test steps in Task 8 pass as described
3. `git status` is clean (no uncommitted changes besides possibly untracked test artifacts outside the repo)
4. The spec at `docs/superpowers/specs/2026-04-11-unified-webserver-design.md` has no requirement that isn't addressed by the commits

After completion, a follow-up step (not in this plan) is to publish the new image tags via the existing `ghcr.io/coho04/pterodactyl-docker-images` CI pipeline. The `egg-laravel.json` `docker_images` map already points at the expected tag names.
