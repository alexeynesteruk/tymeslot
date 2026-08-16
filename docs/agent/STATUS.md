# My Paw Trainer Scheduler Status

Updated: 2026-08-16

## Checkout

- Local worktree: `/Users/anesteruk/Documents/tymeslot/.worktrees/mpt-booking`
- Fork remote: `git@github.com:alexeynesteruk/tymeslot.git`
- Upstream remote: `git@github.com:Tymeslot/tymeslot.git`
- Branch: `feat/mpt-booking`
- HEAD: `5c19a7510eaae9df8a7a6737133d9242e7a29b59`
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
- Stable service identity and versioned booking snapshots: implemented locally,
  pending final review and full baseline gate.
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
17.11 with explicit Homebrew paths. The clean-database migration, focused
tests, compilation with warnings as errors, and formatting checks pass. The
remaining upstream baseline commands must pass before Task 3 application work
begins.

## Next safe action

Run the complete upstream baseline gate and close the service-configuration
review. Do not start service-specific intake or activate production booking.

## Production blockers

- Deferred domain and operator workflows are not implemented.
- Concurrency, webhook, security, and browser gates have not run.
- ARM64 deployment, backups, restore, monitoring, and rollback are not verified.
- Anna has not supplied all production booking and authorization values.
- Anna's scheduler user ID is not approved, so the three direct event types
  cannot be provisioned to an owner yet. Provisioning must be idempotent and
  owner-scoped after the account exists.
- Live Google, Stripe, SMTP, and webhook configuration is not complete.
- Test-mode and manual acceptance have not passed.
