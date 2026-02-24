# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ReportsController < BaseController
        # GET /api/v1/admin/reports/dashboard
        # Dashboard stats and metrics
        def dashboard
          render json: {
            stats: {
              total_employees: Employee.where(company_id: current_company_id).count,
              active_employees: Employee.active.where(company_id: current_company_id).count,
              current_pay_period: current_pay_period_summary,
              ytd_totals: ytd_company_totals,
              recent_payrolls: recent_payroll_summary
            }
          }
        end

        # GET /api/v1/admin/reports/payroll_register
        # Detailed payroll for a pay period
        def payroll_register
          pay_period = PayPeriod.includes(payroll_items: :employee).find(params[:pay_period_id])

          unless pay_period.company_id == current_company_id
            return render json: { error: "Pay period not found" }, status: :not_found
          end

          render json: {
            report: {
              type: "payroll_register",
              pay_period: {
                id: pay_period.id,
                start_date: pay_period.start_date,
                end_date: pay_period.end_date,
                pay_date: pay_period.pay_date,
                status: pay_period.status
              },
              summary: {
                employee_count: pay_period.payroll_items.count,
                total_gross: pay_period.payroll_items.sum(:gross_pay),
                total_withholding: pay_period.payroll_items.sum(:withholding_tax),
                total_social_security: pay_period.payroll_items.sum(:social_security_tax),
                total_medicare: pay_period.payroll_items.sum(:medicare_tax),
                total_retirement: pay_period.payroll_items.sum(:retirement_payment),
                total_deductions: pay_period.payroll_items.sum(:total_deductions),
                total_net: pay_period.payroll_items.sum(:net_pay)
              },
              employees: pay_period.payroll_items.map { |item| payroll_item_detail(item) }
            }
          }
        end

        # GET /api/v1/admin/reports/employee_pay_history
        # Individual employee pay records
        def employee_pay_history
          employee = Employee.find(params[:employee_id])

          unless employee.company_id == current_company_id
            return render json: { error: "Employee not found" }, status: :not_found
          end

          items = employee.payroll_items
                         .includes(:pay_period)
                         .where(pay_periods: { status: "committed" })
                         .order("pay_periods.pay_date DESC")
                         .limit(params[:limit] || 12)

          render json: {
            report: {
              type: "employee_pay_history",
              employee: {
                id: employee.id,
                name: employee.full_name,
                employment_type: employee.employment_type,
                pay_rate: employee.pay_rate
              },
              history: items.map { |item| pay_history_item(item) },
              ytd: employee_ytd_summary(employee)
            }
          }
        end

        # GET /api/v1/admin/reports/tax_summary
        # Tax withholding summary (for quarterly filing)
        def tax_summary
          year = params[:year]&.to_i || Date.today.year
          quarter = params[:quarter]&.to_i

          # Get committed pay periods in range
          pay_periods = PayPeriod.committed
                                 .where(company_id: current_company_id)
                                 .for_year(year)

          if quarter
            start_month = ((quarter - 1) * 3) + 1
            end_month = start_month + 2
            start_date = Date.new(year, start_month, 1)
            end_date = Date.new(year, end_month, -1)
            pay_periods = pay_periods.where(pay_date: start_date..end_date)
          end

          items = PayrollItem.joins(:pay_period)
                            .where(pay_periods: { id: pay_periods.pluck(:id) })
          employee_ss_total = items.sum(:social_security_tax)
          employee_medicare_total = items.sum(:medicare_tax)
          employer_ss_total = items.sum(:employer_social_security_tax)
          employer_medicare_total = items.sum(:employer_medicare_tax)
          withholding_total = items.sum(:withholding_tax)

          render json: {
            report: {
              type: "tax_summary",
              period: {
                year: year,
                quarter: quarter,
                start_date: pay_periods.minimum("pay_periods.pay_date"),
                end_date: pay_periods.maximum("pay_periods.pay_date")
              },
              totals: {
                gross_wages: items.sum(:gross_pay),
                withholding_tax: withholding_total,
                social_security_employee: employee_ss_total,
                social_security_employer: employer_ss_total,
                medicare_employee: employee_medicare_total,
                medicare_employer: employer_medicare_total,
                total_employment_taxes: employee_ss_total + employer_ss_total + employee_medicare_total + employer_medicare_total + withholding_total
              },
              pay_periods_included: pay_periods.count,
              employee_count: items.distinct.count(:employee_id)
            }
          }
        end

        # GET /api/v1/admin/reports/ytd_summary
        # Year-to-date summary for all employees
        def ytd_summary
          year = params[:year]&.to_i || Date.today.year

          employees = Employee.where(company_id: current_company_id)
                             .includes(:employee_ytd_totals)
                             .order(:last_name, :first_name)

          render json: {
            report: {
              type: "ytd_summary",
              year: year,
              employees: employees.map { |emp| employee_ytd_row(emp, year) },
              company_totals: ytd_company_totals(year)
            }
          }
        end

        private

        def current_pay_period_summary
          pp = PayPeriod.where(company_id: current_company_id)
                       .where(status: %w[draft calculated approved])
                       .order(pay_date: :desc)
                       .first

          return nil unless pp

          {
            id: pp.id,
            period_description: pp.period_description,
            pay_date: pp.pay_date,
            status: pp.status,
            employee_count: pp.payroll_items.count,
            total_gross: pp.payroll_items.sum(:gross_pay),
            total_net: pp.payroll_items.sum(:net_pay)
          }
        end

        def ytd_company_totals(year = Date.today.year)
          items = PayrollItem.joins(:pay_period)
                            .where(pay_periods: {
                              company_id: current_company_id,
                              status: "committed",
                              pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31)
                            })

          {
            year: year,
            gross_pay: items.sum(:gross_pay),
            withholding_tax: items.sum(:withholding_tax),
            social_security_tax: items.sum(:social_security_tax),
            medicare_tax: items.sum(:medicare_tax),
            retirement: items.sum(:retirement_payment),
            net_pay: items.sum(:net_pay),
            payroll_count: items.select("DISTINCT pay_period_id").count
          }
        end

        def recent_payroll_summary
          PayPeriod.committed
                   .where(company_id: current_company_id)
                   .order(pay_date: :desc)
                   .limit(5)
                   .map do |pp|
            {
              id: pp.id,
              period_description: pp.period_description,
              pay_date: pp.pay_date,
              employee_count: pp.payroll_items.count,
              total_net: pp.payroll_items.sum(:net_pay)
            }
          end
        end

        def payroll_item_detail(item)
          {
            employee_id: item.employee_id,
            employee_name: item.employee.full_name,
            employment_type: item.employment_type,
            pay_rate: item.pay_rate,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            retirement_payment: item.retirement_payment,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            check_number: item.check_number
          }
        end

        def pay_history_item(item)
          {
            pay_period_id: item.pay_period_id,
            pay_date: item.pay_period.pay_date,
            period_description: item.pay_period.period_description,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            gross_pay: item.gross_pay,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            check_number: item.check_number
          }
        end

        def employee_ytd_summary(employee, year = Date.today.year)
          ytd = employee.ytd_totals_for(year)
          {
            year: year,
            gross_pay: ytd.gross_pay,
            withholding_tax: ytd.withholding_tax,
            social_security_tax: ytd.social_security_tax,
            medicare_tax: ytd.medicare_tax,
            retirement: ytd.retirement,
            net_pay: ytd.net_pay
          }
        end

        def employee_ytd_row(employee, year)
          ytd = employee.employee_ytd_totals.find_by(year: year)

          {
            employee_id: employee.id,
            name: employee.full_name,
            employment_type: employee.employment_type,
            status: employee.status,
            gross_pay: ytd&.gross_pay || 0,
            withholding_tax: ytd&.withholding_tax || 0,
            social_security_tax: ytd&.social_security_tax || 0,
            medicare_tax: ytd&.medicare_tax || 0,
            retirement: ytd&.retirement || 0,
            net_pay: ytd&.net_pay || 0
          }
        end
      end
    end
  end
end
