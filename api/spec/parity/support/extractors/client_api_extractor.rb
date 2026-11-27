# frozen_string_literal: true

module Parity
  module Extractors
    # Calls the real Client Portal HTTP endpoints (pay period detail, pay stubs,
    # employee pay history, YTD summary, and employee profile) and maps each to
    # the canonical parity hash.
    class ClientApiExtractor
      include Parity::CanonicalSchema

      def initialize(request_context:, headers:)
        @ctx = request_context
        @headers = headers
      end

      def pay_period_detail(pay_period_id)
        @ctx.get "/api/v1/client/pay_periods/#{pay_period_id}", headers: @headers
        return nil if @ctx.response.status == 404
        raise "GET /api/v1/client/pay_periods/#{pay_period_id} failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body.fetch("pay_period")
      end

      def pay_stubs_index(employee_id)
        @ctx.get "/api/v1/client/pay_stubs/employee/#{employee_id}", headers: @headers
        raise "GET /api/v1/client/pay_stubs/employee/#{employee_id} failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body
      end

      def pay_stub_pdf_bytes(payroll_item_id)
        @ctx.get "/api/v1/client/pay_stubs/#{payroll_item_id}/download", headers: @headers
        return nil if @ctx.response.status == 404
        raise "GET /api/v1/client/pay_stubs/#{payroll_item_id}/download failed: #{@ctx.response.status}" unless @ctx.response.successful?

        @ctx.response.body
      end

      def employee_pay_history(employee_id:, year:)
        @ctx.get "/api/v1/client/reports/employee_pay_history",
          params: { employee_id: employee_id, year: year }, headers: @headers
        raise "GET /api/v1/client/reports/employee_pay_history failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body.fetch("report")
      end

      def ytd_summary(year:)
        @ctx.get "/api/v1/client/reports/ytd_summary", params: { year: year }, headers: @headers
        raise "GET /api/v1/client/reports/ytd_summary failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

        @ctx.response.parsed_body.fetch("report")
      end

      # Returns raw profile fields as serialized by Client::EmployeesController,
      # plus ui_display_name matching ClientEmployeeOverview.tsx:56 (`${first_name} ${last_name}`).
      def profile(employee_id)
        @ctx.get "/api/v1/client/employees/#{employee_id}", headers: @headers
        raise "GET /api/v1/client/employees/#{employee_id} failed: #{@ctx.response.status} #{@ctx.response.body}" unless @ctx.response.successful?

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

      def extract_pay_period_item(pay_period_id:, employee_id:)
        period = pay_period_detail(pay_period_id)
        return { status: { visible: false } } if period.nil?

        item = period.fetch("payroll_items", []).find { |row| row["employee_id"].to_i == employee_id.to_i }
        return { status: { visible: false } } if item.nil?

        parse_pay_period_item(period, item)
      end

      def parse_pay_period_item(period, item)
        if item["details_error"].present?
          return {
            employee_name: item["employee_name"],
            gross_pay: money(item["gross_pay"]),
            net_pay: money(item["net_pay"]),
            hours: {
              regular: hours(item["hours_worked"]),
              overtime: hours(item["overtime_hours"]),
              combined: hours(item["total_hours"])
            },
            dates: {
              period_start: iso_date(period["start_date"]),
              period_end: iso_date(period["end_date"]),
              pay_date: iso_date(item["effective_check_date"] || period["pay_date"])
            },
            status: {
              visible: true,
              details_available: false,
              details_error: item["details_error"],
              pay_stub_available: item["pay_stub_available"],
              correction: period["run_purpose"] == "correction",
              run_purpose: period["run_purpose"]
            }
          }
        end

        income_tax = money(item["withholding_tax"])
        addl_wh = money(item["additional_withholding"])
        ss_tax = money(item["social_security_tax"])
        med_total = money(item["medicare_tax"])
        addl_med = money(item["additional_medicare_tax"])
        med_base = (med_total - addl_med).round(2)

        deductions = {}
        ret = money(item["retirement_payment"])
        if ret&.nonzero?
          deductions[:retirement_401k] = { label: nil, amount: ret, ytd: nil }
        end
        roth = money(item["roth_retirement_payment"])
        if roth&.nonzero?
          deductions[:roth_401k] = { label: nil, amount: roth, ytd: nil }
        end

        {
          employee_name: item["employee_name"],
          gross_pay: money(item["gross_pay"]),
          net_pay: money(item["net_pay"]),
          non_taxable_pay: money(item["non_taxable_additions_total"]) || money(0),
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
          hours: {
            regular: hours(item["hours_worked"]),
            overtime: hours(item["overtime_hours"]),
            combined: hours(item["total_hours"])
          },
          dates: {
            period_start: iso_date(period["start_date"]),
            period_end: iso_date(period["end_date"]),
            pay_date: iso_date(item["effective_check_date"] || period["pay_date"])
          },
          status: {
            visible: true,
            details_available: true,
            pay_stub_available: item["pay_stub_available"],
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
    end
  end
end
