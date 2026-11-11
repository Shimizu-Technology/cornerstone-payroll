# frozen_string_literal: true

# One admin change to an AIRE pay period's lock time. Rows are append-only;
# the newest row for a pay period is its current lock time, and a reset row
# returns it to the policy cutoff.
class AirePayrollCutoffOverride < ApplicationRecord
  ACTIONS = %w[lock_now change reset].freeze
  REQUESTED_VIA = %w[cornerstone_payroll aire_services].freeze
  REASON_MAX = 500

  belongs_to :company
  belongs_to :pay_period
  belongs_to :aire_payroll_calendar_period
  belongs_to :set_by, class_name: "User", optional: true

  validates :override_id, presence: true, uniqueness: true
  validates :action, inclusion: { in: ACTIONS }
  validates :requested_via, inclusion: { in: REQUESTED_VIA }
  validates :reason, presence: true, length: { maximum: REASON_MAX }
  validates :cutoff_at, :previous_cutoff_at, :policy_cutoff_at, presence: true
  validates :request_id, uniqueness: true, allow_nil: true
  validate :actor_present

  before_validation :assign_override_id, on: :create
  before_destroy { throw(:abort) }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.current_for(pay_period)
    latest = where(pay_period_id: pay_period.id).newest_first.first
    latest unless latest.nil? || latest.reset?
  end

  def readonly?
    persisted?
  end

  def reset?
    action == "reset"
  end

  def set_by_name
    set_by&.name.presence || source_actor&.fetch("name", nil)
  end

  def set_by_system
    requested_via
  end

  # The wire shape AIRE stores and shows. Personal contact details stay out.
  def contract_json
    {
      "override_id" => override_id,
      "action" => action,
      "reason" => reason,
      "set_at" => created_at.in_time_zone(AirePayrollCalendar::Contract::TIME_ZONE).iso8601,
      "set_by" => {
        "name" => set_by_name.to_s,
        "system" => requested_via,
        "role" => (set_by&.role || source_actor&.fetch("role", nil)).to_s
      },
      "previous_cutoff_at" => previous_cutoff_at.in_time_zone(AirePayrollCalendar::Contract::TIME_ZONE).iso8601
    }
  end

  private

  def assign_override_id
    self.override_id ||= SecureRandom.uuid
  end

  def actor_present
    case requested_via
    when "cornerstone_payroll"
      errors.add(:set_by, "is required") if set_by.nil?
    when "aire_services"
      errors.add(:source_actor, "is required") unless source_actor.is_a?(Hash) && source_actor["name"].present?
    end
  end
end
