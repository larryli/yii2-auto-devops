FROM php:fpm-alpine AS builder

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk add -U --no-cache git \
        freetype-dev \
        icu-dev \
        libjpeg-turbo-dev \
        libzip-dev \
    && docker-php-ext-configure intl \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) intl \
        gd \
        pdo_mysql \
        zip

FROM composer AS composer

RUN composer config -g repo.packagist composer https://mirrors.aliyun.com/composer \
    && composer global require --optimize-autoloader --no-progress --prefer-dist hirak/prestissimo

COPY composer.* /app/

ARG BUILD_DEV=false

RUN if [ "$BUILD_DEV" = true ]; then \
    composer install --dev --no-progress --no-scripts --no-suggest --no-interaction --prefer-dist; \
  else \
    composer install --no-dev --no-progress --no-scripts --no-suggest --no-interaction --prefer-dist; \
  fi

ARG BUILD_ASSET=false

RUN if [ "$BUILD_ASSET" = true ]; then \
    composer global require --optimize-autoloader --no-progress --prefer-dist matthiasmullie/minify:1.3.59; \
  fi

COPY . /app

RUN if [ "$BUILD_DEV" = true ]; then \
    composer dump-autoload --optimize --classmap-authoritative; \
  else \
    composer dump-autoload --no-dev --optimize --classmap-authoritative; \
  fi

RUN if [ "$BUILD_ASSET" = true ]; then \
    cp -rf /app/vendor/bower-asset/bootstrap/dist/* /app/web/; \
    /app/yii asset/compress /app/config/assets.php /app/config/asset-bundles.php; \
    rm -rf /app/web/css /app/web/js /app/vendor/npm-asset; \
    if [ "$BUILD_DEV" != true ]; then \
      rm -rf /app/vendor/bower-asset; \
    fi \
  fi

FROM php:fpm-alpine

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk add -U --no-cache freetype icu-libs libjpeg-turbo libzip

COPY --from=builder /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d

COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/

COPY --from=composer --chown=www-data:www-data /app /app

USER www-data

WORKDIR /app