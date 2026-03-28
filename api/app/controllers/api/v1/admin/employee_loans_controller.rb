# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeLoansController < BaseController
        before_action :set_loan, only: [:show, :update, :destroy, :record_payment, :record_addition]

        # GET /api/v1/admin/employee_loans
        def index
          loans = EmployeeLoan.where(company_id: current_company_id)
            .joins(:employee)
            .includes(:employee, :deduction_type, :loan_transactions)

          loans = loans.where(employee_id: params[:employee_id]) if params[:employee_id].present?
          loans = loans.where(status: params[:status]) if params[:status].present?

          loans = loans.order("employees.last_name ASC, employees.first_name ASC, employee_loans.name ASC")

          render json: { loans: loans.map { |l| loan_payload(l) } }
        end

        # GET /api/v1/admin/employee_loans/:id
        def show
          render json: { loan: loan_payload(@loan, include_transactions: true) }
        end

        # POST /api/v1/admin/employee_loans
        def create
          employee = Employee.find_by(id: loan_params[:employee_id], company_id: current_company_id)
          unless employee
            return render json: { error: "Employee not found" }, status: :not_found
          end

          loan = EmployeeLoan.new(loan_params)
          loan.company_id = current_company_id
          loan.employee = employee
          loan.current_balance = loan.original_amount if loan.current_balance.zero?

          ActiveRecord::Base.transaction do
            loan.save!

            # Record initial addition transaction
            loan.loan_transactions.create!(
              transaction_type: "addition",
              amount: loan.original_amount,
              balance_before: 0,
              balance_after: loan.original_amount,
              transaction_date: loan.start_date || Date.current,
              notes: "Initial loan"
            )
          end

          render json: { loan: loan_payload(loan) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/employee_loans/:id
        def update
          if @loan.update(loan_update_params)
            render json: { loan: loan_payload(@loan) }
          else
            render json: { errors: @loan.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/admin/employee_loans/:id
        def destroy
          if @loan.loan_transactions.payments.any?
            return render json: { error: "Cannot delete a loan with payment history" }, status: :unprocessable_entity
          end

          @loan.destroy!
          render json: { message: "Loan deleted" }
        end

        # POST /api/v1/admin/employee_loans/:id/record_payment
        def record_payment
          amount = BigDecimal(params[:amount].to_s)
          actual = @loan.record_payment!(
            amount: amount,
            date: params[:date].present? ? Date.parse(params[:date]) : nil
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
            notes: params[:notes]
          )
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
            :start_date, :deduction_type_id, :notes, :status
          )
        end

        def loan_update_params
          params.require(:employee_loan).permit(
            :name, :payment_amount, :status, :notes, :deduction_type_id
          )
        end

        def loan_payload(loan, include_transactions: false)
          payload = {
            id: loan.id,
            employee_id: loan.employee_id,
            employee_name: loan.employee.full_name,
            name: loan.name,
            original_amount: loan.original_amount,
            current_balance: loan.current_balance,
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
