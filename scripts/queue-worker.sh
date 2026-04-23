#!/bin/bash
# Wait for the application to be deployed before starting the queue worker.
# The STARTUP command handles git clone, composer install, and migrations —
# artisan won't exist until that finishes.

while [ ! -f /home/container/artisan ]; do
    sleep 2
done

exec php artisan queue:work "${QUEUE_CONNECTION:-redis}" --sleep=3 --tries=3 --max-time=3600
