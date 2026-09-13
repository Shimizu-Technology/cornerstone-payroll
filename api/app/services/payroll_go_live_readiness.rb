# frozen_string_literal: true

require "set"

class PayrollGoLiveReadiness
  def initialize(review)
    @review = review
  end

  def blockers
    values = []
    values << "Apply the reviewed predecessor setup" unless review.setup_applied?
    values << "Lock the verified historical import" unless review.historical_import_batch.locked?
    values << "Activate the latest historical YTD bridge" unless review.historical_import_batch.historical_ytd_bridge&.applied?
    values << "Resolve every imported employee setup item" if company.employees.active.where(configuration_review_status: "needs_review").exists?
    if review.setup_applied?
      company_setup = PayrollCompanySetupReview.new(review)
      if company_setup.missing_required_fields.any?
        values << "Complete the successor company's legal employer and filing address"
      elsif !company_setup.reviewed_current?
        values << (review.company_setup_digest.present? ? "Re-review company setup because the saved values changed" : "Review and confirm the successor company setup")
      end
    end
    values << "Add an effective W-4 election for every active W-2 employee" if missing_w4_count.positive?
    values << "Verify opening balances for every active recurring loan deduction" if loan_setup_gap_count.positive?
    values << "Move every legacy recurring earning and adjustment to typed payroll fields" if legacy_recurring_component_count.positive?
    values << "Resolve every required employee document checklist" if employee_document_gap_count.positive?
    values << "Confirm the successor pay schedule" unless current_schedule&.confirmed?
    values << "Confirm the successor legal workweek" unless current_workweek&.confirmed?
    values << "Record two consecutive passing parallel payrolls" if review.consecutive_pass_count < 2
    values << "Complete every operational attestation" unless review.attestations_complete?
    values << "Add final review notes" if review.review_notes.to_s.strip.blank?
    values
  end

  def facts
    {
      "historical_import_locked" => review.historical_import_batch.locked?,
      "historical_ytd_active" => review.historical_import_batch.historical_ytd_bridge&.applied? || false,
      "employees_needing_review" => company.employees.active.where(configuration_review_status: "needs_review").count,
      "company_setup_reviewed" => PayrollCompanySetupReview.new(review).reviewed_current?,
      "company_setup_gaps" => PayrollCompanySetupReview.new(review).missing_required_fields.count,
      "employees_missing_w4" => missing_w4_count,
      "loan_setup_gaps" => loan_setup_gap_count,
      "legacy_recurring_components" => legacy_recurring_component_count,
      "employee_document_gaps" => employee_document_gap_count,
      "pay_schedule_confirmed" => current_schedule&.confirmed? || false,
      "workweek_confirmed" => current_workweek&.confirmed? || false,
      "consecutive_parallel_passes" => review.consecutive_pass_count,
      "attestations_complete" => review.attestations_complete?,
      "technical_signoff" => review.technical_signed_at.present?,
      "operations_signoff" => review.operations_signed_at.present?
    }
  end

  private

  attr_reader :review

  def company
    review.company
  end

  def current_schedule
    @current_schedule ||= CompanyPaySchedule.for_date(company.id, review.effective_on)
  end

  def current_workweek
    @current_workweek ||= CompanyWorkweek.for_date(company.id, review.effective_on)
  end

  def missing_w4_count
    @missing_w4_count ||= company.employees.active.where.not(employment_type: "contractor").count do |employee|
      employee.w4_election_on(review.effective_on).blank?
    end
  end

  def loan_setup_gap_count
    @loan_setup_gap_count ||= begin
      tracked_types = company.employee_loans.active.where.not(deduction_type_id: nil)
        .pluck(:employee_id, :deduction_type_id).to_set
      deduction_gaps = EmployeeDeduction.active.joins(:employee, :deduction_type)
        .where(employees: { company_id: company.id }, deduction_types: { sub_category: "loan", active: true })
        .count { |entry| !tracked_types.include?([ entry.employee_id, entry.deduction_type_id ]) }
      field_gaps = EmployeePayrollField.active.joins(:employee, :payroll_field_definition)
        .where(employees: { company_id: company.id }, payroll_field_definitions: { category: "loan", active: true })
        .count { |entry| entry.employee_loan.blank? || !entry.employee_loan.active? }
      deduction_gaps + field_gaps
    end
  end

  def legacy_recurring_component_count
    @legacy_recurring_component_count ||= company.employees.active.sum do |employee|
      PayrollItem.normalize_custom_earning_entries(employee.default_custom_earnings).size +
        Employee.normalize_payroll_adjustments(employee.default_payroll_adjustments).count { |entry| entry["active"] != false }
    end
  end

  def employee_document_gap_count
    @employee_document_gap_count ||= EmployeeDocumentReadiness.gap_count(
      employees: company.employees.active.where(document_readiness_required: true)
    )
  end
end
