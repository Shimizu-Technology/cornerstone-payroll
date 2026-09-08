# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeLoansController < BaseController
        before_action :set_loan, only: [ :show, :update, :destroy, :record_payment, :record_addition, :mark_paid_off, :suspend, :reactivate ]

        # GET /api/v1/admin/employee_loans
        def index
          loans = EmployeeLoan.where(company_id: current_company_id)
            .joins(:employee)
            .includes(:employee, :deduction_type, :created_by, loan_transactions: :recorded_by)

          loans = loans.where(employee_id: params[:employee_id]) if params[:employee_id].present?
          loans = loans.where(status: params[:status]) if params[:status].present?

          loans = loans.order("employees.last_name ASC, employees.first_name ASC, employee_loans.name ASC")

          schedules = loan_schedule_options
          render json: {
            loans: loans.map { |l| loan_payload(l) },
            loan_schedules: schedules,
            setup_gaps: schedules.reject { |schedule| schedule[:tracked] }
          }
        end

        # GET /api/v1/admin/employee_loans/:id
        def show
          render json: { loan: loan_payload(@loan, include_transactions: true) }
        end

        # POST /api/v1/admin/employee_loans
        def create
          raw_attributes = loan_params.to_h.symbolize_keys
          setup_mode = raw_attributes.delete(:balance_setup_mode).presence || "new_loan"
          schedule_kind = raw_attributes.delete(:schedule_kind)
          schedule_id = raw_attributes.delete(:schedule_id)
          attributes = scoped_loan_attributes(raw_attributes)
          return if performed?

          employee = Employee.find_by(id: attributes[:employee_id], company_id: current_company_id)
          unless employee
            return render json: { error: "Employee not found" }, status: :not_found
          end

          schedule = resolve_schedule(employee, kind: schedule_kind, id: schedule_id)
          attributes[:deduction_type_id] = schedule.deduction_type_id if schedule.is_a?(EmployeeDeduction)
          configure_opening_balance!(attributes, setup_mode: setup_mode)

          loan = EmployeeLoan.new(attributes)
          loan.company_id = current_company_id
          loan.employee = employee
          loan.created_by = current_user

          ActiveRecord::Base.transaction do
            loan.save!

            loan.loan_transactions.create!(
              transaction_type: "addition",
              amount: loan.opening_balance,
              balance_before: 0,
              balance_after: loan.opening_balance,
              transaction_date: loan.balance_as_of,
              notes: setup_mode == "existing_balance" ? "Verified opening balance" : "Initial loan",
              source: "opening_balance",
              recorded_by: current_user
            )
            schedule.update!(employee_loan: loan) if schedule.is_a?(EmployeePayrollField)
          end

          render json: { loan: loan_payload(loan) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/employee_loans/:id
        def update
          attributes = scoped_loan_attributes(loan_update_params)
          return if performed?

          @loan.with_lock do
            if @loan.update(attributes)
              render json: { loan: loan_payload(@loan) }
            else
              render json: { errors: @loan.errors.full_messages }, status: :unprocessable_entity
            end
          end
        end

        # DELETE /api/v1/admin/employee_loans/:id
        def destroy
          @loan.with_lock do
            if @loan.loan_transactions.payments.any?
              return render json: { error: "Cannot delete a loan with payment history" }, status: :unprocessable_entity
            end

            @loan.destroy!
          end
          render json: { message: "Loan deleted" }
        end

        # POST /api/v1/admin/employee_loans/:id/record_payment
        def record_payment
          amount = BigDecimal(params[:amount].to_s)
          actual = @loan.record_payment!(
            amount: amount,
            date: params[:date].present? ? Date.parse(params[:date]) : nil,
            notes: params[:notes],
            recorded_by: current_user
          )
          render json: { loan: loan_payload(@loan.reload, include_transactions: true), amount_applied: actual }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/employee_loans/:id/record_addition
        def record_addition
          amount = BigDecimal(params[:amount].to_s)
          @loan.record_addition!(
            amount: amount,
            date: params[:date].present? ? Date.parse(params[:date]) : nil,
            notes: params[:notes],
            recorded_by: current_user
          )
          render json: { loan: loan_payload(@loan.reload, include_transactions: true) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/employee_loans/:id/mark_paid_off
        def mark_paid_off
          @loan.mark_paid_off!(
            date: params[:date].present? ? Date.parse(params[:date]) : nil,
            notes: params[:notes],
            recorded_by: current_user
          )
          render json: { loan: loan_payload(@loan.reload, include_transactions: true) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/employee_loans/:id/suspend
        def suspend
          @loan.suspend!(notes: params[:notes])
          render json: { loan: loan_payload(@loan.reload, include_transactions: true) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/employee_loans/:id/reactivate
        def reactivate
          @loan.reactivate!(notes: params[:notes])
          render json: { loan: loan_payload(@loan.reload, include_transactions: true) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_loan
          @loan = EmployeeLoan.find_by(id: params[:id], company_id: current_company_id)
          return if @loan

          render json: { error: "Loan not found" }, status: :not_found
        end

        def loan_params
          params.require(:employee_loan).permit(
            :employee_id, :name, :original_amount, :payment_amount,
            :start_date, :deduction_type_id, :notes,
            :opening_balance, :balance_as_of, :balance_source,
            :principal_amount_known, :balance_setup_mode, :schedule_kind, :schedule_id
          )
        end

        def loan_update_params
          params.require(:employee_loan).permit(
            :name, :payment_amount, :notes, :deduction_type_id
          )
        end

        def scoped_loan_attributes(raw_params)
          attributes = raw_params.to_h.symbolize_keys
          return attributes unless attributes[:deduction_type_id].present?

          deduction_type = DeductionType.find_by(
            id: attributes[:deduction_type_id],
            company_id: current_company_id
          )
          unless deduction_type
            render json: { error: "Deduction type not found" }, status: :not_found
            return {}
          end

          attributes[:deduction_type_id] = deduction_type.id
          attributes
        end

        def configure_opening_balance!(attributes, setup_mode:)
          unless setup_mode.in?(%w[new_loan existing_balance])
            raise ArgumentError, "Balance setup mode is invalid"
          end

          if setup_mode == "existing_balance"
            opening_balance = BigDecimal(attributes[:opening_balance].to_s, exception: false)
            raise ArgumentError, "Confirmed opening balance must be greater than zero" unless opening_balance&.positive?
            raise ArgumentError, "Balance as-of date is required" if attributes[:balance_as_of].blank?
            unless attributes[:balance_source].to_s.in?(EmployeeLoan::BALANCE_SOURCES - [ "new_loan" ])
              raise ArgumentError, "Choose where the opening balance was verified"
            end

            principal_known = ActiveModel::Type::Boolean.new.cast(attributes[:principal_amount_known]) == true
            attributes[:opening_balance] = opening_balance
            attributes[:current_balance] = opening_balance
            if principal_known
              original_amount = BigDecimal(attributes[:original_amount].to_s, exception: false)
              raise ArgumentError, "Original principal must be greater than zero" unless original_amount&.positive?

              attributes[:original_amount] = original_amount
            else
              # Keep the legacy non-null column usable without presenting the confirmed
              # balance as a known original principal in the product.
              attributes[:original_amount] = opening_balance
            end
            attributes[:principal_amount_known] = principal_known
          else
            original_amount = BigDecimal(attributes[:original_amount].to_s, exception: false)
            raise ArgumentError, "Original amount must be greater than zero" unless original_amount&.positive?

            attributes[:opening_balance] = original_amount
            attributes[:current_balance] = original_amount
            attributes[:balance_as_of] = attributes[:start_date].presence || Date.current
            attributes[:balance_source] = "new_loan"
            attributes[:principal_amount_known] = true
          end
        rescue ArgumentError => e
          raise e if e.message.match?(/Balance|Confirmed|Original|Choose/)

          raise ArgumentError, "Enter a valid opening balance"
        end

        def resolve_schedule(employee, kind:, id:)
          return if kind.blank? && id.blank?

          case kind
          when "employee_deduction"
            schedule = employee.employee_deductions.active.joins(:deduction_type)
              .where(deduction_types: { company_id: current_company_id, sub_category: "loan", active: true })
              .find_by(id: id) || raise(ArgumentError, "Loan deduction schedule not found")
            if employee.employee_loans.active.exists?(deduction_type_id: schedule.deduction_type_id)
              raise ArgumentError, "This deduction schedule already has an active loan balance"
            end
            schedule
          when "payroll_field"
            schedule = employee.employee_payroll_fields.active.joins(:payroll_field_definition)
              .where(payroll_field_definitions: { company_id: current_company_id, kind: "deduction", category: "loan", active: true })
              .find_by(id: id) || raise(ArgumentError, "Loan payroll field schedule not found")
            if schedule.employee_loan&.active?
              raise ArgumentError, "This payroll field already has an active loan balance"
            end
            schedule
          else
            raise ArgumentError, "Loan deduction schedule is invalid"
          end
        end

        def loan_schedule_options
          active_loans = EmployeeLoan.where(company_id: current_company_id, status: "active").to_a
          tracked_deductions = active_loans.filter_map do |loan|
            [ loan.employee_id, loan.deduction_type_id ] if loan.deduction_type_id.present?
          end.to_set

          deduction_schedules = EmployeeDeduction.active
            .joins(:employee, :deduction_type)
            .where(employees: { company_id: current_company_id })
            .where(deduction_types: { company_id: current_company_id, sub_category: "loan", active: true })
            .includes(:employee, :deduction_type)
            .map do |deduction|
              {
                kind: "employee_deduction",
                id: deduction.id,
                employee_id: deduction.employee_id,
                employee_name: deduction.employee.full_name,
                label: deduction.deduction_type.name,
                amount: deduction.amount,
                percentage: deduction.is_percentage? ? deduction.amount : nil,
                amount_type: deduction.is_percentage? ? "percentage" : "fixed",
                deduction_type_id: deduction.deduction_type_id,
                tracked: tracked_deductions.include?([ deduction.employee_id, deduction.deduction_type_id ])
              }
            end

          field_schedules = EmployeePayrollField.active
            .joins(:employee, :payroll_field_definition)
            .where(employees: { company_id: current_company_id })
            .where(payroll_field_definitions: { company_id: current_company_id, kind: "deduction", category: "loan", active: true })
            .includes(:employee, :employee_loan, :payroll_field_definition)
            .map do |assignment|
              {
                kind: "payroll_field",
                id: assignment.id,
                employee_id: assignment.employee_id,
                employee_name: assignment.employee.full_name,
                label: assignment.payroll_field_definition.name,
                amount: assignment.amount || assignment.payroll_field_definition.default_amount,
                percentage: assignment.percentage || assignment.payroll_field_definition.default_percentage,
                amount_type: assignment.payroll_field_definition.amount_type,
                tracked: assignment.employee_loan&.active? || false
              }
            end

          (deduction_schedules + field_schedules).sort_by do |schedule|
            [ schedule[:employee_name].to_s, schedule[:label].to_s ]
          end
        end

        def loan_payload(loan, include_transactions: false)
          payload = {
            id: loan.id,
            employee_id: loan.employee_id,
            employee_name: loan.employee.full_name,
            name: loan.name,
            original_amount: loan.original_amount,
            opening_balance: loan.opening_balance,
            current_balance: loan.current_balance,
            balance_as_of: loan.balance_as_of,
            balance_source: loan.balance_source,
            principal_amount_known: loan.principal_amount_known,
            created_by_name: loan.created_by&.name,
            payment_amount: loan.payment_amount,
            start_date: loan.start_date,
            paid_off_date: loan.paid_off_date,
            status: loan.status,
            deduction_type_id: loan.deduction_type_id,
            notes: loan.notes,
            created_at: loan.created_at,
            updated_at: loan.updated_at
          }

          if include_transactions
            payload[:transactions] = loan.loan_transactions.chronological.map do |txn|
              {
                id: txn.id,
                transaction_type: txn.transaction_type,
                amount: txn.amount,
                balance_before: txn.balance_before,
                balance_after: txn.balance_after,
                transaction_date: txn.transaction_date,
                notes: txn.notes,
                source: txn.source,
                recorded_by_name: txn.recorded_by&.name,
                pay_period_id: txn.pay_period_id,
                created_at: txn.created_at
              }
            end
          end

          payload
        end
      end
    end
  end
end
