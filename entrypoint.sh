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

# Determine the port that the web server should bind to.  In Pterodactyl
# and Pelican environments the primary allocation port is exposed as
# an environment variable called SERVER_PORT.  However some panels use
# PORT instead.  To handle both cases, fall back to PORT and finally
# to 8080 if neither is defined.
if [ -n "${SERVER_PORT}" ]; then
    PORT_TO_USE="${SERVER_PORT}"
elif [ -n "${PORT}" ]; then
    PORT_TO_USE="${PORT}"
else
    PORT_TO_USE="8080"
fi
export SERVER_PORT="${PORT_TO_USE}"

# Determine the internal Docker IP (used by some applications).  This uses
# iproute2 to retrieve the local gateway address.
INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

# Start Redis in the background for cache and queue operations.
echo "[SETUP] Starting Redis server"
redis-server --daemonize yes --bind 127.0.0.1 --protected-mode yes

# If WEB_SERVER is unset or explicitly set to "nginx", start PHP‑FPM and Nginx.
if [ "${WEB_SERVER}" = "nginx" ] || [ -z "${WEB_SERVER}" ]; then
    if command -v nginx > /dev/null 2>&1; then
        echo "[SETUP] Starting PHP-FPM"
        # Launch PHP‑FPM as a daemon.  The PHP‑FPM configuration is adjusted
        # in the Dockerfile to run as the non‑root `container` user.
        php-fpm -D

        echo "[SETUP] Configuring Nginx for port ${SERVER_PORT}"
        # Copy the bundled nginx.conf and replace the port placeholder with
        # the actual port.  This substitution happens here rather than at
        # build time so that it can react to environment variables provided
        # by the panel.
        if [ -f /etc/nginx/nginx.conf ]; then
            cp /etc/nginx/nginx.conf /tmp/nginx.conf
        else
            echo "[ERROR] Nginx configuration not found at /etc/nginx/nginx.conf"
            exit 1
        fi
        sed -i "s/{{SERVER_PORT}}/${SERVER_PORT}/g" /tmp/nginx.conf

        echo "[SETUP] Starting Nginx"
        # Start Nginx with the customised configuration.  The `daemon off` directive
        # in nginx.conf ensures that the process stays in the foreground, and we
        # run it in the background so that the script can continue.
        nginx -c /tmp/nginx.conf &
    else
        echo "[SETUP] Nginx not installed, skipping Nginx startup"
    fi
fi

# Stream Laravel logs to stdout so that they appear in the container logs.
echo "[SETUP] Streaming Laravel logs"
mkdir -p storage/logs
touch storage/logs/laravel.log
tail -f storage/logs/laravel.log &

echo "[SETUP] Laravel environment ready"

# Change to the application directory.  If it does not exist, exit to avoid
# executing the startup command from an unexpected location.
cd /home/container || exit 1

# Show PHP version for troubleshooting.
printf "\033[1m\033[33mcontainer@pterodactyl~ \033[0mphp -v\n"
php -v

# Prepare the startup command.  The panel passes the command via the
# STARTUP environment variable with double curly braces (e.g. {{SERVER_PORT}}).
# Convert double braces to shell variable syntax and then evaluate it.
PARSED=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')

# Show the command that will be executed.
printf "\033[1m\033[33mcontainer@pterodactyl~ \033[0m%s\n" "$PARSED"

# Execute the startup command.
eval "$PARSED"
