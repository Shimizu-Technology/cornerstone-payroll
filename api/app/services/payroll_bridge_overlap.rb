# frozen_string_literal: true

require "digest"

# A native paycheck paid on or before an applied opening balance's through
# date. The balance holds only imported pay, so the paycheck is either its own
# payment, which must count once, or the same payment the import already
# holds, which must not count twice. The pay date alone can't tell which.
#
# Payment evidence proposes an answer: one imported paycheck in the same
# import with the same pay date, gross and net (and check number when both
# have one) is a duplicate; no imported paycheck sharing a pay date, check
# number or amounts is a distinct payment; anything else is ambiguous and
# needs staff review. Only a recorded PayrollItemBridgeOverlapDisposition
# changes what readers count:
# - the as-of-check statement counts the paycheck only once it is recorded
#   distinct, and until then keeps leaving it out, as it always has;
# - W-2GU leaves out one recorded as a duplicate, and otherwise keeps it;
# - until it is recorded, W-2GU preflight blocks and the statement says its
#   year-to-date is under review.
class PayrollBridgeOverlap
  Overlap = Data.define(:payroll_item, :balance, :batch_id, :disposition, :evidence, :proposal, :matched_paycheck_id) do
    def pending? = disposition.nil?

    def evidence_digest
      Digest::SHA256.hexdigest(JSON.generate(evidence))
    end
  end

  PROPOSALS = %i[distinct duplicate ambiguous].freeze
  EMPLOYEE_NOTE = "Your year-to-date totals are being reviewed: an earlier paycheck may already be in your opening balance. " \
    "If a total changes, a corrected stub will follow."
  STAFF_NOTE = "Year-to-date excludes a native paycheck dated inside the imported opening balance until it is recorded as " \
    "its own payment or a duplicate. W-2GU filing is blocked until then."

  def initialize(company_id:, year:, employee_ids: nil)
    @company_id = Integer(company_id)
    @year = Integer(year)
    @employee_ids = employee_ids&.map { |id| Integer(id) }
  end

  # Every overlapping native paycheck for the year, with its evidence.
  def call
    return [] if balances.empty?

    dispositions = PayrollItemBridgeOverlapDisposition.where(company_id: @company_id, payroll_item_id: candidate_items.map(&:id))
      .index_by { |row| [ row.payroll_item_id, row.historical_import_batch_id ] }
    candidate_items.flat_map do |item|
      balances.fetch(item.employee_id, []).filter_map do |balance|
        next unless item.pay_period.pay_date <= balance.through_pay_date

        batch_id = balance.historical_ytd_bridge.historical_import_batch_id
        evidence, proposal, matched = evaluate(item, batch_id)
        Overlap.new(payroll_item: item, balance: balance, batch_id: batch_id,
          disposition: dispositions[[ item.id, batch_id ]], evidence: evidence, proposal: proposal, matched_paycheck_id: matched)
      end
    end
  end

  def pending
    call.select(&:pending?)
  end

  # Native paychecks recorded as distinct payments against this import: the
  # only ones dated inside its balance that a statement counts.
  def self.distinct_item_ids(company_id:, batch_id:)
    PayrollItemBridgeOverlapDisposition.distinct_payments
      .where(company_id: company_id, historical_import_batch_id: batch_id).select(:payroll_item_id)
  end

  # Native paychecks recorded as the same payment an import already holds.
  def self.duplicate_item_ids(company_ids)
    PayrollItemBridgeOverlapDisposition.duplicates.where(company_id: company_ids).select(:payroll_item_id)
  end

  # An employee's overlapping paychecks still awaiting a disposition, paid on
  # or before this date.
  def self.pending_for(employee:, year:, through:)
    new(company_id: employee.company_id, year: year, employee_ids: [ employee.id ]).pending
      .select { |overlap| overlap.payroll_item.pay_period.pay_date <= through }
  end

  private

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
      PayrollItem.financially_reportable.reportable
        .where(company_id: @company_id, employee_id: balances.keys)
        .where(pay_period_id: PayPeriod.reportable_for_company(company).where(pay_date: Date.new(@year, 1, 1)..latest).select(:id))
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
      same_date = paycheck.pay_date == paid_on || paycheck.pay_date == item.pay_period.pay_date
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
      "proposal" => proposal.to_s,
      "matched_historical_paycheck_id" => matched
    }
  end
end
