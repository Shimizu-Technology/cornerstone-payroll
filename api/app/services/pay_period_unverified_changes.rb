# frozen_string_literal: true

# Resolves open pay-affecting EmployeeVerificationItem records that must be
# surfaced on a pay run and explicitly acknowledged (by id + updated_at
# snapshot) before staff can commit payroll (§2.2B, §4.4).
class PayPeriodUnverifiedChanges
  LIFECYCLE_EVENT_KINDS = %w[new_hire termination rehire].freeze

  EVENT_KIND_SUMMARIES = {
    "new_hire" => "New hire",
    "compensation_change" => "Pay rate or compensation changed",
    "w4_change" => "W-4 withholding changed",
    "payment_method_change" => "Payment method changed",
    "identity_tax_change" => "Tax ID or legal name changed",
    "contractor_tax_change" => "Contractor tax details changed",
    "termination" => "Employee terminated",
    "rehire" => "Employee rehired",
    "profile_change" => "Profile details changed"
  }.freeze

  def initialize(pay_period)
    @pay_period = pay_period
  end

  def relation
    return EmployeeVerificationItem.none unless applicable_period?

    base = EmployeeVerificationItem
      .where(company_id: @pay_period.company_id)
      .open_items
      .affecting_pay

    reportable_employee_ids = @pay_period.payroll_items.financially_reportable.select(:employee_id)
    on_run = base.where(employee_id: reportable_employee_ids)

    lifecycle_scope = base
      .where(event_kind: LIFECYCLE_EVENT_KINDS)
      .where("effective_on IS NULL OR effective_on <= ?", @pay_period.end_date)

    cutoff = last_committed_regular_cutoff
    lifecycle_scope = lifecycle_scope.where("created_at > ?", cutoff) if cutoff.present?

    on_run.or(lifecycle_scope).order(:employee_id, :id)
  end

  def payload
    return [] unless applicable_period?

    relation.includes(:employee).map { |item| serialize_item(item) }
  end

  def serialize_item(item)
    {
      id: item.id,
      updated_at: item.updated_at.utc.iso8601(6),
      employee_id: item.employee_id,
      employee_name: item.employee.full_name,
      event_kind: item.event_kind,
      status: item.status,
      effective_on: item.effective_on&.iso8601,
      summary: summary_for(item)
    }
  end

  private

  def applicable_period?
    @pay_period.status.in?(%w[draft calculated approved]) && !@pay_period.voided?
  end

  def last_committed_regular_cutoff
    last_committed = PayPeriod.reportable_committed
      .where(company_id: @pay_period.company_id, cycle: "regular", run_purpose: "regular")
      .where.not(id: @pay_period.id)
      .where("end_date < ? OR (end_date = ? AND id < ?)", @pay_period.end_date, @pay_period.end_date, @pay_period.id)
      .order(committed_at: :desc, end_date: :desc, id: :desc)
      .first

    last_committed&.committed_at
  end

  def summary_for(item)
    base = EVENT_KIND_SUMMARIES.fetch(item.event_kind, item.event_kind.to_s.humanize)
    fields = Array(item.changed_fields).map(&:to_s).reject(&:blank?)
    return base if fields.empty? || LIFECYCLE_EVENT_KINDS.include?(item.event_kind)

    "#{base} (#{fields.map { |field| field.tr('_', ' ') }.join(', ')})"
  end
end
