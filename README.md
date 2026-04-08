LanBase
=======

Shared runtime Docker base image for every [lan-software](https://lan-software.de)
Laravel application (LanCore, LanBrackets, LanEntrance, LanShout, LanHelp, …).

One image, patched in one place — apps inherit PHP extensions, production
php/opcache tuning, the FrankenPHP Caddyfile, all supervisor role configs,
and a generalised entrypoint. Apps only layer in their own code, build
artifacts, and labels.

Published as: `ghcr.io/lan-software/lanbase`

## Tags

| Tag                      | Meaning                                       | Use for          |
| ------------------------ | --------------------------------------------- | ---------------- |
| `php8.5-sha-<shortsha>`  | Immutable build on PHP 8.5                    | **Production**   |
| `php8.5`                 | Rolling — latest default-branch build on 8.5  | Dev convenience  |
| `sha-<shortsha>`         | Immutable, flavor-agnostic                    | Pinning          |
| `vX.Y.Z`                 | Semver release                                | Release pinning  |
| `latest`                 | Rolling default branch                        | Local dev only   |

App Dockerfiles must pin an **immutable** tag (`php8.5-sha-<shortsha>` or a
digest). Bumping LanBase in an app = bumping that `FROM` line in a PR.

## Runtime contract

The baked entrypoint is driven by environment variables. Child images do
not need their own entrypoint.

| Env                   | Values                   | Default  | Purpose                                                                 |
| --------------------- | ------------------------ | -------- | ----------------------------------------------------------------------- |
| `APP_KEY`             | `base64:…`               | *(required)* | Fails fast if unset. Never bake into an image layer.              |
| `FLAVOR`              | `octane` \| `server`     | `octane` | `octane` = Laravel Octane + FrankenPHP. `server` = plain FrankenPHP.    |
| `ROLE`                | `all` \| `web` \| `worker` | `all`  | Process set: web, worker(s)+scheduler, or both combined.                |
| `SKIP_MIGRATE`        | `0` \| `1`               | `1`      | `0` on **exactly one** container per deploy (the designated migrator).  |
| `SKIP_CACHE`          | `0` \| `1`               | `0`      | `1` skips `artisan config:cache route:cache view:cache event:cache`.    |
| `OCTANE_WORKERS`      | int \| `auto`            | `auto`   | Octane worker pool size. Ignored by `server` flavor.                    |
| `OCTANE_MAX_REQUESTS` | int                      | `500`    | Recycle an Octane worker after N requests. Ignored by `server` flavor.  |

The supervisor config selected at boot is
`/etc/supervisor/conf.d/supervisord-${FLAVOR}-${ROLE}.conf` — six variants
ship in LanBase.

### Flavor matrix

| App          | `FLAVOR` |
| ------------ | -------- |
| LanCore      | `octane` |
| LanBrackets  | `octane` |
| LanEntrance  | `server` |
| LanShout     | `server` |
| LanHelp      | `server` |

## Consuming LanBase from an app

```dockerfile
#syntax=docker/dockerfile:1.7

FROM composer:2 AS deps
# … composer install + wayfinder:generate …

FROM node:22-alpine AS frontend
# … npm ci && npm run build …

FROM ghcr.io/lan-software/lanbase:php8.5-sha-<shortsha> AS production

LABEL org.opencontainers.image.title="LanCore" \
      org.opencontainers.image.description="…"

COPY --from=deps     /app              /var/www/html
COPY --from=frontend /app/public/build /var/www/html/public/build

# Non-Octane apps override the default flavor:
# ENV FLAVOR=server
```

Nothing else. No `apk add`, no `install-php-extensions`, no `COPY docker/`
— all of that lives in LanBase.

## Baked contents

* Base: `dunglas/frankenphp:php8.5-alpine` (pin to digest before release)
* Alpine packages: `supervisor curl su-exec`
* PHP extensions: `pdo_pgsql pgsql bcmath mbstring exif pcntl zip gd opcache intl redis`
* `/usr/local/etc/php/conf.d/app.ini` — production PHP tuning (`memory_limit=512M`, no display errors, UTC)
* `/usr/local/etc/php/conf.d/opcache.ini` — production opcache tuning
* `/etc/caddy/Caddyfile` — FrankenPHP server-mode config (for `FLAVOR=server`)
* `/etc/supervisor/conf.d/supervisord-{octane,server}-{all,web,worker}.conf`
* `/entrypoint.sh`

## Local build

```sh
docker build -t lanbase:dev .
docker run --rm lanbase:dev php -m | grep -E 'pdo_pgsql|redis|opcache|intl'
```

## Updating LanBase

1. Edit files here, open a PR.
2. On merge to `main`, CI publishes `ghcr.io/lan-software/lanbase:php8.5-sha-<shortsha>`.
3. Open PRs in each consuming app bumping the `FROM` line to the new sha tag.
4. App CI rebuilds app images on top of the new base.
