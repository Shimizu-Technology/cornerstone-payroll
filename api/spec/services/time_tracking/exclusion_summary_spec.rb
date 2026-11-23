# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ExclusionSummary do
  {
    "pending_approval" => :needs_action,
    "pending_overtime" => :needs_action,
    "open_clock" => :needs_action,
    "denied_approval" => :not_paid_by_decision,
    "denied_overtime" => :not_paid_by_decision,
    "approved_after_cutoff" => :next_payroll,
    "created_after_cutoff" => :next_payroll,
    "overtime_approved_after_cutoff" => :next_payroll,
    "pending_payment_attestation" => :payment_evidence_pending,
    "payment_attested_pending_evidence" => :payment_evidence_pending,
    "payment_evidence_pending" => :payment_evidence_pending,
    "future_source_reason" => :needs_action,
    nil => :needs_action
  }.each do |reason, expected|
    it "classifies #{reason.inspect} as #{expected}" do
      expect(described_class.category(reason)).to eq(expected)
    end
  end
end
