# frozen_string_literal: true

class EmployeePayStatements
  class Presenter
    def initialize(item)
      @item = item
    end

    def summary
      period = item.pay_period
      {
        id: item.id,
        pay_period: {
          start_date: period.start_date&.iso8601, end_date: period.end_date&.iso8601,
          pay_date: period.pay_date&.iso8601, run_purpose: period.run_purpose
        },
        check_date: (item.check_date || period.pay_date)&.iso8601,
        gross_pay: money(item.gross_pay),
        net_pay: money(item.net_pay),
        total_hours: hours(item.total_hours),
        payment: payment_json,
        has_source_entries: item.time_tracking_entry_allocations.any?
      }
    end

    # employee_app: the employee app's extra fields. AIRE's response stays as it is.
    def detail(employee_app: false)
      statement = PayStubGenerator.new(item).statement
      json = summary.merge(
        earnings: statement.fetch(:earnings).map do |row|
          { label: row[:label], hours: hours(row[:hours]), rate: money(row[:rate]), pay_basis: row[:pay_basis],
            amount: money(row[:amount]), ytd: money(row[:ytd]), kind: row[:kind] }
        end,
        taxes: statement.fetch(:taxes).map { |row| amount_row(row) },
        deductions: statement.fetch(:deductions).map { |row| amount_row(row) },
        other_pay: statement.fetch(:other_pay).map { |row| amount_row(row) },
        ytd: { gross: money(statement.dig(:ytd, :gross)), net: money(statement.dig(:ytd, :net)) },
        source_entries: source_entries_json
      )
      return json unless employee_app

      json.merge(
        # Paid on top of pay, as the PDF prints them (L7).
        employer_contributions: statement.fetch(:employer_contributions).map { |row| amount_row(row) },
        ytd_note: (PayrollBridgeOverlap::EMPLOYEE_NOTE if ytd_under_review?)
      )
    end

    private

    attr_reader :item

    def ytd_under_review?
      date = item.pay_period.pay_date
      PayrollBridgeOverlap.for_employee(employee: item.employee, year: date.year, through: date).any?
    end

    # Status follows the recorded payment evidence, the same rules as the
    # employee pay history and AIRE payment receipts: delivered checks and
    # confirmed transfers are issued; prepared or printed checks are
    # prepared; voided checks and reversed or voided payroll are voided.
    def payment_json
      method = item.effective_payment_delivery_method
      evidence = EmployeePayrollPaymentEvidence.new(item).call
      status = if !item.payroll_included?
        "voided"
      else
        { "voided" => "voided", "issued" => "issued", "printed" => "prepared", "prepared" => "prepared" }.fetch(evidence[:status], "pending")
      end
      {
        method: method,
        status: status,
        issued_on: (evidence[:effective_on]&.iso8601 if status == "issued"),
        check_number_last4: (item.check_number.to_s.last(4).presence if method == "paper_check")
      }
    end

    def source_entries_json
      item.time_tracking_entry_allocations.sort_by { |row| [ row.original_work_date, row.source_time_entry_id.to_s, row.id ] }.map do |row|
        {
          source_time_entry_id: row.source_time_entry_id.to_s,
          work_date: row.original_work_date.iso8601,
          hours: hours(row.total_hours),
          regular_hours: hours(row.regular_hours),
          overtime_hours: hours(row.overtime_hours),
          source_kind: row.source_kind,
          category: row.category_snapshot.to_h["name"]
        }
      end
    end

    def amount_row(row)
      { label: row[:label], amount: money(row[:amount]), ytd: money(row[:ytd]) }
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
