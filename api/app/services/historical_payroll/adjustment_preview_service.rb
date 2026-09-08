# frozen_string_literal: true

require "digest"

module HistoricalPayroll
  class AdjustmentPreviewService
    Result = Data.define(:attributes, :errors, :warnings, :downstream_pay_period_ids, :digest) do
      def ready? = errors.empty?
    end

    def initialize(paycheck:, actor:, attributes:)
      @paycheck = paycheck
      @actor = actor
      @input = attributes.to_h.with_indifferent_access
    end

    def call
      kind = input.fetch(:kind, "correction").to_s
      raise ArgumentError, "Reversals must use the dedicated reversal action" if kind == "reversal"

      attributes = normalized_attributes(kind)
      candidate = HistoricalPaycheckAdjustment.new(
        attributes.merge(company: paycheck.company, historical_paycheck: paycheck, created_by: actor)
      )
      errors = candidate.valid? ? [] : candidate.errors.full_messages
      current_totals = ledger.current_totals(paycheck)
      HistoricalPayroll::Ledger::FIELDS.each do |field|
        next unless current_totals[field] + attributes.fetch(field, 0).to_d < 0

        errors << "#{field.to_s.humanize} cannot reduce the historical paycheck below zero"
      end
      if kind == "void" && ledger.current_totals(paycheck).values.all?(&:zero?)
        errors << "This historical paycheck is already fully voided"
      end
      impacts = downstream_pay_period_ids(attributes.fetch(:effective_pay_date))
      warnings = []
      warnings << "Committed payroll after this date will not be recalculated; acknowledge its downstream impact before activating a revised YTD bridge." if impacts.any?
      Result.new(
        attributes: attributes,
        errors: errors.uniq,
        warnings: warnings,
        downstream_pay_period_ids: impacts,
        digest: Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize(attributes)))
      )
    end

    private

    attr_reader :paycheck, :actor, :input

    def normalized_attributes(kind)
      effective_date = Date.iso8601(input.fetch(:effective_pay_date, paycheck.pay_date).to_s)
      attributes = {
        kind: kind,
        effective_pay_date: effective_date,
        filing_year: effective_date.year,
        filing_quarter: ((effective_date.month - 1) / 3) + 1,
        reason: input.fetch(:reason, "").to_s.strip,
        external_reference: input[:external_reference].presence,
        evidence_metadata: input.fetch(:evidence_metadata, {}).to_h,
        idempotency_key: input.fetch(:idempotency_key, "").to_s.strip
      }
      if kind == "void"
        totals = ledger.current_totals(paycheck).transform_values { |value| -value }
        breakdowns = ledger.current_breakdowns(paycheck).transform_values do |entries|
          entries.map { |entry| entry.merge("amount" => (-BigDecimal(entry.fetch("amount"))).to_s("F")) }
        end
        HistoricalPaycheckAdjustment::BREAKDOWN_TOTALS.each do |breakdown_field, total_field|
          represented = breakdowns[breakdown_field].sum(0.to_d) do |entry|
            BigDecimal(entry.fetch("amount"), exception: false) || 0.to_d
          end
          remainder = totals[total_field] - represented
          next if remainder.zero?

          breakdowns[breakdown_field] << {
            "label" => "Historical void — unclassified source amount",
            "amount" => remainder.to_s("F")
          }
        end
        return attributes.merge(totals).merge(breakdowns)
      end

      HistoricalPayroll::Ledger::FIELDS.each do |field|
        attributes[field] = decimal_value(field)
      end
      attributes[:employee_taxes] = attributes.values_at(:federal_income_tax, :social_security_tax, :medicare_tax).sum(0.to_d) unless input.key?(:employee_taxes)
      attributes[:adjusted_gross] = attributes[:gross_pay] - attributes[:pretax_deductions] unless input.key?(:adjusted_gross)
      unless input.key?(:net_pay)
        attributes[:net_pay] = attributes[:gross_pay] - attributes[:pretax_deductions] -
          attributes[:employee_taxes] - attributes[:after_tax_deductions]
      end
      unless input.key?(:total_payroll_cost)
        attributes[:total_payroll_cost] = attributes[:gross_pay] + attributes[:employer_taxes] + attributes[:employer_contributions]
      end
      HistoricalPayroll::Ledger::BREAKDOWN_FIELDS.each do |field|
        attributes[field] = Array(input[field]).map do |entry|
          value = entry.to_h.with_indifferent_access
          { "label" => value[:label].to_s.strip, "amount" => value[:amount].to_s }
        end
      end
      HistoricalPaycheckAdjustment::BREAKDOWN_TOTALS.each do |breakdown_field, total_field|
        next if attributes[total_field].zero? || attributes[breakdown_field].any?

        attributes[breakdown_field] = [
          { "label" => "Historical correction", "amount" => attributes[total_field].to_s("F") }
        ]
      end
      attributes
    rescue Date::Error, KeyError
      raise ArgumentError, "effective_pay_date must be a valid ISO-8601 date"
    end

    def downstream_pay_period_ids(effective_date)
      PayPeriod.reportable_committed.where(company_id: paycheck.company_id)
               .where("pay_date > ?", effective_date).order(:pay_date, :id).pluck(:id)
    end

    def decimal_value(field)
      return 0.to_d unless input.key?(field)

      value = BigDecimal(input[field].to_s, exception: false)
      raise ArgumentError, "#{field.to_s.humanize} must be a number" unless value

      value
    end

    def ledger
      @ledger ||= Ledger.new(company_id: paycheck.company_id)
    end
  end
end
