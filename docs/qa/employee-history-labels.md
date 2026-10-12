# Employee history evidence labels

Payroll operators review current time alongside frozen source coverage and saved payroll. AIRE owns source hours and receipt scope; Cornerstone owns check components and payment delivery. Raw integration terms on the employee page make that comparison harder to understand.

This change maps recognized evidence values to readable display labels. Stored values, financial calculations, receipt verification, source hours, and links are unchanged. A receipt for a saved line does not confirm issuance. Commitment remains separate from active issued coverage; an unfamiliar value requires review. Operator notes remain verbatim. Source accounting corrections and derived paid-case completion retain their existing meanings.

Sources: the employee evidence producer and types, employee workspace renderer, and the retained I05 desktop/mobile audit. Implementation starts from the reviewed payment-resolution integration merge in each repository.

## Acceptance

- Show current REG/OT separately from frozen source REG/OT and saved payroll REG/OT.
- Describe receipt scope and provenance without exposing integration enum names or implying payment from a receipt alone.
- Preserve local check-delivery/transfer evidence, cancellation reservations, accounting-only notes, signed/unknown hours, and operator-authored reasons.
- Keep unknown evidence labels unresolved; do not label them paid or verified.
- Preserve date filters, exact record links, return navigation, keyboard access, and wrapping at desktop and 390-pixel mobile widths.

Focused rendering tests cover commitment with an exact receipt, unknown scope/identity/coverage, retained free text, signed/unknown hours, and existing accounting/cancellation and navigation behavior. Full frontend checks and actual desktop/mobile acceptance must be recorded with final commits before merge. Physical-phone and uncoached operator acceptance are separate from browser emulation.
