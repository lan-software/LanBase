#syntax=docker/dockerfile:1.7

# =============================================================================
# LanBase — shared runtime base image for all lan-software Laravel apps
# =============================================================================
#
# This image is consumed as the final stage of every Lan* app Dockerfile:
#
#     FROM ghcr.io/lan-software/lanbase:php8.5-<sha> AS production
#     COPY --from=deps     /app              /var/www/html
#     COPY --from=frontend /app/public/build /var/www/html/public/build
#
# It bakes FrankenPHP, PHP extensions, production php/opcache tuning, the
# Caddyfile, all supervisor role configs, and a generalised entrypoint. App
# code and per-release env vars are layered on top by the downstream image.
#
# Runtime is controlled entirely by environment variables — see entrypoint.sh
# for the FLAVOR / ROLE / SKIP_MIGRATE / SKIP_CACHE / OCTANE_* contract.
#
# Base pinning: the `dunglas/frankenphp` tag below should be replaced by an
# immutable @sha256:... digest before tagging a production release of
# LanBase itself. Digest pinning is required by SSS ENV-DEP-010.

FROM dunglas/frankenphp:php8.5-alpine

LABEL org.opencontainers.image.title="LanBase" \
      org.opencontainers.image.description="Shared runtime base image for lan-software Laravel applications" \
      org.opencontainers.image.url="https://lan-software.de" \
      org.opencontainers.image.source="https://github.com/lan-software/lanbase" \
      org.opencontainers.image.vendor="Lan-Software.de" \
      org.opencontainers.image.authors="Markus Kohn <post@markus-kohn.de>" \
      org.opencontainers.image.licenses="AGPL-3.0" \
      org.opencontainers.image.base.name="dunglas/frankenphp:php8.5-alpine"

# System dependencies. su-exec lets entrypoint.sh drop from root to www-data
# before exec'ing supervisord; curl is retained for the HEALTHCHECK probe.
RUN apk add --no-cache supervisor curl su-exec

# PHP extensions — install-php-extensions resolves all transitive deps.
RUN install-php-extensions \
    pdo_pgsql \
    pgsql \
    bcmath \
    mbstring \
    exif \
    pcntl \
    zip \
    gd \
    opcache \
    intl \
    redis

# PHP production configuration
COPY docker/php/php.ini     /usr/local/etc/php/conf.d/app.ini
COPY docker/php/opcache.ini /usr/local/etc/php/conf.d/opcache.ini

# FrankenPHP Caddyfile (used by the `server` flavor; ignored by octane)
COPY docker/frankenphp/Caddyfile /etc/caddy/Caddyfile

# All supervisor role/flavor combos. entrypoint.sh selects one via
# /etc/supervisor/conf.d/supervisord-${FLAVOR}-${ROLE}.conf
COPY docker/supervisor/ /etc/supervisor/conf.d/

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Pre-create supervisor runtime dirs. Per-app storage/bootstrap/cache dirs
# are owned at boot by entrypoint.sh (they arrive in the downstream image).
RUN mkdir -p /var/log/supervisor /var/run/supervisor \
 && chown -R www-data:www-data /var/log/supervisor /var/run/supervisor

WORKDIR /var/www/html

EXPOSE 80 443

# Healthcheck hits Laravel's built-in /up endpoint. Start period covers
# Octane cold boot plus an optional one-shot migration on the migrator
# container.
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost/up || exit 1

# Default tunables — overridable at runtime via `docker run -e`.
ENV FLAVOR=octane \
    ROLE=all \
    SKIP_MIGRATE=1 \
    SKIP_CACHE=0 \
    OCTANE_WORKERS=auto \
    OCTANE_MAX_REQUESTS=500

# The entrypoint itself needs root briefly (chown of runtime dirs) then
# drops privileges to www-data via su-exec before supervisord starts.
ENTRYPOINT ["/entrypoint.sh"]
