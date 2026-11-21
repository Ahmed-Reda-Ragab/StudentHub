# syntax=docker/dockerfile:1.7
#
# student-app production image (multi-stage)
#   1) vendor  : composer install --no-dev (same PHP image as runtime → same extensions)
#   2) assets  : npm ci + vite build (Tailwind scans app/Enums + pagination views)
#   3) runtime : serversideup/php fpm-nginx (non-root www-data, port 8080, S6 supervises nginx + php-fpm)
#
# Build:  docker build -f docker/Dockerfile --build-arg APP_VERSION=$(git rev-parse --short HEAD) -t student-app:local .
# Docs:   docs/devops/scenarios/10-containerize-app.md

ARG PHP_IMAGE=serversideup/php:8.3-fpm-nginx-alpine-v5.0.5
ARG NODE_IMAGE=node:22-alpine

############################
# 1) PHP dependencies
############################
FROM ${PHP_IMAGE} AS vendor
WORKDIR /var/www/html

COPY --chown=www-data:www-data composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction --no-progress

COPY --chown=www-data:www-data . .
# Runs post-autoload-dump → package:discover (no .env needed).
RUN composer dump-autoload --optimize --no-dev --no-interaction

############################
# 2) Front-end assets
############################
FROM ${NODE_IMAGE} AS assets
WORKDIR /app

COPY package.json package-lock.json .npmrc ./
RUN npm ci --no-audit --no-fund

COPY vite.config.js ./
COPY resources ./resources
COPY app/Enums ./app/Enums
COPY --from=vendor /var/www/html/vendor/laravel/framework/src/Illuminate/Pagination/resources/views \
     ./vendor/laravel/framework/src/Illuminate/Pagination/resources/views
RUN npm run build

############################
# 3) Runtime
############################
FROM ${PHP_IMAGE} AS runtime

ARG APP_VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

USER root
# APCu: shared memory for Prometheus counters across PHP-FPM workers.
RUN install-php-extensions apcu
COPY docker/php/zz-student-app.ini /usr/local/etc/php/conf.d/zz-student-app.ini
COPY docker/entrypoint.d/ /etc/entrypoint.d/
USER www-data

WORKDIR /var/www/html
COPY --chown=www-data:www-data --from=vendor /var/www/html /var/www/html
COPY --chown=www-data:www-data --from=assets /app/public/build /var/www/html/public/build

# Runtime defaults — everything can be overridden by env at deploy time (12-factor).
ENV APP_ENV=production \
    APP_DEBUG=false \
    APP_VERSION=${APP_VERSION} \
    LOG_CHANNEL=stderr \
    LOG_LEVEL=info \
    LOG_STDERR_FORMATTER="Monolog\\Formatter\\JsonFormatter" \
    METRICS_STORAGE=apcu \
    PHP_OPCACHE_ENABLE=1 \
    HEALTHCHECK_PATH=/up \
    TRUSTED_PROXY=local \
    AUTORUN_ENABLED=true \
    AUTORUN_LARAVEL_MIGRATION=false \
    AUTORUN_LARAVEL_STORAGE_LINK=false

LABEL org.opencontainers.image.title="student-app" \
      org.opencontainers.image.description="Students Subscriptions (Laravel) — DevOps/SRE lab image" \
      org.opencontainers.image.source="https://github.com/Ahmed-Reda-Ragab/StudentHub" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

EXPOSE 8080
STOPSIGNAL SIGQUIT
