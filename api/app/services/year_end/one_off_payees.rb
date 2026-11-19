# frozen_string_literal: true

module YearEnd
  # One-off contractor checks make a payee reportable on a 1099 without a
  # contractor record, so there is no TIN or address to print. Each such payee
  # blocks the client's 1099s until staff record who it is (the contractor it
  # belongs to, where the W-9 is, or why no 1099 is due). That resolution is an
  # audited acknowledgement bound to the checks and the total it was made on.
  class OneOffPayees
    CODE_PREFIX = "one_off_payee:"

    def self.code?(code)
      code.to_s.start_with?(CODE_PREFIX)
    end

    def self.code_for(payee_key)
      "#{CODE_PREFIX}#{payee_key}"
    end

    def self.digest_for(code, check_ids:, total:, name:)
      JudgmentWarnings.digest_for(code, [ check_ids.sort, BigDecimal(total.to_s).round(2).to_s("F"), name.to_s ])
    end

    # rows: Form1099NecAggregator reportable rows.
    def initialize(company:, year:, rows:, acknowledgements: nil)
      @company = company
      @year = Integer(year)
      @rows = Array(rows).select { |row| row[:employee_id].nil? && row[:payee_key].present? }
      @acknowledgements = acknowledgements || company.year_end_acknowledgements.where(tax_year: @year).index_by(&:warning_code)
    end

    def call
      checks = NonEmployeeCheck.where(company_id: company.id, id: rows.flat_map { |row| row[:non_employee_check_ids] }).includes(:pay_period).index_by(&:id)
      rows.sort_by { |row| [ row[:name].to_s.downcase, row[:payee_key] ] }.map { |row| payload(row, checks) }
    end

    def digests
      rows.to_h { |row| [ self.class.code_for(row[:payee_key]), digest(row) ] }
    end

    private

    attr_reader :company, :year, :rows, :acknowledgements

    def digest(row)
      self.class.digest_for(self.class.code_for(row[:payee_key]), check_ids: Array(row[:non_employee_check_ids]),
                            total: row[:total_compensation], name: row[:name])
    end

    def payload(row, checks)
      code = self.class.code_for(row[:payee_key])
      current_digest = digest(row)
      acknowledgement = acknowledgements[code]
      current = acknowledgement && acknowledgement.warning_digest == current_digest
      {
        code: code,
        payee_key: row[:payee_key],
        name: row[:name],
        total_compensation: row[:total_compensation].to_f,
        payment_count: row[:payment_count],
        checks: Array(row[:non_employee_check_ids]).filter_map do |id|
          check = checks[id]
          next unless check

          { id: check.id, check_number: check.check_number, payment_date: check.effective_payment_date&.iso8601, amount: check.amount.to_f }
        end,
        checks_path: "/checks-payments",
        digest: current_digest,
        status: current ? "identified" : "needs_identity",
        acknowledgement: acknowledgement&.payload,
        acknowledgement_stale: acknowledgement.present? && !current
      }
    end
  end
end
