# My Paw Trainer Scheduler Implementation Plan

Use TDD and signed commits. The detailed approved plan is
`/Users/anesteruk/Documents/mypawtrainer.com/docs/superpowers/plans/2026-08-16-tymeslot-multi-service-booking.md`.

## Current order

1. Reconcile the multi-service contract in scheduler documents. Done.
2. Add stable six-service identity and versioned direct-book configuration.
   Done.
3. Add service intake, ZIP eligibility, and fresh fail-closed booking guards.
   Done.
4. Add Stripe setup mode, immutable payment snapshots, completion, and manual
   charging. Done locally; host payments are Stripe test-mode only.
5. Add private rescheduling, included follow-up, signed price projections, and
   minimum asynchronous CRM projection. Done locally; delivery stays disabled.
6. Add operations, recovery, and test-mode acceptance before activation.
   Started. Production-disabled image `tymeslot:1eb79b11` is on VM 2. Task 16
   is not accepted. Remaining, in order:
   1. Leave `mix credo --strict` as residual upstream debt.
   2. Private Stripe test-mode recovery. Done: `charge_failed` plus
      `RecoverySessions.create/2`. Recovery Checkout not completed.
   3. Private Stripe test-mode refund. Done: full `$140` refund on
      payment `0d85db80-9625-4008-a129-f84043c0aa48`.
   4. Optional application rollback rehearsal to `tymeslot:702c589f`.
   5. Optional private `$49` / `$190` probes with types deactivated afterward.
   6. Record evidence. This change. Do not start Task 17.

## Current Task 2 contract

Direct booking is limited to `discovery-call`, `online-consultation`, and
`in-home-consultation`. Their initial prices are $49, $140, and $190. Event
configuration stores a stable ID, positive USD price, and positive version.
The booking snapshots ID, public name, price, currency, duration, delivery
mode, and event-type version in the same transaction as its insert.

An owner-scoped row lock prevents a price edit between snapshot creation and
booking persistence. Future price changes require the expected version and
increment it. Existing snapshots never change. Intake, payments, CRM, and
infrastructure are outside Tasks 1 and 2.
