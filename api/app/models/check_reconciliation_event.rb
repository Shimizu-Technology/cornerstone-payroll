# frozen_string_literal: true

class CheckReconciliationEvent < ApplicationRecord
  EVENT_TYPES = %w[cleared clearing_reversed replacement_required].freeze
  EVIDENCE_TYPES = %w[bank_statement bank_portal accountant_review payee_confirmation other].freeze

  belongs_to :company
  belongs_to :pay_period, optional: true
  belongs_to :payroll_item, optional: true
  belongs_to :non_employee_check, optional: true
  belongs_to :recorded_by, class_name: "User"

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :check_number, :idempotency_key, presence: true
  validates :amount, numericality: { greater_than: 0 }
  validates :effective_on, presence: true
  validates :evidence_type, inclusion: { in: EVIDENCE_TYPES }, allow_nil: true
  validates :idempotency_key, uniqueness: { scope: :company_id }
  validate :exactly_one_source
  validate :source_belongs_to_company_and_period
  validate :effective_date_is_not_in_the_future

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :for_instrument, ->(source, check_number) do
    source_column = source.is_a?(PayrollItem) ? :payroll_item_id : :non_employee_check_id
    where(source_column => source.id, check_number: check_number)
  end

  def source
    payroll_item || non_employee_check
  end

  private

  def exactly_one_source
    return if payroll_item.present? ^ non_employee_check.present?

    errors.add(:base, "Select exactly one check source")
  end

  def source_belongs_to_company_and_period
    return unless source

    errors.add(:company, "must match the check") unless source.company_id == company_id
    errors.add(:recorded_by, "must belong to the company's organization") unless recorded_by&.organization_id == company&.organization_id

    if payroll_item
      errors.add(:pay_period, "must match the payroll check") unless pay_period_id == payroll_item.pay_period_id
    elsif non_employee_check.pay_period_id != pay_period_id
      errors.add(:pay_period, "must match the non-employee check")
    end
  end

  def prevent_mutation
    errors.add(:base, "Check reconciliation evidence is append-only")
    throw :abort
  end

  def effective_date_is_not_in_the_future
    errors.add(:effective_on, "cannot be in the future") if effective_on.present? && effective_on > PayrollBusinessClock.today
  end
end
