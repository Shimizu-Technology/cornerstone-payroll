# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollItemsController < BaseController
        before_action :set_pay_period
        before_action :set_payroll_item, only: [ :show, :update, :destroy, :recalculate ]

        # GET /api/v1/admin/pay_periods/:pay_period_id/payroll_items
        def index
          @payroll_items = @pay_period.payroll_items.includes(:payroll_item_field_entries, :employee)
          reportable_items = @payroll_items.not_voided

          render json: {
            payroll_items: @payroll_items.map { |item| payroll_item_json(item) },
            summary: {
              total_gross: reportable_items.sum(:gross_pay),
              total_withholding: reportable_items.sum(:withholding_tax),
              total_social_security: reportable_items.sum(:social_security_tax),
              total_medicare: reportable_items.sum(:medicare_tax),
              total_deductions: reportable_items.sum(:total_deductions),
              total_net: reportable_items.sum(:net_pay),
              # Employer obligations (what Cornerstone deposits with Guam DRT)
              total_employer_social_security: reportable_items.sum(:employer_social_security_tax),
              total_employer_medicare: reportable_items.sum(:employer_medicare_tax),
              total_employer_taxes: reportable_items.sum(:employer_social_security_tax) + reportable_items.sum(:employer_medicare_tax),
              employee_count: reportable_items.count
            }
          }
        end

        # GET /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id
        def show
          render json: { payroll_item: payroll_item_json(@payroll_item, detailed: true) }
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/payroll_items
        # Add an employee to this pay period
        def create
          unless @pay_period.can_edit?
            return render json: { error: "Cannot modify a committed pay period" }, status: :unprocessable_entity
          end

          employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          unless employee
            return render json: { error: "Employee not found" }, status: :not_found
          end

          attrs = payroll_item_params
          wage_rate_hours = attrs.delete(:wage_rate_hours)

          @payroll_item = @pay_period.payroll_items.build(attrs)
          @payroll_item.employee = employee
          @payroll_item.employment_type ||= employee.employment_type
          sync_pay_rate_from_employee(@payroll_item, employee)
          @payroll_item.apply_default_payroll_adjustments_if_unset!(employee)
          apply_wage_rate_hours(@payroll_item, wage_rate_hours, employee) if wage_rate_hours.present?

          if save_payroll_item_and_clear_exclusion(@payroll_item, employee)
            @payroll_item.calculate! if params[:auto_calculate]
            render json: { payroll_item: payroll_item_json(@payroll_item) }, status: :created
          else
            render json: { errors: @payroll_item.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end

        # PATCH/PUT /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id
        def update
          unless @pay_period.can_edit?
            return render json: { error: "Cannot modify a committed pay period" }, status: :unprocessable_entity
          end

          attrs = payroll_item_params
          wage_rate_hours = attrs.delete(:wage_rate_hours)
          apply_wage_rate_hours(@payroll_item, wage_rate_hours, @payroll_item.employee) if wage_rate_hours.present?
          sync_pay_rate_from_employee(@payroll_item, @payroll_item.employee) unless wage_rate_hours.present?
          @payroll_item.mark_payroll_adjustments_overridden! if params.dig(:payroll_item, :payroll_adjustments)

          if @payroll_item.update(attrs)
            @payroll_item.calculate! if params[:auto_calculate]
            render json: { payroll_item: payroll_item_json(@payroll_item) }
          else
            render json: { errors: @payroll_item.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotFound => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end

        # DELETE /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id
        def destroy
          unless @pay_period.can_edit?
            return render json: { error: "Cannot modify a committed pay period" }, status: :unprocessable_entity
          end

          ActiveRecord::Base.transaction do
            PayPeriodExcludedEmployee.create_or_find_by!(
              pay_period: @pay_period,
              employee: @payroll_item.employee
            ) do |exclusion|
              exclusion.excluded_by = current_user
              exclusion.reason = "Removed from pay period"
            end
            @payroll_item.destroy!
          end

          head :no_content
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/payroll_items/:id/recalculate
        def recalculate
          unless @pay_period.can_edit?
            return render json: { error: "Cannot modify a committed pay period" }, status: :unprocessable_entity
          end

          sync_pay_rate_from_employee(@payroll_item, @payroll_item.employee)
          @payroll_item.apply_default_payroll_adjustments_if_unset!(@payroll_item.employee)
          @payroll_item.calculate!
          render json: { payroll_item: payroll_item_json(@payroll_item) }
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.find(params[:pay_period_id])

          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found
          end
        end

        def set_payroll_item
          @payroll_item = @pay_period.payroll_items.includes(:payroll_item_field_entries).find(params[:id])
        end

        def payroll_item_params
          permitted = params.require(:payroll_item).permit(
            :employee_id, :employment_type, :pay_rate,
            :hours_worked, :overtime_hours, :holiday_hours, :pto_hours,
            :bonus, :additional_withholding, :additional_withholding_override, :withholding_tax_adjustment, :withholding_tax_override, :check_number,
            :salary_override, :non_taxable_pay, :reported_tips, :tips_paid_out,
            :check_date, :check_memo,
            wage_rate_hours: [
              :employee_wage_rate_id, :label, :rate, :regular_hours,
              :overtime_hours, :holiday_hours, :pto_hours, :is_primary, :active
            ],
            custom_earnings: [ :label, :amount ],
            custom_deductions: [ :label, :amount ],
            payroll_adjustments: [ :label, :amount, :treatment, :notes, :active ],
            payroll_field_entries: [
              :id, :payroll_field_definition_id, :label, :kind, :tax_treatment,
              :category, :amount, :source, :employee_paid, :employer_paid,
              :active, :notes
            ]
          )

          attrs = permitted.except(:wage_rate_hours, :custom_earnings, :custom_deductions, :payroll_adjustments, :payroll_field_entries).to_h.symbolize_keys
          attrs[:wage_rate_hours] = permitted[:wage_rate_hours] if permitted[:wage_rate_hours].present?
          attrs[:custom_earnings] = permitted[:custom_earnings]&.map(&:to_h) || [] if params.dig(:payroll_item, :custom_earnings)
          attrs[:custom_deductions] = PayrollItem.normalize_custom_deduction_entries(permitted[:custom_deductions]) if params.dig(:payroll_item, :custom_deductions)
          attrs[:payroll_adjustments] = PayrollItem.normalize_payroll_adjustments(permitted[:payroll_adjustments]) if params.dig(:payroll_item, :payroll_adjustments)
          if params.dig(:payroll_item, :payroll_field_entries).present?
            normalized_entries = normalize_payroll_field_entries(permitted[:payroll_field_entries])
            attrs[:payroll_item_field_entries_attributes] = normalized_entries if normalized_entries.present?
          end
          attrs
        end

        def normalize_payroll_field_entries(entries)
          Array(entries).filter_map do |entry|
            data = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h
            amount = BigDecimal(data["amount"].to_s)
            label = data["label"].to_s.strip
            next if label.blank? || amount.negative? || !amount.finite?

            field = nil
            if data["payroll_field_definition_id"].present?
              field = PayrollFieldDefinition.find_by(id: data["payroll_field_definition_id"], company_id: current_company_id)
              raise ActiveRecord::RecordNotFound, "Payroll field definition no longer exists for this company" unless field
            end

            existing_entry = nil
            if data["id"].present?
              raise ActiveRecord::RecordNotFound, "Payroll field entry IDs cannot be submitted when creating a payroll item" unless @payroll_item

              existing_entry = @payroll_item.payroll_item_field_entries.find_by(id: data["id"])
              raise ActiveRecord::RecordNotFound, "Payroll field entry no longer exists for this payroll item" unless existing_entry
            end

            source = normalized_payroll_field_entry_source(data["source"])
            payload = {
              id: data["id"],
              payroll_field_definition_id: field&.id,
              label: label,
              kind: data["kind"].presence || field&.kind,
              tax_treatment: data["tax_treatment"].presence || field&.tax_treatment,
              category: data["category"].presence || field&.category || "other",
              amount: amount.round(2),
              source: source,
              employee_paid: ActiveModel::Type::Boolean.new.cast(data.key?("employee_paid") ? data["employee_paid"] : field&.employee_paid?),
              employer_paid: ActiveModel::Type::Boolean.new.cast(data.key?("employer_paid") ? data["employer_paid"] : field&.employer_paid?),
              active: data.key?("active") ? ActiveModel::Type::Boolean.new.cast(data["active"]) : true,
              notes: data["notes"].to_s.strip.presence
            }
            payload = payload.compact.merge(notes: payload[:notes])
            if source == "manual" && existing_entry&.metadata.is_a?(Hash)
              payload[:metadata] = amount == existing_entry.amount ? existing_entry.metadata : existing_entry.metadata.except("uncapped_amount")
            end
            payload
          rescue ArgumentError, FloatDomainError
            nil
          end
        end

        def normalized_payroll_field_entry_source(value)
          source = value.to_s
          PayrollItemFieldEntry::SOURCES.include?(source) ? source : "manual"
        end

        def save_payroll_item_and_clear_exclusion(payroll_item, employee)
          return false unless payroll_item.valid?

          ActiveRecord::Base.transaction do
            payroll_item.save!
            @pay_period.pay_period_excluded_employees.where(employee_id: employee.id).find_each(&:destroy!)
          end

          true
        end

        def payroll_field_entry_json(entry)
          {
            id: entry.id,
            payroll_item_id: entry.payroll_item_id,
            payroll_field_definition_id: entry.payroll_field_definition_id,
            label: entry.label,
            kind: entry.kind,
            tax_treatment: entry.tax_treatment,
            category: entry.category,
            amount: entry.amount.to_f,
            source: entry.source,
            employee_paid: entry.employee_paid,
            employer_paid: entry.employer_paid,
            active: entry.active,
            notes: entry.notes
          }
        end

        def payroll_item_json(item, detailed: false)
          json = {
            id: item.id,
            employee_id: item.employee_id,
            employee_name: item.employee_full_name,
            employment_type: item.employment_type,
            pay_rate: item.pay_rate,
            salary_override: item.salary_override,
            non_taxable_pay: item.non_taxable_pay,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            holiday_hours: item.holiday_hours,
            pto_hours: item.pto_hours,
            total_hours: item.total_hours,
            bonus: item.bonus,
            reported_tips: item.reported_tips,
            tips_paid_out: item.tips_paid_out,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            retirement_payment: item.retirement_payment,
            additional_withholding: item.additional_withholding,
            additional_withholding_override: item.additional_withholding_override,
            withholding_tax_adjustment: item.withholding_tax_adjustment,
            withholding_tax_override: item.withholding_tax_override,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            employer_social_security_tax: item.employer_social_security_tax,
            employer_medicare_tax: item.employer_medicare_tax,
            employer_retirement_match: item.employer_retirement_match,
            employer_roth_retirement_match: item.employer_roth_retirement_match,
            roth_retirement_payment: item.roth_retirement_payment,
            loan_payment: item.loan_payment,
            insurance_payment: item.insurance_payment,
            check_number: item.check_number,
            check_printed_at: item.check_printed_at,
            check_date: item.check_date,
            check_memo: item.check_memo,
            custom_earnings: item.custom_earnings || [],
            custom_deductions: item.custom_deductions || [],
            payroll_adjustments: item.payroll_adjustments || [],
            payroll_field_entries: item.payroll_item_field_entries.map { |entry| payroll_field_entry_json(entry) },
            ytd_gross: item.ytd_gross,
            ytd_net: item.ytd_net,
            wage_rate_hours: item.wage_rate_hours
          }

          if detailed
            # Include full YTD breakdown
            json[:ytd] = {
              gross: item.ytd_gross,
              net: item.ytd_net,
              withholding_tax: item.ytd_withholding_tax,
              social_security_tax: item.ytd_social_security_tax,
              medicare_tax: item.ytd_medicare_tax,
              retirement: item.ytd_retirement
            }
          end

          json
        end

        def apply_wage_rate_hours(payroll_item, wage_rate_hours, employee)
          payroll_item.wage_rate_hours = wage_rate_hours
          entries = payroll_item.wage_rate_hours
          payroll_item.hours_worked = entries.sum { |entry| entry["regular_hours"].to_f }
          payroll_item.overtime_hours = entries.sum { |entry| entry["overtime_hours"].to_f }
          payroll_item.holiday_hours = entries.sum { |entry| entry["holiday_hours"].to_f }
          payroll_item.pto_hours = entries.sum { |entry| entry["pto_hours"].to_f }

          primary_entry = entries.find { |entry| entry["is_primary"] } || entries.first
          payroll_item.pay_rate = primary_entry ? primary_entry["rate"].to_f : employee.pay_rate
        end

        def sync_pay_rate_from_employee(payroll_item, employee)
          return if payroll_item.wage_rate_hours.present?

          payroll_item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
        end
      end
    end
  end
end
