# My Paw Trainer Scheduler Status

Updated: 2026-08-17

## Checkout

- Local worktree: `/Users/anesteruk/Documents/tymeslot/.worktrees/mpt-booking`
- Fork remote: `git@github.com:alexeynesteruk/tymeslot.git`
- Upstream remote: `git@github.com:Tymeslot/tymeslot.git`
- Branch: `feat/mpt-booking`
- Baseline repair started from: `414b19762b360b9ab4bc4bf660fccc7730ad1c04`
- `origin/main`: `5c19a7510eaae9df8a7a6737133d9242e7a29b59`
- `upstream/main`: `5c19a7510eaae9df8a7a6737133d9242e7a29b59`
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
- Service-specific intake: next implementation task. Not started.
- Deferred payment workflow: not started.
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

The VM was updated and rebooted. Before deployment it still needs a scheduler
NSG, stable public IP, independent fingerprint confirmation, `rpcbind`
disablement, and remaining host hardening. No scheduler is deployed.

## Toolchain checkpoint

Local focused verification uses Elixir 1.20.3, OTP 28.5.0.5, and PostgreSQL
17.11 with explicit Homebrew paths. Date-boundary failures in the upstream
calendar and scheduling tests are repaired: initial calendar dates now use the
profile timezone, quick-add ranges advance dates across midnight, and the
shared booking helper advances weekly calendars. The exact three formerly
failing files pass 42 tests, the nearby regression set passes 41 tests,
compilation with warnings as errors and formatting pass, and the complete gate
passes 12,192 tests with 104 excluded.

## Next safe action

Implement Task 3 service-specific intake in this worktree. Do not activate
production booking, seed ZIPs, or deploy the scheduler.

## Production blockers

- Deferred domain and operator workflows are not implemented.
- Concurrency, webhook, security, and browser gates have not run.
- ARM64 deployment, backups, restore, monitoring, and rollback are not verified.
- Anna has not supplied all production booking and authorization values.
- Anna's scheduler user ID is not approved, so production provisioning remains
  blocked. The local operation accepts an explicit owner ID only, provisions
  exactly the three direct event types at catalog initial price/version 1, and
  is idempotent and owner-scoped after the account exists.
- Live Google, Stripe, SMTP, and webhook configuration is not complete.
- Test-mode and manual acceptance have not passed.
