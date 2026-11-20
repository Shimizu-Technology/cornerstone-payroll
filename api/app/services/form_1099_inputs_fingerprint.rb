# frozen_string_literal: true

require "digest"

# Hashes everything that prints on a client's 1099-NECs and their e-file for
# one year, so a "1099s ready" sign-off expires the moment any of it changes:
# the payer's name, EIN, address, phone and email; each payee's full TIN,
# name and address, whether their W-9 is on file, and the account number,
# name lines and name control the e-file prints; the amounts and withholding;
# which one-off checks are linked to which contractor; every unlinked one-off
# contractor check (below the threshold too); and which one-off payees were
# recorded as owing no 1099. The transmitter (the practice's filing submitter
# profile) is not a client input and is checked when the file is made.
# Activity timestamps are left out, so reloading a report or reprinting a
# check doesn't expire it.
class Form1099InputsFingerprint
  RULE_VERSION = "form-1099-nec-inputs-v3"
  IDENTITY_FIELDS = %w[id first_name middle_name last_name name_suffix business_name contractor_type employment_type
                       address_line1 address_line2 city state zip w9_on_file].freeze

  # report: the unmodified Form1099NecAggregator output, when the caller
  # already built it.
  def initialize(company:, year:, report: nil)
    @company = company
    @year = Integer(year)
    @report = report
  end

  def call
    report = (@report || Form1099NecAggregator.new(company, year).generate).deep_symbolize_keys
    payee_rows = Array(report[:reportable_contractors]).select { |row| row[:employee_id] }.sort_by { |row| row[:employee_id] }
    # Every unlinked one-off payee, below the threshold too: a new or changed
    # check to anyone may belong on a 1099, so it expires the sign-off.
    one_off_rows = Array(report[:all_contractors]).select { |row| row[:employee_id].nil? }.sort_by { |row| row[:payee_key].to_s }
    employees = Employee.where(company_id: company.id, id: payee_rows.map { |row| row[:employee_id] }).index_by(&:id)
    check_ids = (payee_rows + one_off_rows).flat_map { |row| Array(row[:non_employee_check_ids]) }
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
          filing_reason: row[:filing_reason],
          # The full TIN matters even when its last four digits are unchanged.
          identity: employee&.attributes&.slice(*IDENTITY_FIELDS)&.merge("tin" => employee.form_1099_tin),
          # What the e-file and the copies print for this payee beyond the
          # amounts: the account number, the TIN type and the B-record name
          # lines and name control (individual or business).
          efile: employee && {
            account_number: Form1099Pub1220Generator.account_number(employee),
            tin_type: row[:tin_type],
            name_lines: Form1099Pub1220Generator.payee_name_lines(employee, row[:tin_type]),
            name_control: row[:tin_type] == "EIN" ? nil : Form1099Pub1220Generator.name_control(employee)
          }
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
