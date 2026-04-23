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

# Queue tunables.
export QUEUE_WORKER="${QUEUE_WORKER:-true}"
export QUEUE_CONNECTION="${QUEUE_CONNECTION:-redis}"

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
            IFS=',' read -ra _trusted_proxies <<< "$TRUSTED_PROXIES"
            for proxy in "${_trusted_proxies[@]}"; do
                # Trim leading/trailing whitespace
                proxy="${proxy#"${proxy%%[![:space:]]*}"}"
                proxy="${proxy%"${proxy##*[![:space:]]}"}"
                [ -z "$proxy" ] && continue
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

# ---------------------------------------------------------------------------
# Assemble the Supervisor configuration. Nginx + PHP-FPM + Redis are always
# started; the queue worker is optional.
# ---------------------------------------------------------------------------
mkdir -p /tmp/supervisor.d

echo -e "\033[1m\033[33m[SETUP] Rendering Nginx configuration for port ${SERVER_PORT}\033[0m"
render_nginx_config

cp /etc/supervisor/conf.d/redis.conf /tmp/supervisor.d/
cp /etc/supervisor/conf.d/nginx.conf /tmp/supervisor.d/
cp /etc/supervisor/conf.d/php-fpm.conf /tmp/supervisor.d/

if [ "$QUEUE_WORKER" = "true" ]; then
    echo -e "\033[1m\033[33m[SETUP] Queue worker enabled (connection: ${QUEUE_CONNECTION})\033[0m"
    cp /etc/supervisor/conf.d/queue-worker.conf /tmp/supervisor.d/
fi

# Start Supervisor (background). It manages redis, nginx, php-fpm, queue-worker.
echo -e "\033[1m\033[33m[SETUP] Starting Supervisor\033[0m"
supervisord -c /etc/supervisor/supervisord.conf

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
