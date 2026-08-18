# My Paw Trainer Scheduler Status

Updated: 2026-08-18

## Checkout

- Local checkout: `/Users/anesteruk/Documents/tymeslot`
- Fork remote: `git@github.com:alexeynesteruk/tymeslot.git`
- Upstream remote: `git@github.com:Tymeslot/tymeslot.git`
- Branch: `feat/mpt-task7` @ `1aaed043` (pushed)
- `origin/main`: `eab8ea89` (Tasks 1-5 merged)
- Git SSH identity: `/Users/anesteruk/.ssh/mypawtrainer.com` for fetch;
  push to `alexeynesteruk/tymeslot` uses `/Users/anesteruk/.ssh/id_rsa`

The checkout already existed from the previous session. It was verified and
both remotes were fetched instead of creating a duplicate clone.

## Implementation state

- Approved design: complete in the website repository.
- Approved implementation plan: complete in the website repository.
- Public fork: created and verified.
- Agent documents in this checkout: reconciled to the current six-service contract.
- Stable service identity, versioned booking snapshots, and owner-scoped direct
  service provisioning: implemented locally and verified with focused suites.
- Service-configuration review: closed on 2026-08-17. The six-service catalog,
  immutable snapshots, owner-scoped lock, and idempotent direct-service
  provisioning match the Task 2 contract. No production event types are active.
- Service-specific intake: implemented locally on 2026-08-17. Discovery and
  full consultation definitions reuse existing custom-field types. Extra keys
  are rejected, valid values survive recoverable errors, and generic meeting
  types keep host-authored custom fields. No phone or meeting-mode fields were
  added. Approval-first IDs have no Tymeslot intake route.
- Task 3 spec gap closed on 2026-08-17: the booking wizard now loads MPT
  intake questions through `Intake.definitions_for_meeting_type/1`. Direct
  services get the questions step even when host `custom_fields` are empty.
  Name and email stay on the existing booking form. Generic types with empty
  custom fields still skip questions. Production booking stays off.
- Unknown age is now accepted in the booking wizard. `dog_age` and
  `acquisition_age` are short_text. Wizard completion uses
  `Intake.validate_wizard_answers/2`, so a numeric age without a unit cannot
  advance. Failed completion stores field errors and jumps to the first
  invalid question. Padded numeric ages are trimmed. LiveView coverage
  walks discovery questions and proves a missing age unit stays on the
  questions step. Production booking stays off.
- ZIP eligibility: implemented locally on 2026-08-17. Owner-scoped allowlist
  and audit tables exist. `eligible?` accepts only active five-digit ZIPs.
  Dashboard `/dashboard/service-area` is authenticated and never lists another
  owner's ZIPs. In-home schedule requires a ZIP before times are fetched or
  shown. Ineligible ZIP returns `service_area_unavailable`. Discovery and
  online never consult the allowlist. No ZIPs are seeded. Production booking
  stays off.
- Task 5 fail-closed booking guards: implemented locally on 2026-08-17.
  `BookingGuard` authorizes only the three direct IDs, enforces catalog
  duration, and requires an active owner ZIP for in-home. Generic Tymeslot
  bookings still proceed on calendar timeout. Direct services refuse timeout,
  transport failure, malformed payloads, and incomplete busy sets.
  `acquire_trainer_booking_lock/1` serializes create and reschedule writes
  inside the booking transaction. Real two-connection overlapping-slot races
  yield one `:ok` and one `:time_conflict`. Event types stay inactive. No
  ZIPs are seeded. Production booking stays off.
- Task 6 deferred setup and durable Stripe webhooks: implemented locally
  on 2026-08-17. Direct services use setup-mode Checkout, persist
  `setup_pending` before the Stripe call, and confirm to `card_saved`
  without creating a charge. SetupIntent and checkout events converge in
  either order. Failed or expired setup releases the slot. Replay uses a
  processed-event ledger. Calendar and email enqueue independently after
  confirmation. Event types stay inactive. No ZIPs are seeded. Production
  booking stays off.
- Task 7 completion, deferred charges, and recovery: implemented locally on
  2026-08-17. Only the owning host can complete a confirmed direct-service
  meeting or reserve its immutable snapshot charge. Stripe execution occurs
  outside the reservation transaction with one attempt-specific idempotency
  key and no automatic decline retry. PaymentIntent and recovery webhooks are
  monotonic, recovery uses Stripe-hosted Checkout, refunds require domain-layer
  ownership, and dashboard controls never accept an editable charge amount.
  Event types remain inactive. No ZIPs are seeded. Production booking stays off.
- Task 7 spec review fixes completed locally on 2026-08-17. The charge modal
  includes appointment time, deferred PaymentIntent and recovery identities
  fail closed, recovery completion verifies immutable amount and currency,
  recovery expiry and disputes lock and deduplicate audit writes, and actorless
  refunds reject deferred payments without changing generic upfront refunds.
- Task 8 private management links: implemented locally on 2026-08-17. My Paw
  Trainer direct-service attendee links are hashed, meeting- and
  attendee-bound, owner-deadline controlled, rescheduling-only, and rotated
  after use or newer email delivery. Legacy public cancellation is an email
  request to `mypawtrainer@gmail.com`; dashboard cancellation remains
  available. Production booking stays off. Event types stay inactive. No ZIPs
  are seeded. Next implementation task is Task 9 included follow-ups.
- Task 9 included follow-ups: implemented locally on 2026-08-17. Completed
  online and in-home consultations earn one owner-issued, client-bound link for
  a zero-dollar 30-minute virtual child booking from day 5 through the end of
  day 10 in the meeting timezone. Redemption is single-use, uses a fresh
  fail-closed calendar check and the trainer booking lock, and creates no card
  setup or payment row. `follow-up` remains outside the public six-service
  catalog and normal booking routes. Production booking stays off. Event types
  remain inactive. No ZIPs are seeded. Next implementation task is Task 10.
- Task 10 transactional price projections and stable event routes: implemented
  locally on 2026-08-17. Direct-price edits lock and version the future event
  type and append one allowlisted `service.price_published.v1` row in the same
  PostgreSQL transaction. Reviewed outbox queries claim with `SKIP LOCKED`,
  deliver, retry with sanitized codes, and dead-letter. Stable `/anna/...`
  routes exist only for the three direct services and resolve unavailable while
  their event types are inactive. No HTTP delivery worker was added. Production
  booking stays off, event types remain inactive, and no ZIPs are seeded. Next
  implementation task is Task 11 signed VM 1 price-projection delivery.
- Task 11 signed VM 1 price-projection delivery: implemented locally on
  2026-08-17. The dedicated worker delivers only
  `service.price_published.v1` with the exact bounded JSON contract, TLS,
  timestamp, nonce, event ID, idempotency key, and HMAC-SHA256 body signature.
  It acknowledges applied, duplicate, and older-version responses; retries
  transient and malformed outcomes with bounded exponential backoff and
  jitter; dead-letters authentication and exhausted retries; and reclaims
  interrupted deliveries for idempotent reconciliation. Delivery defaults off,
  no production secret is present, and price changes remain committed through
  every delivery outcome. Production booking stays off, event types remain
   inactive, and no ZIPs are seeded. Next implementation task is Task 12 minimum
   EspoCRM projection and delivery.
- Task 12 minimum EspoCRM projection and idempotent delivery: implemented
  locally on 2026-08-17. Only booking lifecycle projections use the shared
  transactional outbox. The payload is restricted to the approved booking
  allowlist, signed with a separate CRM credential, retried asynchronously,
  reconciled by immutable booking ID and aggregate version, and ignored by the
  VM 1 price worker. Client, dog, payment, and follow-up producers remain
  disabled. CRM delivery defaults off. Production booking stays off, event
  types remain inactive, and no ZIPs are seeded. Next implementation task is
  Task 13 privacy, retention, authorization, and observability enforcement.
- Task 13 privacy, retention, authorization, and observability enforcement:
  implemented locally on 2026-08-17. Logger metadata, message redaction, admin
  alerts, and analytics reject the named attendee, dog, ZIP, intake, setup,
  payment-method, and card fields, including nested contexts. Scheduler
  retention scrubs attendee identity and intake while preserving immutable
  service and financial facts, retains audit outcomes, and deletes expired
  management and follow-up token hashes. Contract tests prove completion,
  charge, recovery, refund, ZIP, price, and follow-up owner isolation. Focused
  verification passed 14 tests and the broader affected regression suite
  passed 89 tests. `mix deps.audit`, formatting, compile with warnings as
  errors, and `git diff --check` passed. `mix sobelow` exited successfully with
  one pre-existing medium-confidence `XSS.HTML` finding in the development-only
  `lib/tymeslot_web/controllers/dev/embed_test_controller.ex:45`; no Task 13
  file is involved. Production booking stays off, event types remain inactive,
  and no ZIPs are seeded. Next implementation task is Task 14 browser and
  website interface contracts.
- Task 14 browser and website interface contracts: implemented locally on
  2026-08-17. Contract and acceptance suites cover the three stable direct
  routes, exact $49/$140/$190 prices and 30/90/90 durations, service-specific
  intake without phone or meeting-mode, in-home-only ZIP handling, fresh Google
  busy rejection, immutable booking snapshots, Stripe setup-mode Checkout,
  immediate SetupIntent confirmation, and zero immediate charge. Approval-first
  services cannot create meetings or payments, direct route availability is
  independent, and included follow-up remains private, single-use, 30 minutes,
  and payment-free. The focused scheduler suites passed 9 tests. The unchanged
  website suites `tests/unit/booking.test.ts` and
  `tests/components/booking-link.test.tsx` passed 13 tests with Vitest. Production
  booking stays off, event types remain inactive, and no ZIPs are seeded. Next
  implementation task is Task 15 image and platform interface contracts.
- Task 15 image and platform interface contracts: implemented locally on
  2026-08-17. The public application repository now defines a non-root
  `linux/arm64` release image, internal port 4000, `GET /healthcheck` liveness
  and readiness behavior, release migrations, an immutable commit-SHA GHCR
  workflow, AGPL source labels, and a documented runtime environment and
  persistent-state interface. Host Compose, Nginx, deployment, rollback, SSH,
  backup, restore, and systemd assets remain outside this repository. The four
  focused deployment contract tests pass. The requested image command
  `docker buildx build --platform linux/arm64 --load -f Dockerfile.mypawtrainer -t tymeslot:mypawtrainer-plan-check .`
  could not start locally because the `docker` executable is unavailable
  (`command not found`, exit 127). The same Dockerfile later built on VM 2 as
  `tymeslot:702c589f` (`linux/arm64`, digest
  `sha256:c91381943134ce865c2396d0f992c287936b9eca95ef35d9b93330fd7c1b5657`).
  Production booking stays off, event types remain inactive, and no ZIPs are
  seeded.
- Task 16 full gate and test-mode acceptance: started on 2026-08-18 and is
  **not accepted**. Evidence is in the Task 16 gate section below. Next
  implementation work is to close the remaining Task 16 gaps or wait for
  Anna's Task 17 inputs. Production booking activation remains prohibited.

An older implementation worktree also exists at:

`/Users/anesteruk/Documents/mypawtrainer.com/.worktrees/tymeslot-deferred-payments`

It begins at the same baseline. Use one implementation checkout deliberately.
Do not edit the same task in both locations.

## Scheduler VM

- Name: `mypawtrainer-scheduler`
- Public IP observed: `132.145.128.3`
- OS: Ubuntu 24.04 Minimal ARM64
- Shape: `VM.Standard.A1.Flex`
- Capacity: `1 OCPU / 6 GB`
- Updated kernel: `6.17.0-1019-oracle`
- Observed host fingerprint:
  `SHA256:qxxvyJYrAJvDHh3nh3VBTkwgINPC+k+A85bVL8ILDoc`

The VM was updated and rebooted. On 2026-08-18 17:49 UTC host image
`tymeslot:1aaed043` replaced `tymeslot:e3922a06` with four-screen
consultation intake. Previous images `e3922a06`, `1eb79b11`, `702c589f`,
and `d85a30f3` remain on the host for application rollback. `rpcbind` is masked,
UFW/fail2ban/Docker/Nginx are active, and `GET /healthcheck` on
`127.0.0.1:4000` returns HTTP 200 with database and Oban ok. Host Nginx
publishes `book.mypawtrainer.com` over HTTPS. The process runs as `app`.
`REGISTRATION_ENABLED`, `ENABLE_GOOGLE_AUTH`,
`PRICE_PROJECTION_DELIVERY_ENABLED`, and `CRM_PROJECTION_DELIVERY_ENABLED`
are `false`. `MEETING_PAYMENTS_ENABLED` is `true` for Stripe test-mode
only. Event types stay inactive. Approved ZIPs `32095`, `32259`, and
`32258` are seeded. Google Calendar is connected for owner 1. Public
booking and EspoCRM remain off. A scheduler NSG, reserved public IP, and
independent console fingerprint confirmation are still outstanding.

## Toolchain checkpoint

Local verification uses Elixir 1.20.3, OTP 28.5.0.5, and PostgreSQL 17.11
with explicit Homebrew paths. Formatting and `git diff --check` pass.

## Task 16 gate

Code-quality gate was run on 2026-08-18 from
`/Users/anesteruk/Documents/tymeslot/.worktrees/mpt-task7` at `5348c106`.
Later commits `1eb79b11` and `6259eba6` added the customer-heal fix and
deploy evidence. Host image is `tymeslot:1eb79b11`.

| Command | Result |
| --- | --- |
| `mix format --check-formatted` | pass |
| `mix compile --warnings-as-errors` | pass |
| `mix credo --strict` | fail, exit 31. Project `.credo.exs` has `strict: false`. Upstream design/consistency debt. Not cleaned in this task. |
| `mix sobelow` | exit 0. Pre-existing medium-confidence `XSS.HTML` in `lib/tymeslot_web/controllers/dev/embed_test_controller.ex:45`. No MPT file involved. |
| `mix deps.audit` | pass, no vulnerabilities found |
| `mix excellent_migrations.check_safety` | pass after MPT safety-assured comments. SQL unchanged. |
| `mix test --exclude mpt_concurrency` | 12490 passed, 115 excluded |
| same-slot + webhooks + refunds + retention + security + payments rate-limit | 126 passed, including the two-connection same-slot race |
| `MIX_ENV=dev mix gettext.extract --check-up-to-date` | pass |
| `MIX_ENV=dev mix dialyzer` | pass. 81 ignored, 0 remaining |
| `git diff --check` | pass |

### Test-mode acceptance

Automated ExUnit acceptance in `test/e2e/mypawtrainer_booking_acceptance_test.exs`
and `test/e2e/mypawtrainer_follow_up_acceptance_test.exs` covers the three
direct services with fake Stripe and a fake Google provider: setup-mode
Checkout, zero immediate charge, immutable $49/$140/$190 snapshots, ZIP only
for in-home, Google busy rejection, and payment-free follow-up.

A second private `$140` online-consultation probe completed live Stripe
test Checkout with card `4242`. Checkout mode was `setup`,
`payment_status=no_payment_required`, livemode false, amount total null.
The existing platform webhooks did not receive connected-account events.
A test-mode Connect endpoint `we_1U5n8eI86BemGfry3MOtOqSl` was created
for `/webhooks/stripe/connect` and `STRIPE_CONNECT_WEBHOOK_SECRET` was
rotated. After `docker compose up -d` (restart does not reload env),
Stripe replay of `setup_intent.succeeded` returned HTTP 200.

Resulting booking `c1e98935-42a5-4d5a-a9d6-157d8fc2b9e1`: meeting
`confirmed` then owner-completed, payment `card_saved` at `$140`, no
PaymentIntent or charge, Google Calendar event
`c9175467bd2a4e48b8ef971d0b9ec5c3` written, follow-up entitlement
created for 2026-08-26 through 2026-09-01. Owner refund
`Refunds.issue_refund/3` later set payment
`0d85db80-9625-4008-a129-f84043c0aa48` to `refunded` with
`refunded_amount_cents=14000`. Event type deactivated;
`EventRoutes.resolve/2` is `:unavailable`. Website booking URLs stayed
unset.

Gaps found on the live path, now deployed on `tymeslot:1eb79b11`:

- Checkout setup now creates a Connect Customer and binds `customer`
  on the session so the saved card can be charged later.
- Webhook confirmation heals a missing customer, broadcasts
  `:card_saved`, and both theme return pages plus the embed iframe
  treat `card_saved` as confirmed.
- `ManualCharges.reserve/2` healed the existing live probe, created
  Connect customer `cus_V5zgyinNZ0TZF7`, and charged `$140` in Stripe
  test mode. Payment `0d85db80-9625-4008-a129-f84043c0aa48` is `paid`
  with PaymentIntent `pi_3U5nhEI86BQ5JZdC1wYQtcoc` and charge
  `ch_3U5nhEI86BQ5JZdC1Qog49UQ` (`livemode=false`, captured).

A second private `$140` recovery probe on 2026-08-18 used test card
`4000000000000341` (attach succeeds, later charge fails). Type 4 was
activated only for `Orchestrator.submit_booking/1`, then set
`is_active=false` and `is_private=true` in the same `rpc`. Booking
`2190740d-99e3-4a26-9b2a-899590702534` confirmed after setup Checkout.
Owner completion plus `ManualCharges.reserve/2` produced PaymentIntent
`pi_3U5oTYI86BQ5JZdC11sHbvQ2` and payment
`8f473879-5bcf-4053-8944-016f1a7d7dda` `charge_failed` /
`card_declined`. `RecoverySessions.create/2` as owner 1 created hosted
Checkout `cs_test_a1tq4X6GH3D5dufP3IhBwQCFUeyhx6cP7o378fZmLDKwJlkFnJTXhBiYz7`.
Final payment status after session create remains `charge_failed`.
Recovery Checkout was not completed. All three
`EventRoutes.resolve/2` results are `:unavailable`. Website booking
URLs stayed unset.

| Service | Setup charge | Confirmation | Calendar | Manual charge | Recovery | Refund |
| --- | --- | --- | --- | --- | --- | --- |
| discovery-call $49 | ExUnit only | ExUnit only | fake provider | not on host | not on host | not on host |
| online-consultation $140 | live Stripe test Checkout, $0 | card_saved then owner-completed | Google event written | live Stripe test charge `$140`, plus later `card_declined` | live `RecoverySessions.create/2`; session created; payment left `charge_failed` | live full `$140` refund on payment `0d85db80-9625-4008-a129-f84043c0aa48` |
| in-home-consultation $190 | ExUnit only | ExUnit only | fake provider | not on host | not on host | not on host |

### Backup, restore, rollback

- Pre-image backup: `/var/backups/tymeslot/tymeslot.20260818T120120Z.dump.age`
- Post-image backup: `/var/backups/tymeslot/tymeslot.20260818T122656Z.dump.age`
- Pre-`1eb79b11` backup: `/var/backups/tymeslot/tymeslot.20260818T135858Z.dump.age`
- Disposable restore rehearsal of the pre-image backup: `tables=39 users=1`
  while live Tymeslot stayed healthy
- Application rollback to `tymeslot:d85a30f3` was **not** executed. Newer
  migrations have already run. Automatic down-migrations are prohibited.
- EspoCRM is not running. Tymeslot stays healthy with CRM delivery disabled.
  That is the current fail-closed interface-failure proof.

### Image

- Tag: `tymeslot:1eb79b11`
- Digest: `sha256:c408826b6064f52a1a5b25218717a64af611d3c465aa5ce3df679492e20c5a5e`
- Previous rollback images still on host: `tymeslot:702c589f`, `tymeslot:d85a30f3`
- Arch: `linux/arm64`, runs as `app`
- Health: HTTP 200, `oban=ok`, `database=ok`

## Next safe action

Direct event types are active on the host in Stripe test mode:
`/annak/discovery-call`, `/annak/online-consultation`, and
`/annak/in-home-consultation` return HTTP 200. Website booking URLs and
`resolveBookingTarget` stay inquiry-only. Do not treat this as a
customer launch or live-Stripe activation. Remaining Task 16 gaps are
credo --strict (upstream), optional image rollback, and live `$49` /
`$190` payment probes. Do not start Task 17.

## Production blockers

- Task 16 is not accepted. Credo `--strict` remains red. Live `$140`
  card-save, Google Calendar write, Stripe test-mode manual charge,
  full refund, and owner recovery-session create succeeded on image
  `1eb79b11`. Recovery Checkout was not completed to `paid`.
- Price and minimum booking projection events have transactional outbox and
  signed delivery locally. CRM delivery remains disabled.
- Anna supplied bookable hours 09:00-20:00 America/New_York, applied to all
  seven days on owner `mypawtrainer@gmail.com`, and approved ZIPs `32095`,
  `32259`, and `32258`. Forty-five previously active ZIPs were deactivated so
  only those three remain. Days off, notice, window, buffer, and rescheduling
  deadline are still unset.
- Stripe sandbox test keys, test webhooks, and a charges-enabled Connect
  test account are on VM 2. `MEETING_PAYMENTS_ENABLED` is `true` for
  test-mode only. Live charges stay off. Event types stay inactive.
- Operator-chosen test policy on owner 1: 24-hour notice, 30-day window,
  30-minute buffer, 24-hour reschedule cutoff. All seven days remain
  09:00-20:00 America/New_York. The reschedule cutoff is in the running
  node via `Application.put_env/3` and in host env as
  `MPT_RESCHEDULE_DEADLINE_HOURS=24`. Image `1eb79b11` includes the
  runtime reader.
- Anna has not supplied notice, window, buffer, rescheduling deadline,
  saved-card authorization, cancellation/refund policy, safety wording,
  monthly/assistant-dog operating details, replacement FAQ, photography,
  Instagram decision, or admin recovery procedure.
- Anna's scheduler user ID is not approved, so production provisioning
  remains blocked.
- Google Calendar is connected for owner 1 with encrypted tokens. Google
  login stays off. Live Stripe Connect onboarding and SMTP/Resend are not
  complete.
- Measured host thresholds and a live `--apply` restore remain outstanding.
