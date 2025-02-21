#
# Copyright (c) 2024 Collin Ilgner
#

FROM --platform=$TARGETOS/$TARGETARCH php:8.3-fpm

LABEL author="Collin Ilgner" maintainer="cohohohn04@gmail.com"

# Install system dependencies
RUN apt-get update -y \
    && apt-get install -y git curl zip unzip tar sqlite3 libzip-dev libonig-dev \
    libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev iproute2 nginx supervisor \
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

# Set up the working directory
USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

# Copy configuration files
COPY nginx.conf /etc/nginx/nginx.conf
#COPY supervisord.conf /etc/supervisord.conf

# Expose ports
EXPOSE 80

# Set up entrypoint script
COPY ./../entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/bin/bash", "/entrypoint.sh"]
