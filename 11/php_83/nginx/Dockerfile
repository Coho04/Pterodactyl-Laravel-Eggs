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

# Install system dependencies
RUN apt-get update -y \
    && apt-get install -y git curl zip unzip tar sqlite3 libzip-dev libonig-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev iproute2 default-mysql-client nginx redis-server \
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
RUN useradd -m -d /home/container -s /bin/bash container
RUN mkdir -p /var/lib/nginx /var/log/nginx \
    && chown -R container:container /var/lib/nginx /var/log/nginx \
    && sed -i 's/user = www-data/user = container/g' /usr/local/etc/php-fpm.d/www.conf \
    && sed -i 's/group = www-data/group = container/g' /usr/local/etc/php-fpm.d/www.conf

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

# Copy the entrypoint script and nginx config
COPY entrypoint.sh /entrypoint.sh
COPY nginx.conf /home/container/nginx.conf

# Set entrypoint
CMD [ "/bin/bash", "/entrypoint.sh" ]
