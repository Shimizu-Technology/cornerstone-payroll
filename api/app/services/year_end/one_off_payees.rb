# frozen_string_literal: true

module YearEnd
  # One-off contractor checks make a payee reportable on a 1099 without a
  # contractor record, so there is no TIN or address to print. Each such payee
  # blocks the client's 1099s until staff resolve it, one of two ways:
  #
  #   - link its checks to a contractor record (an existing one, or one made
  #     from the payee's W-9). The checks then count toward that contractor's
  #     single 1099 and leave this list (OneOffPayeeResolver).
  #   - record why no 1099 is due: an audited acknowledgement bound to the
  #     checks and the total it was made on. That payee gets no 1099.
  class OneOffPayees
    CODE_PREFIX = "one_off_payee:"
    # Part of every digest. Acknowledgements recorded before an
    # acknowledgement meant "no 1099 is due" (when it only said who the payee
    # was) carry no marker, so they no longer match and ask to be resolved again.
    RESOLUTION = "no_1099_due"

    def self.code?(code)
      code.to_s.start_with?(CODE_PREFIX)
    end

    def self.code_for(payee_key)
      "#{CODE_PREFIX}#{payee_key}"
    end

    # Bound to each check's own amount, not only the total: two unpaid
    # checks can be edited by offsetting amounts and keep the same total.
    # The checklist, the recorder and the clients list all call this.
    def self.digest_for(code, checks:, name:)
      pairs = checks.map { |check| [ check.id, money(check.amount) ] }.sort_by(&:first)
      total = money(checks.sum(0.to_d) { |check| check.amount.to_d })
      JudgmentWarnings.digest_for(code, [ pairs, total, name.to_s, RESOLUTION ])
    end

    # Printed or paid contractor checks dated in the year, for several
    # companies in one query, chosen the way Form1099NecAggregator chooses
    # them. Includes checks linked to a contractor record.
    def self.issued_checks(company_ids, year)
      return [] if company_ids.empty?

      range = Date.new(year, 1, 1)..Date.new(year, 12, 31)
      contractor = NonEmployeeCheck.active.where(company_id: company_ids, check_type: "contractor")
      contractor.where(payment_date: range).or(contractor.where(payment_date: nil)).includes(:pay_period).to_a
        .select { |check| (check.printed_at.present? || check.paid_at.present?) && range.cover?(check.effective_payment_date) }
    end

    # The unlinked issued checks, grouped by company and exact payee name.
    # `checks` lets a caller reuse issued_checks it already loaded.
    def self.issued_check_groups(company_ids, year, checks: nil)
      (checks || issued_checks(company_ids, year)).reject(&:payee_employee_id)
        .group_by { |check| [ check.company_id, check.payable_to ] }
    end

    # Linked issued checks, as { [company_id, employee_id] => amount }.
    def self.linked_totals(checks)
      checks.select(&:payee_employee_id).group_by { |check| [ check.company_id, check.payee_employee_id ] }
        .transform_values { |linked| linked.sum(0.to_d) { |check| check.amount.to_d } }
    end

    # Payee groups that reach the 1099-NEC threshold. With no threshold set,
    # every issued check counts, so a client is never treated as having none.
    def self.reportable_groups(groups, threshold)
      groups.select { |_key, payments| threshold.nil? || payments.sum(0.to_d) { |check| check.amount.to_d }.round(2) >= threshold }
    end

    def self.money(value)
      BigDecimal(value.to_s.presence || "0").round(2).to_s("F")
    end

    # rows: Form1099NecAggregator reportable rows.
    def initialize(company:, year:, rows:, acknowledgements: nil)
      @company = company
      @year = Integer(year)
      @rows = Array(rows).select { |row| row[:employee_id].nil? && row[:payee_key].present? }
      @acknowledgements = acknowledgements || company.year_end_acknowledgements.where(tax_year: @year).index_by(&:warning_code)
    end

    def call
      rows.sort_by { |row| [ row[:name].to_s.downcase, row[:payee_key] ] }.map { |row| payload(row) }
    end

    def digests
      rows.to_h { |row| [ self.class.code_for(row[:payee_key]), digest(row) ] }
    end

    private

    attr_reader :company, :year, :rows, :acknowledgements

    def checks
      @checks ||= NonEmployeeCheck.where(company_id: company.id, id: rows.flat_map { |row| row[:non_employee_check_ids] })
        .includes(:pay_period).index_by(&:id)
    end

    def row_checks(row)
      Array(row[:non_employee_check_ids]).filter_map { |id| checks[id] }
    end

    def digest(row)
      self.class.digest_for(self.class.code_for(row[:payee_key]), checks: row_checks(row), name: row[:name])
    end

    # Money stays BigDecimal until the response, which sends numbers rounded
    # to the cent like the reconciliation.
    def payload(row)
      code = self.class.code_for(row[:payee_key])
      current_digest = digest(row)
      acknowledgement = acknowledgements[code]
      current = acknowledgement && acknowledgement.warning_digest == current_digest
      payee_checks = row_checks(row)
      {
        code: code,
        payee_key: row[:payee_key],
        name: row[:name],
        total_compensation: payee_checks.sum(0.to_d) { |check| check.amount.to_d }.round(2).to_f,
        payment_count: row[:payment_count],
        checks: payee_checks.map do |check|
          { id: check.id, check_number: check.check_number, payment_date: check.effective_payment_date&.iso8601, amount: check.amount.to_d.round(2).to_f }
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
