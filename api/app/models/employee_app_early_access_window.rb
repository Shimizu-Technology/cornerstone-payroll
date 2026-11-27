# frozen_string_literal: true

# M4-9d demo early-access rule (docs/DEMO_COMPANY_PLAN_2026-11-25.md §4).
#
# An owner-approved, dated window during which the named demo companies may
# turn the employee app on before the database enforces row-level security,
# provided the employee service runs its RLS guard in raise mode. It never
# applies to a real company. Only a super_admin (the owner) sets one, for at
# most MAX_DAYS; an extension is a new window with its own approval and
# reason. set_by is that approver. Rows are never edited except to end them,
# or retire them once the database enforces RLS, once. A window stops
# applying after expires_on (a Guam business date) without anyone acting,
# and a retired one never applies again, even back in shadow mode.
class EmployeeAppEarlyAccessWindow < ApplicationRecord
  NAME = "Demo early access before database enforcement"
  MAX_DAYS = 30
  MAX_COMPANIES = 2
  REASON_MAX = 500

  belongs_to :organization
  belongs_to :set_by, class_name: "User"
  belongs_to :ended_by, class_name: "User", optional: true

  validates :expires_on, presence: true
  validates :reason, presence: true, length: { maximum: REASON_MAX }
  validates :end_reason, length: { maximum: REASON_MAX }
  validate :company_ids_shape

  scope :open, -> { where(ended_at: nil, retired_at: nil) }
  scope :history_order, -> { order(created_at: :desc, id: :desc) }

  def self.current_for(organization_id)
    open.where(organization_id: organization_id).order(:id).first
  end

  def approved_by
    set_by
  end

  def ended?
    ended_at.present?
  end

  def retired?
    retired_at.present?
  end

  def expired?(today: PayrollBusinessClock.today)
    today > expires_on
  end

  def in_effect?(today: PayrollBusinessClock.today)
    !ended? && !retired? && !expired?(today: today)
  end

  # True only for a still-demo company named in this open, unexpired window
  # of the company's own organization.
  def covers?(company, today: PayrollBusinessClock.today)
    in_effect?(today: today) && company.is_a?(Company) && company.demo? && company.active? &&
      company.organization_id == organization_id && Array(company_ids).include?(company.id)
  end

  def status(today: PayrollBusinessClock.today)
    return "ended" if ended?
    return "retired" if retired?
    return "expired" if expired?(today: today)

    "in_effect"
  end

  private

  def company_ids_shape
    ids = Array(company_ids)
    if ids.empty? || ids.size > MAX_COMPANIES || ids.any? { |id| !id.is_a?(Integer) } || ids.uniq.size != ids.size
      errors.add(:company_ids, "must name one or #{MAX_COMPANIES} different demo companies")
    end
  end
end
