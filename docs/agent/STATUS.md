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
17.11 with explicit Homebrew paths. The Task 3 wizard-completion suites pass 65 tests: intake 15,
state-machine helpers 10, custom-field validator 14, booking submission
handler 5, questions engine 19, and MPT intake LiveView 2. Formatting and
`git diff --check` pass.
Date-boundary failures in the upstream calendar and scheduling tests remain
repaired. The complete gate has not been re-run in this change.

## Next safe action

Implement Task 4 ZIP eligibility in this worktree. Do not activate
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
