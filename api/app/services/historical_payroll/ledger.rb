# frozen_string_literal: true

require "digest"

module HistoricalPayroll
  class Ledger
    FIELDS = [ :hours_total, *HistoricalPaycheckAdjustment::MONEY_FIELDS ].freeze
    BREAKDOWN_FIELDS = %i[
      hours_breakdown earnings_breakdown pretax_deduction_breakdown
      after_tax_deduction_breakdown employee_tax_breakdown employer_tax_breakdown
      employer_contribution_breakdown
    ].freeze

    Entry = Data.define(
      :record_type, :record_id, :historical_paycheck_id, :employee_id, :employee,
      :pay_date, :period_start, :period_end, :historical_pay_period,
      *FIELDS, *BREAKDOWN_FIELDS
    )

    def initialize(batch: nil, company_id: nil)
      @batch = batch
      @company_id = batch&.company_id || Integer(company_id)
    end

    def source_paychecks
      scope = HistoricalPaycheck.includes(:employee, :historical_pay_period)
                                .where(company_id: @company_id)
      scope = scope.where(historical_import_batch_id: @batch.id) if @batch
      scope
    end

    def adjustments
      scope = HistoricalPaycheckAdjustment.includes(:historical_paycheck, :events)
                                           .where(company_id: @company_id)
      scope = scope.where(historical_paycheck_id: source_paychecks.select(:id)) if @batch
      scope.chronological
    end

    def entries
      source_entries = source_paychecks.map { |paycheck| entry_for_source(paycheck) }
      adjustment_entries = adjustments.map { |adjustment| entry_for_adjustment(adjustment) }
      (source_entries + adjustment_entries).sort_by { |entry| [ entry.pay_date, entry.record_type, entry.record_id ] }
    end

    def current_totals(paycheck)
      rows = [ paycheck ] + paycheck.historical_paycheck_adjustments.to_a
      FIELDS.to_h do |field|
        [ field, rows.sum(0.to_d) { |row| row.public_send(field).to_d }.round(field == :hours_total ? 4 : 2) ]
      end
    end

    def current_breakdowns(paycheck)
      rows = [ paycheck ] + paycheck.historical_paycheck_adjustments.to_a
      BREAKDOWN_FIELDS.to_h { |field| [ field, combine_breakdown(rows, field) ] }
    end

    def source_totals
      totals(source_paychecks)
    end

    def adjustment_totals
      totals(adjustments)
    end

    def adjusted_totals
      source_totals.merge(adjustment_totals) { |_field, source, delta| (source + delta).round(2) }
    end

    def adjustment_digest
      payload = adjustments.map do |adjustment|
        [ adjustment.id, adjustment.created_at&.iso8601(6), *FIELDS.map { |field| adjustment.public_send(field).to_s } ]
      end
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    private

    def entry_for_source(paycheck)
      build_entry(
        record_type: "source_snapshot",
        record_id: paycheck.id,
        paycheck: paycheck,
        row: paycheck,
        pay_date: paycheck.pay_date
      )
    end

    def entry_for_adjustment(adjustment)
      paycheck = adjustment.historical_paycheck
      build_entry(
        record_type: adjustment.kind,
        record_id: adjustment.id,
        paycheck: paycheck,
        row: adjustment,
        pay_date: adjustment.effective_pay_date
      )
    end

    def build_entry(record_type:, record_id:, paycheck:, row:, pay_date:)
      attributes = {
        record_type: record_type,
        record_id: record_id,
        historical_paycheck_id: paycheck.id,
        employee_id: paycheck.employee_id,
        employee: paycheck.employee,
        pay_date: pay_date,
        period_start: paycheck.period_start,
        period_end: paycheck.period_end,
        historical_pay_period: paycheck.historical_pay_period
      }
      FIELDS.each { |field| attributes[field] = row.public_send(field) }
      BREAKDOWN_FIELDS.each { |field| attributes[field] = row.public_send(field) }
      Entry.new(**attributes)
    end

    def totals(rows)
      HistoricalPaycheckAdjustment::MONEY_FIELDS.to_h do |field|
        [ field, rows.sum(0.to_d) { |row| row.public_send(field).to_d }.round(2) ]
      end
    end

    def combine_breakdown(rows, field)
      totals = Hash.new(0.to_d)
      rows.each do |row|
        Array(row.public_send(field)).each do |entry|
          value = entry.to_h.with_indifferent_access
          totals[value[:label].to_s] += BigDecimal(value[:amount].to_s, exception: false) || 0.to_d
        end
      end
      totals.sort.filter_map do |label, amount|
        next if amount.zero?

        { "label" => label, "amount" => amount.round(2).to_s("F") }
      end
    end
  end
end
