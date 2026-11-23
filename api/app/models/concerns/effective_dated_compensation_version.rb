# frozen_string_literal: true

# Shared rules for the effective-dated compensation history tables. A version
# covers effective_on..ends_on (open-ended when ends_on is nil). History is
# changed only inside EmployeeCompensationChangeService; anything else raises.
module EffectiveDatedCompensationVersion
  extend ActiveSupport::Concern

  included do
    validates :effective_on, :reason, :source, presence: true
    validate :ends_on_not_before_effective_on
    validate :company_matches_employee

    before_create :guard_history_write
    before_update :guard_history_write
    before_destroy :guard_history_write

    scope :chronological, -> { order(:effective_on, :id) }
    scope :covering, lambda { |date|
      where("#{table_name}.effective_on <= :date AND (#{table_name}.ends_on IS NULL OR #{table_name}.ends_on >= :date)", date: date)
    }
  end

  def covers?(date)
    date = date.to_date
    effective_on <= date && (ends_on.nil? || ends_on >= date)
  end

  def scheduled?(today = PayrollBusinessClock.today)
    effective_on > today
  end

  private

  def guard_history_write
    return if EmployeeCompensationChangeService.writing?(employee_id)

    raise EmployeeCompensationChangeService::CompensationMutationError,
          "#{self.class.name} rows change only through EmployeeCompensationChangeService"
  end

  def ends_on_not_before_effective_on
    return if ends_on.blank? || effective_on.blank? || ends_on >= effective_on

    errors.add(:ends_on, "must be on or after the effective date")
  end

  def company_matches_employee
    return if employee.blank? || company_id == employee.company_id

    errors.add(:company, "must match the employee's company")
  end
end
