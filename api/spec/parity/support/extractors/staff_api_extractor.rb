# frozen_string_literal: true

module Parity
  module Extractors
    # Calls the real Cornerstone Staff (Admin) HTTP endpoints and maps the JSON
    # responses to the canonical parity hash.
    class StaffApiExtractor
      include Parity::CanonicalSchema

      def initialize(request_context:, headers:)
        @ctx = request_context
        @headers = headers
      end

      def pay_period_detail(pay_period_id)
        @ctx.get "/api/v1/admin/pay_periods/#{pay_period_id}", headers: @headers
        raise "GET /api/v1/admin/pay_periods/#{pay_period_id} failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body.fetch("pay_period")
      end

      def employee_pay_history(employee_id:, year:)
        @ctx.get "/api/v1/admin/reports/employee_pay_history",
          params: { employee_id: employee_id, year: year }, headers: @headers
        raise "GET /api/v1/admin/reports/employee_pay_history failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body.fetch("report")
      end

      def ytd_summary(year:)
        ytd_summary_for(year: year)
      end

      # [status, parsed body] of a staff POST, for endpoints that refuse.
      def post(path, params = {})
        @ctx.post path, params: params, headers: @headers, as: :json
        [ @ctx.response.status, @ctx.response.parsed_body ]
      end

      # [status, parsed JSON or nil] of a staff GET that may refuse.
      def get(path, params = {})
        @ctx.get path, params: params, headers: @headers
        body = @ctx.response.media_type == "application/json" ? @ctx.response.parsed_body : nil
        [ @ctx.response.status, body ]
      end

      def ytd_summary_pdf_text(params)
        @ctx.get "/api/v1/admin/reports/ytd_summary_pdf", params: params, headers: @headers
        raise "GET /api/v1/admin/reports/ytd_summary_pdf failed: #{@ctx.response.status}" unless @ctx.response.successful?

        PDF::Reader.new(StringIO.new(@ctx.response.body)).pages.map(&:text).join(" ").squish
      end

      def ytd_summary_for(params)
        @ctx.get "/api/v1/admin/reports/ytd_summary", params: params, headers: @headers
        raise "GET /api/v1/admin/reports/ytd_summary failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body.fetch("report")
      end

      def w2_gu(year:)
        @ctx.get "/api/v1/admin/reports/w2_gu", params: { year: year }, headers: @headers
        raise "GET /api/v1/admin/reports/w2_gu failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body.fetch("report")
      end

      def check_pdf_bytes(payroll_item_id)
        @ctx.get "/api/v1/admin/payroll_items/#{payroll_item_id}/check", headers: @headers
        raise "GET /api/v1/admin/payroll_items/#{payroll_item_id}/check failed: #{@ctx.response.status}" unless @ctx.response.successful?

        @ctx.response.body
      end

      # Returns raw profile fields as serialized by Admin::EmployeesController,
      # plus ui_display_name matching EmployeeList.tsx:630 (`${first_name} ${last_name}`).
      def profile(employee_id)
        @ctx.get "/api/v1/admin/employees/#{employee_id}", headers: @headers
        raise "GET /api/v1/admin/employees/#{employee_id} failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        raw = @ctx.response.parsed_body.fetch("data")
        {
          first_name: raw["first_name"],
          middle_name: raw["middle_name"],
          last_name: raw["last_name"],
          name_suffix: raw["name_suffix"],
          legal_name: raw["legal_name"],
          ui_display_name: [ raw["first_name"], raw["last_name"] ].compact_blank.join(" "),
          email: raw["email"],
          phone: normalize_phone(raw["phone"]),
          address_line1: raw["address_line1"],
          address_line2: raw["address_line2"],
          city: raw["city"],
          state: raw["state"],
          zip: raw["zip"],
          status: raw["status"]
        }
      end

      def extract_pay_run_item(pay_period_id:, employee_id:)
        period = pay_period_detail(pay_period_id)
        item = period.fetch("payroll_items", []).find { |row| row["employee_id"].to_i == employee_id.to_i }
        return { status: { visible: false } } if item.nil?

        income_tax = money(item["withholding_tax"])
        addl_wh = money(item["additional_withholding"])
        ss_tax = money(item["social_security_tax"])
        med_total = money(item["medicare_tax"])
        addl_med = money(item["additional_medicare_tax"])
        med_base = (med_total - addl_med).round(2)

        reg = hours(item["hours_worked"]) || money(0)
        ot = hours(item["overtime_hours"]) || money(0)
        hol = hours(item["holiday_hours"]) || money(0)
        pto = hours(item["pto_hours"]) || money(0)

        deductions = {}
        ret = money(item["retirement_payment"])
        if ret&.nonzero?
          deductions[:retirement_401k] = { label: nil, amount: ret, ytd: nil }
        end
        roth = money(item["roth_retirement_payment"])
        if roth&.nonzero?
          deductions[:roth_401k] = { label: nil, amount: roth, ytd: nil }
        end

        employer_contributions = {}
        er_match = money(item["employer_retirement_match"])
        if er_match&.nonzero?
          employer_contributions[:employer_401k_match] = {
            label: "401(k) Match",
            amount: er_match,
            ytd: nil
          }
        end
        er_roth_match = money(item["employer_roth_retirement_match"])
        if er_roth_match&.nonzero?
          employer_contributions[:employer_roth_401k_match] = {
            label: "Roth 401(k) Match",
            amount: er_roth_match,
            ytd: nil
          }
        end

        non_taxable_total = (
          (money(item["non_taxable_pay"]) || money(0)) +
          (money(item.dig("payroll_adjustment_totals", "non_taxable_additions")) || money(0))
        ).round(2)

        {
          employee_name: item["employee_name"],
          gross_pay: money(item["gross_pay"]),
          net_pay: money(item["net_pay"]),
          non_taxable_pay: non_taxable_total,
          taxes: {
            income_tax: income_tax,
            additional_withholding: addl_wh,
            total_income_tax: (income_tax + addl_wh).round(2),
            social_security: ss_tax,
            medicare_base: med_base,
            additional_medicare: addl_med,
            medicare_total: med_total,
            total_taxes: (income_tax + addl_wh + ss_tax + med_total).round(2)
          },
          deductions: deductions,
          employer_contributions: employer_contributions,
          hours: {
            regular: reg,
            overtime: ot,
            holiday: hol,
            pto: pto,
            combined: (reg + ot + hol + pto).round(2)
          },
          ytd: {
            gross: money(item["ytd_gross"]),
            net: money(item["ytd_net"])
          },
          dates: {
            period_start: iso_date(period["start_date"]),
            period_end: iso_date(period["end_date"]),
            pay_date: iso_date(period["pay_date"])
          },
          payment: {
            method: item["effective_payment_delivery_method"],
            **check_number_fields(item["check_number"]),
            check_status: item["check_status"]
          },
          status: {
            visible: true,
            payroll_included: item["payroll_included"] != false,
            voided: item["voided"] == true,
            correction: period["run_purpose"] == "correction",
            run_purpose: period["run_purpose"]
          }
        }
      end

      def extract_pay_history_item(employee_id:, year:, payroll_item_id:)
        report = employee_pay_history(employee_id: employee_id, year: year)
        row = report.fetch("history", []).find { |entry| entry["payroll_item_id"].to_i == payroll_item_id.to_i }
        return { status: { visible: false } } if row.nil?

        # Pay history splits income tax and W-4 4c as the stub does (L4), and
        # carries their total; read all three from the view.
        income_tax = money(row["withholding_tax"])
        addl_wh = money(row["additional_withholding"])
        total_income_tax = money(row["total_income_tax_withheld"])
        ss_tax = money(row["social_security_tax"])
        med_total = money(row["medicare_tax"])
        evidence = row.fetch("payment_evidence", {})

        {
          employee_name: report.dig("employee", "name"),
          gross_pay: money(row["gross_pay"]),
          net_pay: money(row["net_pay"]),
          taxes: {
            income_tax: income_tax,
            additional_withholding: addl_wh,
            total_income_tax: total_income_tax,
            social_security: ss_tax,
            medicare_total: med_total,
            total_taxes: (total_income_tax + ss_tax + med_total).round(2)
          },
          hours: {
            regular: hours(row["hours_worked"]),
            overtime: hours(row["overtime_hours"]),
            pto: hours(row["pto_hours"]),
            holiday: hours(row["holiday_hours"]),
            combined: hours(row["total_hours"])
          },
          dates: {
            period_start: iso_date(row["period_start"]),
            period_end: iso_date(row["period_end"]),
            pay_date: iso_date(row["pay_date"])
          },
          payment: {
            method: row["payment_delivery_method"],
            **check_number_fields(row["check_number"]),
            status: evidence["status"],
            payment_label: row["payment_method_label"]
          },
          status: {
            visible: true,
            voided: evidence["status"] == "voided",
            correction: row["hours_basis"] == "signed_payroll_correction"
          }
        }
      end

      def extract_ytd_summary_row(employee_id:, year:)
        report = ytd_summary(year: year)
        row = report.fetch("employees", []).find { |entry| entry["employee_id"].to_i == employee_id.to_i }
        return nil if row.nil?

        {
          employee_name: row["name"],
          ytd: {
            gross: money(row["gross_pay"]),
            total_income_tax: money(row["withholding_tax"]),
            social_security: money(row["social_security_tax"]),
            medicare_total: money(row["medicare_tax"]),
            retirement_401k: money(row["retirement"]),
            roth_401k: money(row["roth_retirement"]),
            net: money(row["net_pay"])
          },
          hours: {
            total_hours_field: hours(row["total_hours"]),
            overtime: hours(row["total_overtime_hours"]),
            combined: hours(row["combined_hours"])
          }
        }
      end

      def extract_w2_employee_row(employee_id:, year:)
        report = w2_gu(year: year)
        row = report.fetch("employees", []).find { |entry| entry["employee_id"].to_i == employee_id.to_i }
        return nil if row.nil?

        box12_d = Array(row["box12"]).select { |entry| entry["code"] == "D" }.sum(0.to_d) { |entry| money(entry["amount"]) }.round(2)
        box12_aa = Array(row["box12"]).select { |entry| entry["code"] == "AA" }.sum(0.to_d) { |entry| money(entry["amount"]) }.round(2)
        {
          employee_name: row["employee_name"],
          employee_name_suffix: row["employee_name_suffix"] || row["name_suffix"],
          box1_wages: money(row["box1_wages_tips_other_comp"]),
          box2_income_tax: money(row["box2_federal_income_tax_withheld"]),
          box3_ss_wages: money(row["box3_social_security_wages"]),
          box4_ss_tax: money(row["box4_social_security_tax_withheld"]),
          box5_medicare_wages: money(row["box5_medicare_wages_tips"]),
          box6_medicare_tax: money(row["box6_medicare_tax_withheld"]),
          box12_code_d: box12_d,
          box12_code_aa: box12_aa
        }
      end
    end
  end
end
