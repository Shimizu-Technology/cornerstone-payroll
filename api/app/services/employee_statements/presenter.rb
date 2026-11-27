# frozen_string_literal: true

class EmployeeStatements
  # JSON for the employee app. Payroll rows start from the presenter AIRE uses
  # (EmployeePayStatements::Presenter), so amounts, hours and payment status
  # read the same way, and add what the employee app needs on top. AIRE's own
  # output is not changed. Payment status is read live from the recorded
  # evidence; it is never part of the frozen PDF.
  class Presenter
    WITHDRAWN_MESSAGE = "This pay stub was withdrawn. A corrected one will follow."
    VOIDED_CHECK_MESSAGE = "Check voided. A replacement is coming. This pay still counts toward your year."
    QUICKBOOKS_LABEL = "From QuickBooks records"
    # The printed stub's tax labels, in PayStubGenerator#tax_lines order.
    TAX_KINDS = [
      [ /\Aadditional (?:withholding|guam income tax)/i, "additional_guam_income_tax", PayrollLabels::ADDITIONAL_WITHHOLDING ],
      [ /income tax/i, "guam_income_tax", PayrollLabels::INCOME_TAX ],
      [ /\Asocial security/i, "social_security", "Social Security" ],
      [ /\Aadditional medicare/i, "additional_medicare", PayrollLabels::STUB_TAXES.fetch(:additional_medicare) ],
      [ /\Amedicare/i, "medicare", PayrollLabels::STUB_TAXES.fetch(:medicare) ]
    ].freeze

    # previous: the regular check listed before this one (EmployeeStatements
    # #previous_regular), for "vs last check". Nil hides the comparison.
    def initialize(statement, statements:, previous: nil)
      @statement = statement
      @statements = statements
      @previous = previous
    end

    def summary
      @statement.kind == :quickbooks ? quickbooks_summary : payroll_summary
    end

    def detail
      @statement.kind == :quickbooks ? quickbooks_detail : payroll_detail
    end

    protected

    def payroll_core
      shared = EmployeePayStatements::Presenter.new(item).summary.except(:has_source_entries)
      shared.merge(
        id: @statement.id,
        source: "payroll",
        source_label: nil,
        pdf_available: document.posted? && !item.voided?,
        **(item.voided? ? { notice: VOIDED_CHECK_MESSAGE } : {}),
        original_pdf: false,
        corrected: document.correction_label?,
        posted_at: document.posted_at.iso8601
      )
    end

    private

    def document
      @statement.document
    end

    def item
      document.payroll_item
    end

    def payroll_summary
      return payroll_core.merge(previous: previous_json) unless @statement.withdrawn?

      period = item.pay_period
      { id: @statement.id, source: "payroll", status: "withdrawn", notice: WITHDRAWN_MESSAGE, pdf_available: false,
        check_date: period.pay_date.iso8601,
        pay_period: { start_date: period.start_date.iso8601, end_date: period.end_date.iso8601, pay_date: period.pay_date.iso8601 } }
    end

    def payroll_detail
      return payroll_summary if @statement.withdrawn?

      shared = EmployeePayStatements::Presenter.new(item).detail(employee_app: true).except(:has_source_entries, :source_entries)
      shared.merge(payroll_summary).merge(
        taxes: shared.fetch(:taxes).map { |row| row.merge(tax_kind(row[:label])) },
        earlier_versions: (item.voided? ? [] : @statements.earlier_versions(document)).map do |version|
          { id: version.id.to_s, status: "replaced", posted_at: version.posted_at.iso8601,
            payment_line: version.payment_line, corrected: version.correction_revision?, ytd_changed: version.ytd_changed? }
        end,
        ytd_changed: document.ytd_changed?,
        note: nil
      )
    end

    # Only a regular check compares, with the regular check before it, and
    # only when both have a take-home amount.
    def previous_json
      return unless @previous && item.pay_period.run_purpose == "regular" && !item.net_pay.nil?

      row = self.class.new(@previous, statements: @statements).payroll_core
      return if row[:net_pay].nil?

      { id: row[:id], pay_date: row.dig(:pay_period, :pay_date), check_date: row[:check_date],
        net_pay: row[:net_pay], total_hours: row[:total_hours] }
    end

    def quickbooks_summary
      check = @statement.check
      adjustments = check.historical_paycheck_adjustments.sort_by(&:id)
      total = ->(field) { check.public_send(field).to_d + adjustments.sum { |row| row.public_send(field).to_d } }
      {
        id: @statement.id,
        source: "quickbooks",
        source_label: QUICKBOOKS_LABEL,
        pay_period: {
          start_date: check.period_start&.iso8601, end_date: check.period_end&.iso8601,
          pay_date: check.pay_date.iso8601, run_purpose: "regular"
        },
        check_date: check.pay_date.iso8601,
        gross_pay: money(total.call(:gross_pay)),
        net_pay: money(total.call(:net_pay)),
        total_hours: hours(total.call(:hours_total)),
        # The app records no payment evidence for QuickBooks checks.
        payment: {
          method: quickbooks_method(check.payment_method), status: nil, issued_on: nil,
          check_number_last4: check.check_number.to_s.last(4).presence
        },
        pdf_available: document.present?,
        original_pdf: document.present?,
        corrected: false,
        posted_at: document&.posted_at&.iso8601,
        previous: nil,
        adjustment_note: ("Includes recorded payroll adjustments." if adjustments.any?)
      }
    end

    # QuickBooks rows show their imported breakdown only when no adjustment
    # was recorded on the check. With one, only the adjusted totals show, so
    # nothing reads as an unadjusted amount.
    def quickbooks_detail
      check = @statement.check
      summary = quickbooks_summary
      adjusted = check.historical_paycheck_adjustments.any?
      total = ->(field) { check.public_send(field).to_d + check.historical_paycheck_adjustments.sum { |row| row.public_send(field).to_d } }
      taxes = [
        [ PayrollLabels::INCOME_TAX, total.call(:federal_income_tax) ],
        [ "Social Security", total.call(:social_security_tax) ],
        [ "Medicare", total.call(:medicare_tax) ]
      ].map { |label, amount| { label: label, amount: money(amount), ytd: nil }.merge(tax_kind(label)) }
      summary.merge(
        earnings: adjusted ? [ gross_line(summary) ] : quickbooks_earnings(check).presence || [ gross_line(summary) ],
        taxes: taxes,
        deductions: adjusted ? quickbooks_deduction_totals(total) : quickbooks_deductions(check),
        other_pay: [],
        ytd: { gross: nil, net: nil },
        earlier_versions: [],
        note: summary[:adjustment_note]
      )
    end

    def gross_line(summary)
      { label: "Gross pay", hours: summary[:total_hours], rate: nil, pay_basis: nil, amount: summary[:gross_pay], ytd: nil, kind: nil }
    end

    def quickbooks_earnings(check)
      hours_by_label = breakdown(check.hours_breakdown).to_h { |row| [ row[:label], row[:amount] ] }
      breakdown(check.earnings_breakdown).map do |row|
        { label: row[:label], hours: hours(hours_by_label[row[:label]]), rate: nil, pay_basis: nil,
          amount: money(row[:amount]), ytd: nil, kind: nil }
      end
    end

    def quickbooks_deductions(check)
      (breakdown(check.pretax_deduction_breakdown) + breakdown(check.after_tax_deduction_breakdown))
        .map { |row| { label: row[:label], amount: money(row[:amount]), ytd: nil } }
    end

    def quickbooks_deduction_totals(total)
      [ [ "Pre-tax deductions", :pretax_deductions ], [ "After-tax deductions", :after_tax_deductions ] ]
        .filter_map do |label, field|
          amount = total.call(field)
          { label: label, amount: money(amount), ytd: nil } if amount.nonzero?
        end
    end

    def breakdown(rows)
      Array(rows).filter_map do |row|
        row = row.to_h.stringify_keys
        label = row["label"].to_s.squish.presence
        amount = row["amount"]
        { label: label, amount: amount.to_d } if label && amount.present?
      rescue ArgumentError, TypeError
        nil
      end
    end

    def quickbooks_method(value)
      text = value.to_s.downcase
      return "direct_deposit" if text.include?("direct")

      "paper_check" if text.include?("check") || text.include?("paper")
    end

    def tax_kind(label)
      _, kind, plain = TAX_KINDS.find { |pattern, _kind, _plain| label.to_s.match?(pattern) }
      { kind: kind, display_label: plain || label.to_s.sub(%r{\bfederal\b\s*/?\s*}i, "").strip.presence || label }
    end

    def money(value)
      return nil if value.nil?

      format("%.2f", value.to_d.round(2))
    end

    def hours(value)
      return nil if value.nil?

      format("%.2f", value.to_d.round(2))
    end
  end
end
