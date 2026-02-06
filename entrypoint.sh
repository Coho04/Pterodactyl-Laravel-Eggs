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

# Default the TZ environment variable to UTC.
TZ=${TZ:-UTC}
export TZ

# Set environment variable that holds the Internal Docker IP
INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

# Start Redis in the background
echo "[SETUP] Starting Redis server"
redis-server --daemonize yes --bind 127.0.0.1 --protected-mode yes

# Start PHP-FPM and Nginx if WEB_SERVER is set to nginx (default)
if [ "${WEB_SERVER}" = "nginx" ] || [ -z "${WEB_SERVER}" ]; then
    if command -v nginx > /dev/null 2>&1; then
        echo "[SETUP] Starting PHP-FPM"
        php-fpm -D

        echo "[SETUP] Configuring Nginx"
        sed -i "s/8080/${SERVER_PORT}/g" /home/container/nginx.conf

        echo "[SETUP] Starting Nginx"
        nginx -c /home/container/nginx.conf &
    else
        echo "[SETUP] Nginx not installed, skipping Nginx startup"
    fi
fi

# Stream Laravel logs
echo "[SETUP] Streaming Laravel logs"
mkdir -p storage/logs
touch storage/logs/laravel.log
tail -f storage/logs/laravel.log &

echo "[SETUP] Laravel environment ready"

# Switch to the container's working directory
cd /home/container || exit 1

# Print PHP version
printf "\033[1m\033[33mcontainer@pterodactyl~ \033[0mphp -v\n"
php -v

# Convert all of the "{{VARIABLE}}" parts of the command into the expected shell
# variable format of "${VARIABLE}" before evaluating the string and automatically
# replacing the values.
PARSED=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')

# Display the command we're running in the output
printf "\033[1m\033[33mcontainer@pterodactyl~ \033[0m%s\n" "$PARSED"

# Execute the parsed startup command
eval "$PARSED"
