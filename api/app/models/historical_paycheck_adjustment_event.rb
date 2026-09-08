# frozen_string_literal: true

class HistoricalPaycheckAdjustmentEvent < ApplicationRecord
  EVENT_TYPES = %w[
    filing_reviewed_no_amendment filing_amendment_required filing_amendment_filed_external
    filing_review_reopened downstream_impact_acknowledged ytd_revision_activated
  ].freeze

  belongs_to :company
  belongs_to :historical_paycheck_adjustment
  belongs_to :historical_ytd_bridge, optional: true
  belongs_to :created_by, class_name: "User"

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validate :tenant_is_consistent
  validate :activation_bridge_matches_adjustment

  before_update :prevent_change
  before_destroy :prevent_change

  private

  def tenant_is_consistent
    if historical_paycheck_adjustment && historical_paycheck_adjustment.company_id != company_id
      errors.add(:company, "must match the historical paycheck adjustment")
    end
    if historical_ytd_bridge && historical_ytd_bridge.company_id != company_id
      errors.add(:historical_ytd_bridge, "must belong to the same client")
    end
    if created_by && company && created_by.organization_id != company.organization_id
      errors.add(:created_by, "must belong to the same organization")
    end
  end

  def activation_bridge_matches_adjustment
    return unless event_type == "ytd_revision_activated"
    unless historical_ytd_bridge
      errors.add(:historical_ytd_bridge, "is required for a YTD revision activation")
      return
    end
    return unless historical_paycheck_adjustment
    return if historical_ytd_bridge.historical_import_batch_id ==
              historical_paycheck_adjustment.historical_paycheck.historical_import_batch_id

    errors.add(:historical_ytd_bridge, "must belong to the adjustment's historical import")
  end

  def prevent_change
    errors.add(:base, "Historical paycheck adjustment events are append-only")
    throw(:abort)
  end
end
