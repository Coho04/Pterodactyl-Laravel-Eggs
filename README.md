# Pterodactyl-Docker-Images

## Overview

This project contains Docker images for use with Pterodactyl. It includes various versions of Java and PHP, ensuring that the images work on different platforms such as `linux/amd64` and `linux/arm64`.

## Directory Structure

- `.github/workflows/Java.yml`: GitHub Actions workflow for building and publishing the Java Docker images.
- `java/entrypoint.sh`: Entrypoint script executed when the Java container starts.
- `java/21/Dockerfile`: Dockerfile for Java 21.
- `Laravel/entrypoint.sh`: Entrypoint script executed when the Laravel container starts.
- `Laravel/11/Dockerfile`: Dockerfile for Laravel with PHP 8.2.

## Docker Images

The Docker images are automatically built and pushed to the GitHub Container Registry (`ghcr.io`). The tags of the images follow the schema `java_<version>` and `laravel_<version>`.

## Usage

### Running a Docker Image

To run a Docker image, use the following command:

```sh
docker run -it ghcr.io/coho04/pterodactyl-docker-images:java_<version>
```

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

> **Security note:** the `X-Forwarded-Proto` → `HTTPS` mapping trusts the forwarded header unconditionally. If your container is exposed to the public internet without a TLS terminator in front, an attacker can send a forged `X-Forwarded-Proto: https` header and trick Laravel into thinking the request is secure. Always put a reverse proxy in front of public deployments and set `TRUSTED_PROXIES` to the proxy's IP range.

### Full Configuration Override

If the env vars aren't enough, you can drop a complete replacement Nginx config at **`/home/container/.nginx/nginx.conf`** (create the `.nginx` directory via the Pelican file manager if it doesn't exist). When the container starts, it will:

1. Detect the user-supplied file
2. Substitute `${SERVER_PORT}` so Pelican's dynamic port allocation still works
3. Use the file as the complete Nginx configuration, ignoring the bundled template entirely

**Important:** in custom mode only `${SERVER_PORT}` is substituted. None of the other `NGINX_*` environment variables affect a user-supplied config — inline any values you need directly in the file. Also note that `NGINX_DOCUMENT_ROOT` must point to a non-writable directory; serving PHP out of a user-writable location allows uploaded files to be executed.

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