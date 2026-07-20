# frozen_string_literal: true

class PayrollLiabilityDueDateService
  def initialize(pay_period:, actor:, authority:, category:, due_date:)
    @pay_period = pay_period
    @actor = actor
    @authority = authority.to_s.strip
    @category = category.to_s
    @due_date = due_date
  end

  def call
    parsed_due_date = Date.iso8601(due_date.to_s)
    PayPeriod.transaction do
      period = PayPeriod.lock.find(pay_period.id)
      validate_context!(period)
      raise ArgumentError, "No active liability exists for this recipient and category" unless active_postings(period).exists?

      record = PayrollLiabilityDueDate.find_or_initialize_by(pay_period: period, category:, authority:)
      record.assign_attributes(company: period.company, due_date: parsed_due_date, updated_by: actor)
      record.save!
      record
    end
  rescue Date::Error
    raise ArgumentError, "Due date is invalid"
  end

  private

  attr_reader :pay_period, :actor, :authority, :category, :due_date

  def validate_context!(period)
    raise ArgumentError, "Due dates require a committed pay period" unless period.committed?
    unless actor&.organization_id == period.company.organization_id && actor.can_access_company?(period.company_id)
      raise ArgumentError, "User cannot update due dates for this client"
    end
    raise ArgumentError, "Recipient is required" if authority.blank?
    raise ArgumentError, "Liability category is invalid" unless category.in?(PayrollLiabilityEntry::CATEGORIES)
  end

  def active_postings(period)
    reversed_ids = period.payroll_liability_postings.where.not(source_posting_id: nil).pluck(:source_posting_id)
    period.payroll_liability_postings
      .where.not(posting_type: "reversal")
      .where.not(id: reversed_ids)
      .joins(:entries)
      .where(payroll_liability_entries: { category:, authority: })
      .distinct
  end
end
