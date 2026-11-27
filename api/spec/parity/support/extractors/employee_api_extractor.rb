# frozen_string_literal: true

module Parity
  module Extractors
    # Calls the real Employee Portal HTTP endpoints and maps the JSON payloads
    # to the canonical parity hash.
    class EmployeeApiExtractor
      include Parity::CanonicalSchema

      def initialize(request_context:, headers:)
        @ctx = request_context
        @headers = headers
      end

      def statements_list(year:)
        @ctx.get "/api/v1/employee/statements", params: { year: year }, headers: @headers
        raise "GET /api/v1/employee/statements failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body
      end

      def statement_detail(statement_id)
        @ctx.get "/api/v1/employee/statements/#{statement_id}", headers: @headers
        return nil if @ctx.response.status == 404
        raise "GET /api/v1/employee/statements/#{statement_id} failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body
      end

      def statement_pdf_bytes(statement_id)
        @ctx.get "/api/v1/employee/statements/#{statement_id}/pdf", headers: @headers
        return nil if @ctx.response.status == 404
        raise "GET /api/v1/employee/statements/#{statement_id}/pdf failed: #{@ctx.response.status}" unless @ctx.response.successful?

        @ctx.response.body
      end

      def tax_forms_list
        @ctx.get "/api/v1/employee/tax_forms", headers: @headers
        raise "GET /api/v1/employee/tax_forms failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body
      end

      def tax_form_pdf_bytes(document_id)
        @ctx.get "/api/v1/employee/tax_forms/#{document_id}/pdf", headers: @headers
        return nil if @ctx.response.status == 404
        raise "GET /api/v1/employee/tax_forms/#{document_id}/pdf failed: #{@ctx.response.status}" unless @ctx.response.successful?

        @ctx.response.body
      end

      def profile
        @ctx.get "/api/v1/employee/profile", headers: @headers
        raise "GET /api/v1/employee/profile failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        raw = @ctx.response.parsed_body
        address = raw.fetch("address", {})
        {
          name: raw["legal_name"],
          email: raw["email"],
          phone: normalize_phone(raw["phone"]),
          address_line1: address["address_line1"],
          address_line2: address["address_line2"],
          city: address["city"],
          state: address["state"],
          zip: address["zip"],
          payment_method: raw["payment_method"]
        }
      end

      def extract_paycheck(statement_id:, list_year: nil)
        listed = list_year ? statements_list(year: list_year).fetch("statements") : nil
        list_entry = listed&.find { |row| row["id"].to_s == statement_id.to_s }
        detail = statement_detail(statement_id)
        if detail.nil?
          return {
            status: { visible: false, voided: nil, correction: nil }
          }
        end

        ytd_summary = detail.fetch("ytd", {})
        taxes = parse_taxes(detail.fetch("taxes", []), ytd_present: !ytd_summary["gross"].nil?)
        deductions = parse_deductions(detail.fetch("deductions", []))
        employer_contributions = parse_employer_contributions(detail.fetch("employer_contributions", []))
        earnings = detail.fetch("earnings", [])
        other_pay = parse_other_pay(detail.fetch("other_pay", []))

        regular_hours = sum_earning_hours(earnings, "regular")
        overtime_hours = sum_earning_hours(earnings, "overtime")
        pto_hours = sum_earning_hours(earnings, "pto")
        holiday_hours = sum_earning_hours(earnings, "holiday")

        payment = detail.fetch("payment", {})
        pay_period = detail.fetch("pay_period", {})
        non_taxable_current = other_pay.values.sum(0.to_d) { |row| row[:amount].to_d }.round(2)

        {
          list_present: list_entry.present?,
          source: detail["source"],
          source_label: detail["source_label"],
          gross_pay: money(detail["gross_pay"]),
          net_pay: money(detail["net_pay"]),
          non_taxable_pay: non_taxable_current,
          taxes: taxes[:amounts],
          tax_labels: taxes[:labels],
          tax_display_labels: taxes[:display_labels],
          deductions: deductions[:rows],
          employer_contributions: employer_contributions,
          other_pay: other_pay,
          hours: {
            regular: regular_hours,
            overtime: overtime_hours,
            pto: pto_hours,
            holiday: holiday_hours,
            combined: hours(detail["total_hours"])
          },
          ytd: {
            gross: money(ytd_summary["gross"]),
            income_tax: taxes[:ytd][:income_tax],
            additional_withholding: taxes[:ytd][:additional_withholding],
            total_income_tax: sum_present(taxes[:ytd][:income_tax], taxes[:ytd][:additional_withholding]),
            social_security: taxes[:ytd][:social_security],
            medicare_total: taxes[:ytd][:medicare_total],
            retirement_401k: deductions[:rows].dig(:retirement_401k, :ytd) || money(0),
            roth_401k: deductions[:rows].dig(:roth_401k, :ytd) || money(0),
            deductions: deductions[:ytd_total],
            net: money(ytd_summary["net"])
          },
          dates: {
            period_start: iso_date(pay_period["start_date"]),
            period_end: iso_date(pay_period["end_date"]),
            pay_date: iso_date(detail["check_date"] || pay_period["pay_date"]),
            period_pay_date: iso_date(pay_period["pay_date"])
          },
          payment: {
            method: payment["method"],
            # The employee app shows only the last 4 digits.
            check_number: nil,
            check_number_last4: normalize_check_number(payment["check_number_last4"]),
            status: payment["status"],
            # Only populate payment_label if the employee API actually emits a label field;
            # never synthesize copy from payment.method for parity assertions.
            payment_label: payment["label"] || detail["payment_method_label"]
          },
          status: {
            visible: true,
            voided: payment["status"] == "voided",
            correction: pay_period["run_purpose"] == "correction" || detail["corrected"] == true,
            run_purpose: pay_period["run_purpose"],
            corrected_flag: detail["corrected"]
          },
          note: detail["note"],
          earnings: earnings
        }
      end

      private

      def parse_taxes(rows, ytd_present: false)
        amounts = {
          income_tax: money(0),
          additional_withholding: money(0),
          social_security: money(0),
          medicare_base: nil,
          additional_medicare: nil,
          medicare_total: money(0)
        }
        ytd_has_values = ytd_present || rows.any? { |r| !r["ytd"].nil? }
        ytd = {
          income_tax: ytd_has_values ? money(0) : nil,
          additional_withholding: ytd_has_values ? money(0) : nil,
          social_security: ytd_has_values ? money(0) : nil,
          medicare_total: ytd_has_values ? money(0) : nil
        }
        labels = {}
        display_labels = {}
        medicare_row_amount = nil
        medicare_row_ytd = nil
        addl_med_ytd = nil

        rows.each do |row|
          kind = row["kind"].to_s
          label_down = row["label"].to_s.downcase

          if kind == "additional_medicare" || label_down.start_with?("additional medicare")
            amounts[:additional_medicare] = money(row["amount"])
            addl_med_ytd = money(row["ytd"])
            labels[:additional_medicare] = row["label"]
            display_labels[:additional_medicare] = row["display_label"]
          elsif kind == "additional_guam_income_tax" || label_down.include?("additional withholding") || label_down.include?("w-4 4c")
            amounts[:additional_withholding] = money(row["amount"])
            ytd[:additional_withholding] = money(row["ytd"])
            labels[:additional_withholding] = row["label"]
            display_labels[:additional_withholding] = row["display_label"]
          elsif kind == "guam_income_tax" || label_down.include?("income tax")
            amounts[:income_tax] = money(row["amount"])
            ytd[:income_tax] = money(row["ytd"])
            labels[:income_tax] = row["label"]
            display_labels[:income_tax] = row["display_label"]
          elsif kind == "social_security" || label_down.start_with?("social security")
            amounts[:social_security] = money(row["amount"])
            ytd[:social_security] = money(row["ytd"])
            labels[:social_security] = row["label"]
            display_labels[:social_security] = row["display_label"]
          elsif kind == "medicare" || label_down.start_with?("medicare")
            medicare_row_amount = money(row["amount"])
            medicare_row_ytd = money(row["ytd"])
            labels[:medicare] = row["label"]
            display_labels[:medicare] = row["display_label"]
          end
        end

        if amounts[:additional_medicare]
          amounts[:medicare_base] = medicare_row_amount || money(0)
          amounts[:medicare_total] = (amounts[:medicare_base] + amounts[:additional_medicare]).round(2)
          ytd[:medicare_total] = sum_present(medicare_row_ytd, addl_med_ytd) if ytd_has_values
        elsif medicare_row_amount
          amounts[:medicare_total] = medicare_row_amount
          ytd[:medicare_total] = medicare_row_ytd if ytd_has_values
        end

        amounts[:total_income_tax] = (amounts[:income_tax] + amounts[:additional_withholding]).round(2)
        amounts[:total_taxes] = (amounts[:total_income_tax] + amounts[:social_security] + amounts[:medicare_total]).round(2)
        { amounts: amounts, ytd: ytd, labels: labels, display_labels: display_labels }
      end

      def parse_deductions(rows)
        mapped = {}
        ytd_total = money(0)
        rows.each do |row|
          key = canonical_deduction_key(row["label"])
          amt = money(row["amount"])
          ytd_val = money(row["ytd"])
          mapped[key] = { label: row["label"], amount: amt, ytd: ytd_val }
          ytd_total = (ytd_total + ytd_val).round(2) if ytd_val
        end
        { rows: mapped, ytd_total: rows.any? { |r| !r["ytd"].nil? } ? ytd_total : money(0) }
      end

      def parse_employer_contributions(rows)
        Array(rows).each_with_object({}) do |row, acc|
          next unless row.is_a?(Hash)

          label = row["label"] || row["display_label"]
          key = canonical_employer_contribution_key(label)
          acc[key] = {
            label: label,
            amount: money(row["amount"]),
            ytd: money(row["ytd"])
          }
        end
      end

      def parse_other_pay(rows)
        rows.each_with_object({}) do |row, acc|
          acc[row["label"].to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "").to_sym] = {
            label: row["label"], amount: money(row["amount"]), ytd: money(row["ytd"])
          }
        end
      end

      def sum_earning_hours(earnings, kind)
        matched = earnings.select { |row| row["kind"] == kind && !row["hours"].nil? }
        return money(0) if matched.empty?

        matched.sum(0.to_d) { |row| hours(row["hours"]) }.round(2)
      end

      def sum_present(*values)
        present = values.compact
        return nil if present.empty?

        present.sum(0.to_d).round(2)
      end
    end
  end
end
