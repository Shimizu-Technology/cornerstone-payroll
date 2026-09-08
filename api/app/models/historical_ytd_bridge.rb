# frozen_string_literal: true

class HistoricalYtdBridge < ApplicationRecord
  STATUSES = %w[previewed applied].freeze
  BOUNDARY_KEYS = %w[through_period_end through_pay_date].freeze

  belongs_to :company
  belongs_to :historical_import_batch
  belongs_to :historical_client_bootstrap
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :applied_by, class_name: "User", optional: true
  belongs_to :supersedes_historical_ytd_bridge, class_name: "HistoricalYtdBridge", optional: true
  has_many :historical_employee_ytd_balances, dependent: :restrict_with_error
  has_many :historical_paycheck_adjustment_events, dependent: :restrict_with_error
  has_one :superseding_historical_ytd_bridge, class_name: "HistoricalYtdBridge",
                                              foreign_key: :supersedes_historical_ytd_bridge_id,
                                              inverse_of: :supersedes_historical_ytd_bridge,
                                              dependent: :restrict_with_error

  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :revision, uniqueness: { scope: :historical_import_batch_id }
  validates :status, inclusion: { in: STATUSES }
  validates :plan_digest, presence: true
  validate :tenant_and_sources_match
  validate :preview_summary_declares_boundary
  validate :boundary_unchanged_after_balances, on: :update
  validate :revision_chain_is_consistent

  before_update :prevent_applied_update
  before_destroy :prevent_destroy

  def previewed? = status == "previewed"
  def applied? = status == "applied"
  def ready_to_apply? = previewed? && Array(validation_errors).empty?

  private

  def tenant_and_sources_match
    if historical_import_batch && historical_import_batch.company_id != company_id
      errors.add(:historical_import_batch, "must belong to the same client")
    end
    if historical_client_bootstrap && historical_client_bootstrap.company_id != company_id
      errors.add(:historical_client_bootstrap, "must belong to the same client")
    end
    return unless historical_client_bootstrap && historical_import_batch
    return if historical_client_bootstrap.historical_import_batch_id == historical_import_batch_id

    errors.add(:historical_client_bootstrap, "must belong to the same historical import")
  end

  def preview_summary_declares_boundary
    summary = preview_summary.to_h
    dates = {}
    BOUNDARY_KEYS.each do |key|
      value = summary[key].to_s
      parsed = Date.iso8601(value)
      valid = parsed.iso8601 == value
      dates[key] = parsed if valid
      errors.add(:preview_summary, "must include a valid ISO-8601 #{key.humanize.downcase}") unless valid
    rescue Date::Error
      errors.add(:preview_summary, "must include a valid ISO-8601 #{key.humanize.downcase}")
    end
    return unless dates.keys.sort == BOUNDARY_KEYS.sort
    return if dates.fetch("through_pay_date") >= dates.fetch("through_period_end")

    errors.add(:preview_summary, "must have a through pay date on or after the through period end")
  end

  def boundary_unchanged_after_balances
    return unless will_save_change_to_preview_summary?
    return unless historical_employee_ytd_balances.exists?

    errors.add(:preview_summary, "cannot change after historical YTD balances exist")
  end

  def revision_chain_is_consistent
    if revision.to_i == 1 && supersedes_historical_ytd_bridge.present?
      errors.add(:supersedes_historical_ytd_bridge, "must be blank for revision 1")
      return
    end
    return if revision.to_i == 1 && supersedes_historical_ytd_bridge.blank?

    unless supersedes_historical_ytd_bridge
      errors.add(:supersedes_historical_ytd_bridge, "is required after revision 1")
      return
    end
    if supersedes_historical_ytd_bridge.historical_import_batch_id != historical_import_batch_id ||
       supersedes_historical_ytd_bridge.company_id != company_id
      errors.add(:supersedes_historical_ytd_bridge, "must belong to the same historical import")
    end
    if revision != supersedes_historical_ytd_bridge.revision + 1
      errors.add(:revision, "must immediately follow the superseded revision")
    end
  end

  def prevent_applied_update
    persisted_status = self.class.lock.where(id: id).pick(:status)
    return unless persisted_status == "applied"

    errors.add(:base, "Applied historical YTD bridges cannot be changed")
    throw(:abort)
  end

  def prevent_destroy
    errors.add(:base, "Historical YTD bridge evidence cannot be deleted")
    throw(:abort)
  end
end
