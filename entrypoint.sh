#!/bin/sh
set -eu

# LanBase entrypoint — shared by every lan-software Laravel app image.
#
# FLAVOR selects the runtime stack:
#   octane  — Laravel Octane + FrankenPHP (LanCore, LanBrackets)
#   server  — plain FrankenPHP server mode (LanEntrance, LanShout, LanHelp)
#
# ROLE selects which processes run in the container:
#   all    — web + worker(s) + scheduler
#   web    — HTTP server only
#   worker — queue/horizon + scheduler only
#
# The selected supervisor config is:
#   /etc/supervisor/conf.d/supervisord-${FLAVOR}-${ROLE}.conf
#
# SKIP_MIGRATE=1 disables `migrate --force`. In multi-container deployments
# EXACTLY ONE container (the designated migrator) must set SKIP_MIGRATE=0;
# every other container must set SKIP_MIGRATE=1 to avoid racing on schema
# changes. Default is 1 (safe).
#
# SKIP_CACHE=1 disables config/route/view/event caching (handy for dev
# containers). Default is 0.
#
# OCTANE_WORKERS / OCTANE_MAX_REQUESTS tune the Octane worker pool without
# rebuilding the image — referenced from supervisord-octane-*.conf. They are
# ignored by the `server` flavor but exported unconditionally so supervisord
# variable expansion never fails.

FLAVOR="${FLAVOR:-octane}"
ROLE="${ROLE:-all}"
SKIP_MIGRATE="${SKIP_MIGRATE:-1}"
SKIP_CACHE="${SKIP_CACHE:-0}"
export OCTANE_WORKERS="${OCTANE_WORKERS:-auto}"
export OCTANE_MAX_REQUESTS="${OCTANE_MAX_REQUESTS:-500}"

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

log "Starting (flavor=${FLAVOR}, role=${ROLE}, skip_migrate=${SKIP_MIGRATE}, skip_cache=${SKIP_CACHE})"

# Runtime sanity checks — fail fast with a clear message rather than letting
# supervisord loop on a broken process.
[ -n "${APP_KEY:-}" ] || die "APP_KEY must be set at runtime (never baked into the image)"

case "${FLAVOR}" in
    octane|server) ;;
    *) die "Unknown FLAVOR: ${FLAVOR} (expected: octane | server)" ;;
esac

case "${ROLE}" in
    all|web|worker) ;;
    *) die "Unknown ROLE: ${ROLE} (expected: all | web | worker)" ;;
esac

CONF="/etc/supervisor/conf.d/supervisord-${FLAVOR}-${ROLE}.conf"
[ -f "${CONF}" ] || die "Supervisor config not found: ${CONF}"

# Ensure writable runtime dirs exist with correct ownership. The app code
# was copied into the child image as root; fix perms at boot so www-data
# can write to storage/, bootstrap/cache/, and the supervisor runtime dirs.
mkdir -p /var/run/supervisor /var/log/supervisor \
         storage/framework/sessions storage/framework/views \
         storage/framework/cache storage/logs bootstrap/cache
chown -R www-data:www-data \
    /var/run/supervisor /var/log/supervisor \
    storage bootstrap/cache

if [ "${SKIP_CACHE}" != "1" ]; then
    su-exec www-data php artisan config:cache || die "config:cache failed"
    su-exec www-data php artisan route:cache  || die "route:cache failed"
    su-exec www-data php artisan view:cache   || die "view:cache failed"
    su-exec www-data php artisan event:cache  || die "event:cache failed"
else
    log "Skipping artisan *:cache (SKIP_CACHE=1)"
fi

if [ "${SKIP_MIGRATE}" != "1" ]; then
    log "Running database migrations (designated migrator)"
    su-exec www-data php artisan migrate --force || die "migrate --force failed"
else
    log "Skipping migrations (SKIP_MIGRATE=1)"
fi

log "Exec supervisord with ${CONF}"
# supervisord itself must run as root so it can open /dev/stdout and
# /dev/stderr (owned by the root-started container's PID 1). All supervised
# programs are configured with `user=www-data` and therefore run as the
# unprivileged user.
exec /usr/bin/supervisord -c "${CONF}"
