# My Paw Trainer Scheduler Implementation Plan

Use TDD and signed commits. The detailed approved plan is
`/Users/anesteruk/Documents/mypawtrainer.com/docs/superpowers/plans/2026-08-16-tymeslot-multi-service-booking.md`.

## Current order

1. Reconcile the multi-service contract in scheduler documents.
2. Add stable six-service identity and versioned direct-book configuration.
3. Add service intake, ZIP eligibility, and fresh fail-closed booking guards.
4. Add Stripe setup mode, immutable payment snapshots, completion, and manual
   charging.
5. Add private rescheduling, included follow-up, signed price projections, and
   minimum asynchronous CRM projection.
6. Add operations, recovery, and test-mode acceptance before activation.

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
