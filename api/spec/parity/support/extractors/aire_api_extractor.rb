# frozen_string_literal: true

module Parity
  module Extractors
    # Calls the real AIRE Worker Statements integration endpoints
    # (`Api::V1::Integrations::Aire::WorkerStatementsController` backed by
    # `EmployeePayStatements::Presenter`) and maps payloads to canonical parity keys.
    class AireApiExtractor
      include Parity::CanonicalSchema

      def initialize(request_context:, headers:, worker_uuid:)
        @ctx = request_context
        @headers = headers
        @worker_uuid = worker_uuid
      end

      def statements_list
        @ctx.get "/api/v1/integrations/time_payroll/workers/#{@worker_uuid}/statements", headers: @headers
        raise "GET AIRE statements list failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body
      end

      def statement_detail(payroll_item_id)
        @ctx.get "/api/v1/integrations/time_payroll/workers/#{@worker_uuid}/statements/#{payroll_item_id}", headers: @headers
        return nil if @ctx.response.status == 404
        raise "GET AIRE statement #{payroll_item_id} failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body
      end

      def extract_paycheck(payroll_item_id:)
        detail = statement_detail(payroll_item_id)
        return { status: { visible: false } } if detail.nil?

        taxes = parse_taxes(detail.fetch("taxes", []))
        deductions = parse_deductions(detail.fetch("deductions", []))
        payment = detail.fetch("payment", {})
        pay_period = detail.fetch("pay_period", {})
        ytd_summary = detail.fetch("ytd", {})
        other_pay = detail.fetch("other_pay", [])
        non_taxable_current = other_pay.sum(0.to_d) { |row| money(row["amount"]).to_d }.round(2)

        {
          gross_pay: money(detail["gross_pay"]),
          net_pay: money(detail["net_pay"]),
          non_taxable_pay: non_taxable_current,
          taxes: taxes[:amounts],
          deductions: deductions,
          hours: {
            combined: hours(detail["total_hours"])
          },
          ytd: {
            gross: money(ytd_summary["gross"]),
            income_tax: taxes[:ytd][:income_tax],
            additional_withholding: taxes[:ytd][:additional_withholding],
            total_income_tax: sum_present(taxes[:ytd][:income_tax], taxes[:ytd][:additional_withholding]),
            social_security: taxes[:ytd][:social_security],
            medicare_total: taxes[:ytd][:medicare_total],
            net: money(ytd_summary["net"])
          },
          dates: {
            period_start: iso_date(pay_period["start_date"]),
            period_end: iso_date(pay_period["end_date"]),
            pay_date: iso_date(detail["check_date"] || pay_period["pay_date"])
          },
          payment: {
            method: payment["method"],
            # The AIRE worker app shows only the last 4 digits.
            check_number: nil,
            check_number_last4: normalize_check_number(payment["check_number_last4"]),
            status: payment["status"]
          },
          status: {
            visible: true,
            voided: payment["status"] == "voided"
          }
        }
      end

      private

      def parse_taxes(rows)
        amounts = {
          income_tax: money(0),
          additional_withholding: money(0),
          social_security: money(0),
          medicare_base: nil,
          additional_medicare: nil,
          medicare_total: money(0)
        }
        ytd = {
          income_tax: money(0),
          additional_withholding: money(0),
          social_security: money(0),
          medicare_total: money(0)
        }
        med_row_amt = nil
        med_row_ytd = nil
        addl_med_ytd = nil

        rows.each do |row|
          down = row["label"].to_s.downcase
          if down.start_with?("additional medicare")
            amounts[:additional_medicare] = money(row["amount"])
            addl_med_ytd = money(row["ytd"])
          elsif down.include?("additional withholding") || down.include?("w-4 4c")
            amounts[:additional_withholding] = money(row["amount"])
            ytd[:additional_withholding] = money(row["ytd"])
          elsif down.include?("income tax")
            amounts[:income_tax] = money(row["amount"])
            ytd[:income_tax] = money(row["ytd"])
          elsif down.start_with?("social security")
            amounts[:social_security] = money(row["amount"])
            ytd[:social_security] = money(row["ytd"])
          elsif down.start_with?("medicare")
            med_row_amt = money(row["amount"])
            med_row_ytd = money(row["ytd"])
          end
        end

        if amounts[:additional_medicare]
          amounts[:medicare_base] = med_row_amt || money(0)
          amounts[:medicare_total] = (amounts[:medicare_base] + amounts[:additional_medicare]).round(2)
          ytd[:medicare_total] = sum_present(med_row_ytd, addl_med_ytd) || money(0)
        elsif med_row_amt
          amounts[:medicare_total] = med_row_amt
          ytd[:medicare_total] = med_row_ytd || money(0)
        end

        amounts[:total_income_tax] = (amounts[:income_tax] + amounts[:additional_withholding]).round(2)
        amounts[:total_taxes] = (amounts[:total_income_tax] + amounts[:social_security] + amounts[:medicare_total]).round(2)
        { amounts: amounts, ytd: ytd }
      end

      def parse_deductions(rows)
        rows.each_with_object({}) do |row, acc|
          key = canonical_deduction_key(row["label"])
          acc[key] = { label: row["label"], amount: money(row["amount"]), ytd: money(row["ytd"]) }
        end
      end

      def sum_present(*values)
        present = values.compact
        return nil if present.empty?

        present.sum(0.to_d).round(2)
      end
    end
  end
end
