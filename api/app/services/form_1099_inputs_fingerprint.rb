# frozen_string_literal: true

require "digest"

# Hashes everything that prints on a client's 1099-NECs for one year, so a
# "1099s ready" sign-off expires the moment any of it changes: the payer's
# name, EIN, address and phone, each payee's full TIN, name and address, the
# amounts, which one-off checks are linked to which contractor, and which
# one-off payees were recorded as owing no 1099. Activity timestamps are left
# out, so reloading a report or reprinting a check doesn't expire it.
class Form1099InputsFingerprint
  RULE_VERSION = "form-1099-nec-inputs-v1"
  IDENTITY_FIELDS = %w[id first_name middle_name last_name name_suffix business_name contractor_type employment_type
                       address_line1 address_line2 city state zip].freeze

  # report: the unmodified Form1099NecAggregator output, when the caller
  # already built it.
  def initialize(company:, year:, report: nil)
    @company = company
    @year = Integer(year)
    @report = report
  end

  def call
    report = (@report || Form1099NecAggregator.new(company, year).generate).deep_symbolize_keys
    rows = Array(report[:reportable_contractors])
    payee_rows = rows.select { |row| row[:employee_id] }.sort_by { |row| row[:employee_id] }
    one_off_rows = rows.reject { |row| row[:employee_id] }.sort_by { |row| row[:payee_key].to_s }
    employees = Employee.where(company_id: company.id, id: payee_rows.map { |row| row[:employee_id] }).index_by(&:id)
    check_ids = rows.flat_map { |row| Array(row[:non_employee_check_ids]) }
    checks = NonEmployeeCheck.where(company_id: company.id, id: check_ids).order(:id).pluck(:id, :amount, :payee_employee_id)
    codes = one_off_rows.map { |row| YearEnd::OneOffPayees.code_for(row[:payee_key]) }

    snapshot = {
      rule_version: RULE_VERSION,
      tax_year: year,
      threshold: money(report.dig(:meta, :filing_threshold)),
      payer: company.attributes.slice("name", "ein", "address_line1", "address_line2", "city", "state", "zip", "phone", "email"),
      payees: payee_rows.map do |row|
        employee = employees[row[:employee_id]]
        {
          employee_id: row[:employee_id],
          total_compensation: money(row[:total_compensation]),
          federal_withheld: money(row[:federal_withheld]),
          payroll_payment_count: row[:payroll_payment_count],
          non_employee_check_ids: Array(row[:non_employee_check_ids]).sort,
          # The full TIN matters even when its last four digits are unchanged.
          identity: employee&.attributes&.slice(*IDENTITY_FIELDS)&.merge("tin" => employee.form_1099_tin)
        }
      end,
      checks: checks.map { |id, amount, payee_employee_id| [ id, money(amount), payee_employee_id ] },
      one_off_payees: one_off_rows.map do |row|
        { payee_key: row[:payee_key], name: row[:name], non_employee_check_ids: Array(row[:non_employee_check_ids]).sort, total_compensation: money(row[:total_compensation]) }
      end,
      no_1099_due: company.year_end_acknowledgements.where(tax_year: year, warning_code: codes).order(:warning_code).pluck(:warning_code, :warning_digest),
      responsible_party: company.payroll_filing_responsibilities.find_by(tax_year: year, quarter: nil, filing_type: "form_1099")&.responsible_party
    }
    Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize(snapshot)))
  end

  private

  attr_reader :company, :year

  def money(value)
    return nil if value.nil?

    format("%.2f", BigDecimal(value.to_s).round(2))
  end
end
