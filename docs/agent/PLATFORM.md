# My Paw Trainer Platform Interface

This document defines the public application image interface. Host Compose,
Nginx, deployment, rollback, SSH, backup, restore, and systemd assets belong in
the private `mypawtrainer-operations` repository.

## Image

- Architecture: `linux/arm64`.
- Registry tag: `ghcr.io/alexeynesteruk/tymeslot:<40-character-git-sha>`.
- Public source: `https://github.com/alexeynesteruk/tymeslot` under
  `AGPL-3.0-only`.
- Internal HTTP port: `4000`.
- `GET /healthcheck` is the liveness and readiness probe.
- The process runs as the unprivileged `app` user.
- Persistent application state is mounted at `/app/data`. PostgreSQL has its
  own platform-managed persistent state and is not embedded in this image.

The one-shot migration command is:

```sh
bin/tymeslot eval 'Ecto.Migrator.with_repo(Tymeslot.Repo, &Ecto.Migrator.run(&1, :up, all: true))'
```

The image runs this migration-compatible release command before
`bin/tymeslot start`. A platform may run the same command as a separate
one-shot migration job before starting the application.

## Environment Names

The platform supplies values at runtime. Values, environment files, and
credentials are not part of the image or this repository.

Core runtime and database names:

- `PHX_HOST`
- `SECRET_KEY_BASE`
- `DATA_ENCRYPTION_KEY`
- `PORT`
- `DATABASE_URL`
- `DATABASE_HOST`
- `DATABASE_PORT`
- `DATABASE_POOL_SIZE`
- `DATABASE_SSL`
- `DATABASE_SSL_CACERT_FILE`
- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`

Google and Stripe names:

- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_CONNECT_WEBHOOK_SECRET`

My Paw Trainer feature and projection names:

- `REGISTRATION_ENABLED`
- `MEETING_PAYMENTS_ENABLED`
- `MEETING_PAYMENTS_DEFAULT_COUNTRY`
- `MEETING_PAYMENTS_APPLICATION_FEE_BP`
- `PRICE_PROJECTION_DELIVERY_ENABLED`
- `PRICE_PROJECTION_URL`
- `PRICE_PROJECTION_SECRET`
- `CRM_PROJECTION_DELIVERY_ENABLED`
- `CRM_PROJECTION_URL`
- `CRM_PROJECTION_SECRET`
- `CRM_PROJECTION_OPERATOR_BASE_URL`

Mail delivery names:

- `EMAIL_ADAPTER`
- `EMAIL_FROM_NAME`
- `EMAIL_FROM_ADDRESS`
- `EMAIL_SUPPORT_ADDRESS`
- `EMAIL_CONTACT_RECIPIENT`
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USERNAME`
- `SMTP_PASSWORD`

Production activation remains prohibited until the release gates are complete.
