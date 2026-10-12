// Display labels only. Source evidence and payment proof remain authoritative.
function label(value: string | null | undefined, labels: Readonly<Record<string, string>>, fallback: string): string {
  return value && Object.hasOwn(labels, value) ? labels[value] : fallback;
}

export function receiptScopeLabel(value: string | null | undefined): string {
  return label(value, {
  "exact_line": "Receipt for this saved line",
  "unambiguous_entry": "Receipt for this entry's only saved line",
  "ambiguous_entry": "Entry receipt · saved line needs review",
  "batch": "Batch receipt only · no line confirmation",
  "none": "No receipt recorded"
}, "Receipt scope not recognized · line confirmation unavailable");
}

export function evidenceSourceLabel(value: string | null | undefined, receiptScope?: string | null, identityState?: string | null): string {
  const frozenReceiptScopes: Readonly<Record<string, string>> = {
    frozen_batch_and_exact_authenticated_receipt: 'exact_line',
    frozen_batch_with_unambiguous_entry_receipt: 'unambiguous_entry',
    frozen_batch_with_ambiguous_entry_receipt: 'ambiguous_entry',
    frozen_batch_with_batch_receipt: 'batch',
    frozen_batch_with_none_receipt: 'none',
  };
  if (value && Object.hasOwn(frozenReceiptScopes, value)) {
    if (identityState && identityState !== 'verified') return 'Saved batch · receipt identity needs review';
    if (receiptScope !== frozenReceiptScopes[value]) return 'Saved batch · receipt scope needs review';
  }
  return label(value, {
  "frozen_batch_and_exact_authenticated_receipt": "Saved batch and receipt for this line",
  "frozen_batch_with_unambiguous_entry_receipt": "Saved batch and receipt for the entry's only line",
  "frozen_batch_with_ambiguous_entry_receipt": "Saved batch with entry receipt · line needs review",
  "frozen_batch_with_batch_receipt": "Saved batch with batch receipt only",
  "frozen_batch_with_none_receipt": "Saved batch · no receipt recorded",
  "manual_source_allocation": "Manually linked source hours",
  "payment_attestation_pending_exact_evidence": "Reported paid · awaiting matching payment evidence"
}, "Evidence source needs review");
}

export function coverageStateLabel(value: string | null | undefined, identityState?: string | null, receiptScope?: string | null, manualEvidence = false): string {
  // Compatible producers can supply unfamiliar or conflicting fields independently.
  // Keep their hours intact, but do not present unconfirmed line coverage as issued.
  if (value === 'issued' && identityState && identityState !== 'verified') {
    return 'Employee identity needs review · payment coverage unconfirmed';
  }
  const lineReceiptConfirmed = receiptScope === 'exact_line' || receiptScope === 'unambiguous_entry';
  if (value === 'issued' && !lineReceiptConfirmed && !(manualEvidence && !receiptScope)) {
    return 'Receipt needs review · line coverage unconfirmed';
  }
  return label(value, {
  "issued": "Issued payment coverage",
  "committed": "Payroll committed · no active issued coverage",
  "exported": "Exported hours · no issued payment coverage",
  "inactive": "No active payment coverage",
  "identity_review": "Employee identity needs review",
  "receipt_review": "Receipt needs review · line coverage unconfirmed",
  "evidence_hold": "Reported paid · awaiting matching payment evidence"
}, "Coverage status needs review");
}

export function identityStateLabel(value: string | null | undefined): string {
  return label(value, {
  "verified": "Employee identity matched",
  "legacy_identity_unknown": "Original employee identity not recorded",
  "frozen_owner_mismatch": "Saved employee identity does not match"
}, "Employee identity needs review");
}

export function sourceKindLabel(value: string | null | undefined): string {
  return label(value, {
  "current": "Original period hours",
  "carryover": "Carried-over hours",
  "correction": "Correction hours",
  "manual": "Manually linked hours",
  "payment_attestation": "Reported payment"
}, "Source hours · source needs review");
}

export function settlementStatusLabel(value: string | null | undefined): string {
  return label(value, {
  "open": "Needs review",
  "scheduled": "Scheduled",
  "in_payroll": "Included in payroll · receipt confirmation pending",
  "settled": "Resolved",
  "not_payable": "Closed unpaid",
  "superseded": "Replaced by a later case"
}, "Case status needs review");
}

export function historicalReasonLabel(value: string | null | undefined): string {
  return label(value, {
  "pending_approval": "Approval was pending at cutoff",
  "denied_approval": "Approval was denied at cutoff",
  "open_clock": "Clock entry was still open at cutoff",
  "pending_overtime": "Overtime approval was pending at cutoff",
  "denied_overtime": "Overtime approval was denied at cutoff",
  "created_after_cutoff": "Entry was added after cutoff",
  "approved_after_cutoff": "Entry was approved after cutoff",
  "overtime_approved_after_cutoff": "Overtime was approved after cutoff",
  "pending_payment_attestation": "Reported payment needed matching evidence",
  "changed_after_cutoff": "Entry changed after cutoff",
  "deleted_after_cutoff": "Entry was deleted after cutoff"
}, "Recorded reason needs review");
}

export function payRunStatusLabel(value: string | null | undefined): string {
  return label(value, {
  "draft": "Draft",
  "calculated": "Calculated",
  "approved": "Approved",
  "committed": "Committed"
}, "Pay run status unavailable");
}

