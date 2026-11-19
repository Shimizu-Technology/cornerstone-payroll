# frozen_string_literal: true

class W2FilingReadiness < ApplicationRecord
  STATUSES = %w[draft preflight_passed filing_ready].freeze

  belongs_to :company
  belongs_to :marked_ready_by, class_name: "User", optional: true

  validate :preserve_attestation_history

  validates :year,
    presence: true,
    numericality: {
      only_integer: true,
      greater_than: 2000,
      less_than_or_equal_to: ->(_record) { Date.current.year + 1 }
    }
  validates :status, inclusion: { in: STATUSES }
  validates :company_id, uniqueness: { scope: :year }
  def current?(fingerprint)
    status == "filing_ready" && ready_fingerprint.present? && ready_fingerprint == fingerprint
  end

  def preflight_current?(fingerprint)
    preflight_fingerprint.present? && preflight_fingerprint == fingerprint
  end

  def review_payload(fingerprint:)
    stale = status.in?(%w[filing_ready preflight_passed]) &&
      !(status == "filing_ready" ? current?(fingerprint) : preflight_current?(fingerprint))
    {
      year: year,
      status: stale ? "stale" : status,
      stale: stale,
      preflight_current: preflight_current?(fingerprint),
      preflight_fingerprint: preflight_fingerprint,
      ready_fingerprint: ready_fingerprint,
      attestation_history: attestation_history,
      blocking_count: blocking_count,
      warning_count: warning_count,
      preflight_run_at: preflight_run_at,
      marked_ready_at: marked_ready_at,
      marked_ready_by_id: marked_ready_by_id,
      notes: notes,
      findings: findings,
      findings_source: "persisted"
    }
  end

  private

  def preserve_attestation_history
    return if new_record? || !will_save_change_to_attestation_history?

    retained = attestation_history_in_database || []
    errors.add(:attestation_history, "cannot rewrite previous reviews") unless attestation_history.first(retained.length) == retained
  end
end
