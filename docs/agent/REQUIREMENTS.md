# My Paw Trainer Scheduler Requirements

Status: approved multi-service design, implementation in progress.

## Service identity and routing

Exactly six stable services are published:

| ID | Price | Duration | Route |
| --- | ---: | ---: | --- |
| `discovery-call` | $49 | 30 minutes | Direct booking |
| `online-consultation` | $140 | 90 minutes | Direct booking |
| `in-home-consultation` | $190 | 90 minutes | Direct after ZIP eligibility |
| `online-case-management` | $540 | Approval-defined | Approval-first |
| `in-person-case-management` | $690 | Approval-defined | Approval-first |
| `assistant-dog-visit` | $350 | Approval-defined | Approval-first |

The six IDs are code-owned. Tymeslot owns the three directly bookable event
types, their future prices and versions, availability, and booking records.
Approval-first services have no normal Tymeslot event routes in this release.

## Booking and payment

All direct services use one Google Calendar, shared Anna-configured hours,
Eastern time, minimum notice, booking window, and buffer. In-home booking
requires an active approved five-digit ZIP before times appear. Exact operating
values are release blockers and must not be invented.

The final availability check uses a complete fresh Google busy set and fails
closed when unavailable, incomplete, timed out, or unverifiable. A per-trainer
database lock protects the final conflict check and booking insert.

Stripe-hosted setup mode saves a card without charging it. Successful setup
confirms the booking immediately. Anna may manually charge only the immutable
booked amount after marking the appointment completed. Raw card data never
enters Tymeslot.

## Intake and follow-up

Discovery intake requires client name, email, and one main question, with dog
name optional. Full online and in-home intake requires client name, email, dog
name, breed or mix, dog age, sex, spay or neuter status, origin, acquisition
age, main concern, brief context, and desired result. Phone and meeting-mode
fields are absent.

Online and in-home consultations receive one private, single-use, 30-minute
virtual follow-up link available from day 5 through day 10. `follow-up` is an
internal child-booking type, not a seventh public service. It is excluded from
the public catalog, SEO, normal routes, and service counts.

Rescheduling uses a private management link after Anna approves the deadline.
Cancellation requests go to Anna by email. Automatic cancellation,
late-cancellation, and no-show fees are disabled.

## Release blockers

Anna's hours and Eastern timezone configuration, minimum notice, booking
window, buffer, rescheduling deadline, active ZIP list, saved-card
authorization, cancellation and refund policy, safety wording, test
integrations, backup and restore proof, and measured load thresholds must be
approved before production activation.
