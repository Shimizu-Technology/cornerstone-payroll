# frozen_string_literal: true

require "digest"

# A native paycheck paid on or before an applied opening balance's through
# date. The balance holds only imported pay, so the paycheck is either its own
# payment, which must count once, or the same payment the import already
# holds, which must not count twice. The date alone can't tell which, and
# nothing here decides it: readers keep counting as before (the statement
# leaves the paycheck out, W-2GU counts it), the statement says its YTD is
# under review, and W-2GU preflight, mark-ready and final files are blocked
# while any such paycheck exists.
#
# The payment evidence is shown for review only: one imported paycheck in the
# same import with the same pay date, gross and net (and check number when
# both have one) suggests a duplicate; none sharing a pay date, check number
# or amounts suggests a distinct payment; anything else is ambiguous.
class PayrollBridgeOverlap
  Overlap = Data.define(:payroll_item, :balance, :batch_id, :evidence, :proposal, :matched_paycheck_id) do
    # Contractors are never on a W-2GU, so they don't block it.
    def blocks_w2? = payroll_item.employment_type != "contractor"

    def evidence_digest
      Digest::SHA256.hexdigest(JSON.generate(evidence))
    end
  end

  EMPLOYEE_NOTE = "Your year-to-date totals are being reviewed: an earlier paycheck may already be in your opening balance. " \
    "If a total changes, a corrected stub will follow."
  STAFF_NOTE = "A native paycheck is dated inside the imported opening balance, so year-to-date may leave it out or W-2GU may " \
    "count it twice. W-2GU filing is blocked until it is resolved."

  def initialize(company_id:, year:, employee_ids: nil)
    @company_id = Integer(company_id)
    @year = Integer(year)
    @employee_ids = employee_ids&.map { |id| Integer(id) }
  end

  # Every overlapping native paycheck for the year, with its evidence.
  def call
    return [] if balances.empty?

    candidate_items.flat_map do |item|
      balances.fetch(item.employee_id, []).filter_map do |balance|
        next unless inside?(item, balance)

        batch_id = balance.historical_ytd_bridge.historical_import_batch_id
        evidence, proposal, matched = evaluate(item, batch_id)
        Overlap.new(payroll_item: item, balance: balance, batch_id: batch_id, evidence: evidence, proposal: proposal,
          matched_paycheck_id: matched)
      end
    end
  end

  def w2_blocking
    call.select(&:blocks_w2?)
  end

  # An employee's overlapping paychecks paid on or before this date.
  def self.for_employee(employee:, year:, through:)
    new(company_id: employee.company_id, year: year, employee_ids: [ employee.id ]).call
      .select { |overlap| overlap.payroll_item.pay_period.pay_date <= through }
  end

  private

  # The check date the payment carries (the evidence's date) or the run's pay
  # date (the statement's cutoff), whichever is earlier, on or before the
  # balance's through date.
  def inside?(item, balance)
    [ item.check_date, item.pay_period.pay_date ].compact.min <= balance.through_pay_date
  end

  # The latest applied bridge of each locked import: the balances W-2GU reads.
  def balances
    @balances ||= begin
      bridges = HistoricalImportBatch.where(company_id: @company_id, status: "locked")
        .includes(:latest_applied_historical_ytd_bridge).filter_map(&:latest_applied_historical_ytd_bridge)
      scope = HistoricalEmployeeYtdBalance.includes(:historical_ytd_bridge)
        .where(company_id: @company_id, tax_year: @year, historical_ytd_bridge_id: bridges.map(&:id))
      scope = scope.where(employee_id: @employee_ids) if @employee_ids
      scope.to_a.group_by(&:employee_id)
    end
  end

  def candidate_items
    @candidate_items ||= begin
      latest = balances.values.flatten.map(&:through_pay_date).max
      company = Company.find(@company_id)
      PayrollItem.financially_reportable.reportable.joins(:pay_period)
        .where(company_id: @company_id, employee_id: balances.keys)
        .where(pay_period_id: PayPeriod.reportable_for_company(company).where(pay_date: Date.new(@year, 1, 1)..Date.new(@year, 12, 31)).select(:id))
        .where("pay_periods.pay_date <= :latest OR payroll_items.check_date <= :latest", latest: latest)
        .includes(:pay_period, :employee).order(:employee_id, :id).to_a
    end
  end

  def imported_paychecks(batch_id)
    @imported_paychecks ||= {}
    @imported_paychecks[batch_id] ||= HistoricalPaycheck
      .where(historical_import_batch_id: batch_id, employee_id: balances.keys, pay_date: Date.new(@year, 1, 1)..Date.new(@year, 12, 31))
      .order(:id).to_a.group_by(&:employee_id)
  end

  def evaluate(item, batch_id)
    paid_on = item.check_date || item.pay_period.pay_date
    candidates = imported_paychecks(batch_id).fetch(item.employee_id, [])
    rows = candidates.map do |paycheck|
      same_date = paycheck.pay_date == paid_on
      same_amounts = paycheck.gross_pay.to_d == item.gross_pay.to_d && paycheck.net_pay.to_d == item.net_pay.to_d
      numbers = [ paycheck.check_number, item.check_number ].map { |value| value.to_s.strip.presence }
      same_number = numbers.all? && numbers.uniq.one?
      numbers_agree = numbers.any?(&:nil?) || same_number
      {
        paycheck: paycheck, same_date: same_date, same_amounts: same_amounts, same_number: same_number,
        full_match: same_date && same_amounts && numbers_agree
      }
    end
    matches = rows.select { |row| row[:full_match] }
    shared = rows.select { |row| row[:same_date] || row[:same_amounts] || row[:same_number] }
    proposal, matched = if matches.one? && shared.one?
      [ :duplicate, matches.first[:paycheck].id ]
    elsif shared.empty?
      [ :distinct, nil ]
    else
      [ :ambiguous, nil ]
    end
    [ evidence_json(item, paid_on, rows, proposal, matched), proposal, matched ]
  end

  def evidence_json(item, paid_on, rows, proposal, matched)
    {
      "payroll_item" => {
        "id" => item.id, "pay_period_id" => item.pay_period_id, "period_pay_date" => item.pay_period.pay_date.iso8601,
        "paid_on" => paid_on.iso8601, "check_number" => item.check_number.to_s.presence,
        "employment_type" => item.employment_type,
        "gross_pay" => item.gross_pay.to_d.round(2).to_s("F"), "net_pay" => item.net_pay.to_d.round(2).to_s("F")
      },
      "imported_paychecks" => rows.map do |row|
        paycheck = row.fetch(:paycheck)
        {
          "id" => paycheck.id, "external_key" => paycheck.external_key, "source_row_number" => paycheck.source_row_number,
          "pay_date" => paycheck.pay_date.iso8601, "check_number" => paycheck.check_number.to_s.presence,
          "gross_pay" => paycheck.gross_pay.to_d.round(2).to_s("F"), "net_pay" => paycheck.net_pay.to_d.round(2).to_s("F"),
          "same_pay_date" => row[:same_date], "same_amounts" => row[:same_amounts], "same_check_number" => row[:same_number]
        }
      end,
      # For review only; nothing is recorded or applied from it.
      "suggestion" => proposal.to_s,
      "suggested_historical_paycheck_id" => matched
    }
  end
end
