# frozen_string_literal: true

class AirePayrollCalendarPeriod < ApplicationRecord
  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :pay_period

  has_many :publications,
           -> { order(schedule_version: :asc) },
           class_name: "AirePayrollCalendarPublication",
           dependent: :restrict_with_error,
           inverse_of: :aire_payroll_calendar_period
  has_many :payroll_events,
           class_name: "AirePayrollEvent",
           dependent: :restrict_with_error,
           inverse_of: :aire_payroll_calendar_period

  validates :external_pay_period_id, presence: true, uniqueness: true,
            format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i }
  validates :pay_period_id, uniqueness: { scope: :time_tracking_source_id }
  validate :relationships_share_company
  validate :immutable_identity, on: :update

  before_validation :assign_external_pay_period_id, on: :create

  def latest_publication
    publications.max_by(&:schedule_version)
  end

  def latest_delivered_publication
    publications.where(delivery_status: "delivered").order(schedule_version: :desc).first
  end

  def latest_verified_event
    payroll_events.verified.order(occurred_at: :desc, id: :desc).first
  end

  private

  def assign_external_pay_period_id
    self.external_pay_period_id ||= SecureRandom.uuid
  end

  def relationships_share_company
    return if company.blank?

    errors.add(:pay_period, "must belong to the same company") if pay_period && pay_period.company_id != company_id
    if time_tracking_source && time_tracking_source.company_id != company_id
      errors.add(:time_tracking_source, "must belong to the same company")
    end
    if time_tracking_source && time_tracking_source.source_type != "aire_services"
      errors.add(:time_tracking_source, "must be an AIRE Services source")
    end
  end

  def immutable_identity
    changed = changes_to_save.keys & %w[
      company_id time_tracking_source_id pay_period_id external_pay_period_id
    ]
    errors.add(:base, "AIRE calendar period identity is immutable") if changed.any?
  end
end
