# My Paw Trainer Scheduler Status

Updated: 2026-08-17

## Checkout

- Local checkout: `/Users/anesteruk/Documents/tymeslot`
- Fork remote: `git@github.com:alexeynesteruk/tymeslot.git`
- Upstream remote: `git@github.com:Tymeslot/tymeslot.git`
- Branch: `feat/mpt-task7`
- `origin/main`: `eab8ea89` (Tasks 1-5 merged)
- Git SSH identity: `/Users/anesteruk/.ssh/mypawtrainer.com`

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
- Deployment assets: not started.
- Production booking activation: prohibited at this stage.

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

The VM was updated and rebooted. On 2026-08-17 a production-disabled host
install started Tymeslot `d85a30f3` on loopback only. `rpcbind` is masked,
UFW/fail2ban/Docker/Nginx are active, and `GET /healthcheck` on
`127.0.0.1:4000` returns HTTP 200. Host Nginx now publishes
`book.mypawtrainer.com` over HTTPS. Event types stay inactive. No ZIPs are
seeded. Public booking and EspoCRM remain off. A scheduler NSG, reserved
public IP, and independent console fingerprint confirmation are still
outstanding.

## Toolchain checkpoint

Local focused verification uses Elixir 1.20.3, OTP 28.5.0.5, and PostgreSQL
17.11 with explicit Homebrew paths. Task 5 focused suites plus bookings,
meetings, and calendar regression passed 2436 tests. The two-connection
same-slot race passed separately (2 tests) so committed rows do not leak
into the sandbox suite. Formatting and `git diff --check` pass. The
complete gate has not been re-run in this change.

## Next safe action

Task 10 is complete locally on `feat/mpt-task7` and is not deployed. The Task 6
SHA remains loopback-only on VM 2. `book.mypawtrainer.com` has DNS and TLS. A
local encrypted PostgreSQL backup and a disposable restore rehearsal both
exist. Do not activate production booking or seed ZIPs. Next product work is
Task 11 signed VM 1 price-projection delivery. Website booking URLs stay off.

## Production blockers

- Price events have a transactional outbox, but signed VM 1 delivery and CRM
  projection producers and delivery are not implemented.
- Concurrency, webhook, security, and browser gates have not run.
- ARM64 deployment, backups, restore, monitoring, and rollback are not verified.
- Anna has not supplied all production booking and authorization values.
- Anna's scheduler user ID is not approved, so production provisioning remains
  blocked. The local operation accepts an explicit owner ID only, provisions
  exactly the three direct event types at catalog initial price/version 1, and
  is idempotent and owner-scoped after the account exists.
- Live Google, Stripe, SMTP, and webhook configuration is not complete.
- Test-mode and manual acceptance have not passed.
