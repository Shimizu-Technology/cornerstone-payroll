# frozen_string_literal: true

# A Clerk revocation the demo kill switch requested (M4-9d): a pending
# sign-up invitation, or every session of an employee-only demo login. The
# row is the durable request; RevokeEmployeeAppClerkJob retries it until
# Clerk confirms (confirmed_at) or the retries run out (gave_up_at), and
# audits the confirmed outcome separately from the request. While a row is
# still pending, a repeat stop finds it instead of queueing a duplicate.
class EmployeeAppClerkRevocation < ApplicationRecord
  KINDS = %w[invitation sessions].freeze
  SOURCE_DEMO_STOP = "demo_stop"

  belongs_to :organization
  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :requested_by, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :target, :source, :requested_at, presence: true

  scope :pending, -> { where(confirmed_at: nil, gave_up_at: nil) }

  # Records the request unless the same one is still pending. Returns the
  # new row, or nil for a duplicate. Run inside the caller's transaction;
  # enqueue the job after commit.
  def self.request!(kind:, target:, organization:, company:, source:, requested_by:, user: nil, now: Time.current)
    return nil if pending.exists?(kind: kind, target: target.to_s)

    transaction(requires_new: true) do
      create!(kind: kind, target: target.to_s, organization: organization, company: company, user: user,
        source: source, requested_by: requested_by, requested_at: now)
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def pending?
    confirmed_at.nil? && gave_up_at.nil?
  end
end
