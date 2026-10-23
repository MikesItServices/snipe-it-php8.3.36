# Snipe-IT on the official PHP image, pinned to PHP 8.3.36
# Build context must be the root of the Snipe-IT source repo (it COPYs . and docker/*)
FROM php:8.3.36-apache

ENV DEBIAN_FRONTEND=noninteractive

# System packages + build deps for PHP extensions
RUN apt-get update -qq \
 && apt-get install -qqy --no-install-recommends \
      $PHPIZE_DEPS \
      libldap2-dev \
      libldap-common \
      libpng-dev \
      libjpeg62-turbo-dev \
      libfreetype6-dev \
      libzip-dev \
      libmemcached-dev \
      zlib1g-dev \
      libssl-dev \
      pkg-config \
      patch \
      curl \
      wget \
      vim \
      git \
      cron \
      mariadb-client \
      supervisor \
      ca-certificates \
      unzip \
      dnsutils \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-configure ldap --with-libdir=lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH) \
 && docker-php-ext-install -j"$(nproc)" ldap pdo_mysql mysqli gd zip bcmath exif \
 && pecl install redis memcached \
 && docker-php-ext-enable redis memcached \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
# curl, mbstring, xml, dom, fileinfo, etc. are already compiled into the official image

# php.ini (official image ships none; one file covers Apache + CLI)
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
 && sed -i 's/^variables_order = .*/variables_order = "EGPCS"/' "$PHP_INI_DIR/php.ini"

# Run Apache as uid 10000 / group staff (same as upstream Snipe-IT image)
RUN useradd -m --uid 10000 --gid 50 docker \
 && echo 'export APACHE_RUN_USER=docker' >> /etc/apache2/envvars \
 && echo 'export APACHE_RUN_GROUP=staff' >> /etc/apache2/envvars

# Apache site config (replace the official image's default site)
RUN rm -f /etc/apache2/sites-enabled/000-default.conf
COPY docker/000-default.conf /etc/apache2/sites-enabled/000-default.conf

# SSL
RUN mkdir -p /var/lib/snipeit/ssl
COPY docker/001-default-ssl.conf /etc/apache2/sites-available/001-default-ssl.conf
RUN a2enmod ssl rewrite && a2ensite 001-default-ssl.conf

# Apache limits
COPY docker/apache-limits.conf /etc/apache2/conf-available/limits.conf
RUN a2enconf limits

RUN mkdir -p /etc/mysql/conf.d
COPY docker/column-statistics.cnf /etc/mysql/conf.d/column-statistics.cnf

############ APPLICATION #####################
COPY . /var/www/html
WORKDIR /var/www/html

COPY docker/docker.env /var/www/html/.env
RUN chown -R docker /var/www/html

RUN rm -r "/var/www/html/storage/private_uploads" && ln -fs "/var/lib/snipeit/data/private_uploads" "/var/www/html/storage/private_uploads" \
 && rm -rf "/var/www/html/public/uploads" && ln -fs "/var/lib/snipeit/data/uploads" "/var/www/html/public/uploads" \
 && rm -r "/var/www/html/storage/app/backups" && ln -fs "/var/lib/snipeit/dumps" "/var/www/html/storage/app/backups" \
 && mkdir -p "/var/lib/snipeit/keys" && ln -fs "/var/lib/snipeit/keys/oauth-private.key" "/var/www/html/storage/oauth-private.key" \
 && ln -fs "/var/lib/snipeit/keys/oauth-public.key" "/var/www/html/storage/oauth-public.key" \
 && ln -fs "/var/lib/snipeit/keys/ldap_client_tls.cert" "/var/www/html/storage/ldap_client_tls.cert" \
 && ln -fs "/var/lib/snipeit/keys/ldap_client_tls.key" "/var/www/html/storage/ldap_client_tls.key" \
 && chown docker "/var/lib/snipeit/keys/" \
 && chown -Rh docker "/var/www/html/storage/" \
 && chmod +x /var/www/html/artisan

############ COMPOSER #####################
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer
USER docker
RUN COMPOSER_CACHE_DIR=/dev/null composer install --no-dev --working-dir=/var/www/html \
 && rm -rf /var/www/html/vendor/*/*/.git
USER root

VOLUME ["/var/lib/snipeit"]

############ START #####################
COPY docker/startup.sh docker/supervisord.conf /
COPY docker/supervisor-exit-event-listener /usr/bin/supervisor-exit-event-listener
RUN chmod +x /startup.sh /usr/bin/supervisor-exit-event-listener

# Official php:apache image uses SIGWINCH (meant for Apache as PID 1); supervisord wants SIGTERM
STOPSIGNAL SIGTERM

EXPOSE 80 443
CMD ["/startup.sh"]
