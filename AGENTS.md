# My Paw Trainer Tymeslot Agent Guide

This is the public `alexeynesteruk/tymeslot` fork used to build the self-hosted
My Paw Trainer scheduler. It is separate from the marketing website repository
at `/Users/anesteruk/Documents/mypawtrainer.com`.

## Required reading

Before changing application code, read these files in order:

1. `docs/agent/README.md`
2. `docs/agent/REQUIREMENTS.md`
3. `docs/agent/IMPLEMENTATION_PLAN.md`
4. `docs/agent/STATUS.md`
5. `/Users/anesteruk/Documents/mypawtrainer.com/agent-artifacts/SCHEDULING_PAYMENT_DESIGN.md`
6. `/Users/anesteruk/Documents/mypawtrainer.com/agent-artifacts/SCHEDULING_PAYMENT_IMPLEMENTATION_PLAN.md`

The website artifacts are the product source of truth. The files in
`docs/agent/` adapt them to this fork and record execution state.

## Product rules

- Build for one trainer, Anna K.
- Direct booking applies to `discovery-call` ($49, 30 minutes),
  `online-consultation` ($140, 90 minutes), and `in-home-consultation` ($190,
  90 minutes after active ZIP eligibility).
- `online-case-management`, `in-person-case-management`, and
  `assistant-dog-visit` remain approval-first and have no Tymeslot route.
- Google Calendar busy time must block unavailable slots.
- The final Google availability check fails closed when it cannot be verified.
- Stripe-hosted setup mode saves a card during booking without charging it.
- Successful card setup confirms the booking immediately.
- Anna manually charges the immutable booked amount only after completion.
- Online and in-home consultations include one private, single-use 30-minute
  virtual follow-up available from day 5 through day 10.
- Private management links support rescheduling after Anna approves a deadline;
  cancellation requests go to Anna by email.
- Do not add automatic cancellation, late-cancellation, or no-show charges.
- Never collect, transmit, log, or store raw card data.
- Recheck payment ownership in the domain layer, not only in LiveView.
- Make bookings, charges, refunds, and webhook processing safe to retry.
- Keep the fork public and preserve GNU AGPLv3 obligations.

## Engineering rules

- Preserve existing upfront payments and add deferred payment as an explicit mode.
- Use TDD for every behavior change.
- Keep Stripe and Google secrets out of Git, fixtures, logs, and documentation.
- Do not copy website application code into this repository.
- Do not activate production booking until every release gate passes.
- Use signed commits with `git commit -s`.
- Run focused tests, the relevant full gate, and `git diff --check` before commits.
- Do not use em dash characters in source, documentation, or commit messages.

Update `docs/agent/STATUS.md` after each verified task, commit, deployment, or
change in blockers.
