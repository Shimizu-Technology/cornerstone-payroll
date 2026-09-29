# frozen_string_literal: true

require "csv"

module Api
  module V1
    module Admin
      class ExpensesController < BaseController
        before_action :require_admin!
        before_action :set_expense, only: %i[show update void upload_artifact download_artifact]

        def index
          page = [ params.fetch(:page, 1).to_i, 1 ].max
          per_page = params.fetch(:per_page, 50).to_i.clamp(1, 100)
          expenses = filtered_scope.includes(:expense_vendor, :expense_payments, :expense_artifacts)
          total_count = expenses.count
          rows = expenses.recent.offset((page - 1) * per_page).limit(per_page)
          render json: {
            expenses: rows.map { |expense| ExpensePayloadBuilder.call(expense) },
            meta: { page: page, per_page: per_page, total_count: total_count },
            summary: summary_for(filtered_scope.active)
          }
        rescue Date::Error
          render json: { error: "Date filters must use YYYY-MM-DD" }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def show
          render json: { expense: ExpensePayloadBuilder.call(@expense, detailed: true) }
        end

        def create
          attrs = expense_params.to_h.symbolize_keys
          payment = paid_purchase_params
          source_key = attrs[:source_key].presence
          raise ArgumentError, "A source key is required for paid purchases" if payment && source_key.blank?
          if source_key && (existing = scope.find_by(source_key: source_key))
            candidate = scope.new(attrs)
            unless same_expense?(existing, candidate) && same_paid_purchase?(existing, payment)
              return render json: { error: "Source key already belongs to a different expense" }, status: :conflict
            end
            return render json: { expense: ExpensePayloadBuilder.call(existing, detailed: true), already_exists: true }
          end

          expense = scope.new(attrs)
          expense.finance_book = current_finance_book
          expense.payment_included_at_creation = payment.present?
          expense.created_by = current_user
          expense.updated_by = current_user
          Expense.transaction do
            expense.save!
            if payment
              ExpensePaymentService.record!(expense: expense, actor: current_user, amount: expense.total_amount,
                                            paid_on: payment.fetch(:paid_on), payment_method: payment.fetch(:payment_method),
                                            reference_number: payment[:reference_number], notes: payment[:notes])
            end
          end
          render json: { expense: ExpensePayloadBuilder.call(expense, detailed: true) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          existing = source_key && scope.find_by(source_key: source_key)
          if existing && same_expense?(existing, scope.new(attrs)) && same_paid_purchase?(existing, payment)
            render json: { expense: ExpensePayloadBuilder.call(existing, detailed: true), already_exists: true }
          else
            render json: { error: "An expense with that source key already exists" }, status: :conflict
          end
        rescue ArgumentError, Date::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update
          @expense.with_lock do
            raise ArgumentError, "Voided expenses cannot be changed" if @expense.voided?

            @expense.assign_attributes(expense_params.except(:source_key))
            @expense.updated_by = current_user
            @expense.save!
          end
          render json: { expense: ExpensePayloadBuilder.call(@expense.reload, detailed: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def void
          reason = params.require(:reason).to_s.strip
          raise ArgumentError, "A void reason is required" if reason.blank?

          @expense.with_lock do
            raise ArgumentError, "Expense has already been voided" if @expense.voided?
            raise ArgumentError, "Reverse recorded payments before voiding" if @expense.expense_payments.active.exists?

            @expense.update!(voided_at: Time.current, void_reason: reason, updated_by: current_user)
          end
          render json: { expense: ExpensePayloadBuilder.call(@expense.reload, detailed: true) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def upload_artifact
          raise ArgumentError, "Voided expenses cannot receive receipts" if @expense.voided?

          artifact = ExpenseArtifactStorageService.new.upload!(expense: @expense, actor: current_user, file: params[:file])
          render json: { artifact: artifact.as_json(only: %i[id filename content_type byte_size sha256 created_at]) }, status: :created
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue R2StorageService::UploadError => e
          Rails.logger.warn("Expense receipt upload failed: #{e.class}: #{e.message}")
          render json: { error: "Unable to store the expense receipt" }, status: :unprocessable_entity
        end

        def download_artifact
          artifact = @expense.expense_artifacts.find(params[:artifact_id])
          bytes = ExpenseArtifactStorageService.new.download(artifact)
          send_data bytes, type: artifact.content_type, filename: artifact.filename, disposition: "attachment"
        rescue R2StorageService::DownloadError => e
          Rails.logger.warn("Expense receipt download failed: #{e.class}: #{e.message}")
          render json: { error: "Expense receipt is unavailable" }, status: :not_found
        end

        def export
          rows = filtered_scope.includes(:expense_vendor, :expense_payments)
          csv = CSV.generate do |file|
            file << %w[date vendor reference category description currency total paid balance status due_date kind]
            rows.find_each do |expense|
              file << [ expense.expense_on, safe_csv(expense.expense_vendor.name), safe_csv(expense.reference_number),
                        safe_csv(expense.category), safe_csv(expense.description), expense.currency,
                        expense.total_amount.to_s("F"), expense.amount_paid.to_s("F"), expense.balance_due.to_s("F"),
                        expense.payment_status, expense.due_on,
                        expense.payment_included_at_creation? ? "purchase" : "bill" ]
            end
          end
          send_data csv, type: "text/csv", filename: "expenses-#{Date.current.iso8601}.csv", disposition: "attachment"
        rescue Date::Error
          render json: { error: "Date filters must use YYYY-MM-DD" }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def same_expense?(existing, candidate)
          comparable = %i[expense_vendor_id category description expense_on due_on total_amount currency reference_number]
          comparable.all? { |field| existing.public_send(field) == candidate.public_send(field) }
        end

        def same_paid_purchase?(expense, payment)
          return false unless expense.payment_included_at_creation? == payment.present?

          active = expense.expense_payments.active.to_a
          return true if payment.blank?
          return false unless active.one?

          recorded = active.first
          recorded.amount == expense.total_amount && recorded.paid_on == payment[:paid_on] &&
            recorded.payment_method == payment[:payment_method] &&
            recorded.reference_number.to_s == payment[:reference_number].to_s &&
            recorded.notes.to_s == payment[:notes].to_s
        end

        def paid_purchase_params
          return nil unless params.key?(:payment)

          payment = params[:payment]
          raise ArgumentError, "Payment details must be an object" unless payment.is_a?(ActionController::Parameters)

          raw = payment.permit(:paid_on, :payment_method, :reference_number, :notes)
          raise ArgumentError, "Payment date must use YYYY-MM-DD" unless raw[:paid_on].is_a?(String)

          paid_on = Date.iso8601(raw.require(:paid_on))
          method = raw.require(:payment_method)
          reference = raw[:reference_number].to_s.strip.presence
          notes = raw[:notes].to_s.strip.presence
          raise ArgumentError, "Add a payment reference or evidence note" if reference.blank? && notes.blank?

          { paid_on: paid_on, payment_method: method, reference_number: reference, notes: notes }
        end

        def set_expense
          @expense = scope.includes(:expense_vendor, :expense_payments, :expense_artifacts).find(params[:id])
        end

        def scope
          Expense.where(organization_id: current_organization_id, finance_book_id: current_finance_book.id)
        end

        def filtered_scope
          rows = scope
          rows = case params[:kind]
          when nil, "" then rows
          when "bill" then rows.where(payment_included_at_creation: false)
          when "purchase" then rows.where(payment_included_at_creation: true)
          else raise ArgumentError, "Unknown expense kind"
          end
          rows = rows.where(expense_vendor_id: params[:vendor_id]) if params[:vendor_id].present?
          rows = rows.where(category: params[:category]) if params[:category].present?
          rows = rows.where("expense_on >= ?", Date.iso8601(params[:from])) if params[:from].present?
          rows = rows.where("expense_on <= ?", Date.iso8601(params[:to])) if params[:to].present?
          rows = rows.active unless ActiveModel::Type::Boolean.new.cast(params[:include_voided])
          if params[:q].present?
            query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.strip.first(200))}%"
            rows = rows.joins(:expense_vendor).where(
              "expense_vendors.name ILIKE :query OR expenses.reference_number ILIKE :query OR " \
              "expenses.description ILIKE :query OR expenses.category ILIKE :query", query: query
            )
          end
          rows = filter_payment_status(rows, params[:status]) if params[:status].present?
          rows
        end

        def filter_payment_status(rows, status)
          rows = rows.active
          payment_total = "(SELECT COALESCE(SUM(ep.amount), 0) FROM expense_payments ep " \
                          "WHERE ep.expense_id = expenses.id AND ep.reversed_at IS NULL)"
          balance = "expenses.total_amount - #{payment_total}"
          case status
          when "paid" then rows.where("#{balance} = 0")
          when "overdue" then rows.where("#{balance} > 0 AND expenses.due_on < ?", Date.current)
          when "partial" then rows.where("#{payment_total} > 0 AND #{balance} > 0 AND " \
                                          "(expenses.due_on IS NULL OR expenses.due_on >= ?)", Date.current)
          when "open" then rows.where("#{payment_total} = 0 AND " \
                                       "(expenses.due_on IS NULL OR expenses.due_on >= ?)", Date.current)
          else raise ArgumentError, "Unknown expense status"
          end
        end

        def expense_params
          params.require(:expense).permit(:expense_vendor_id, :reference_number, :source_key, :category, :description,
                                          :expense_on, :due_on, :total_amount, :currency)
        end

        def safe_csv(value)
          string = value.to_s
          string.match?(/\A\s*[=+\-@]/) ? "'#{string}" : string
        end

        def summary_for(rows)
          totals = rows.group(:currency).sum(:total_amount)
          paid = ExpensePayment.active.joins(:expense).where(expense_id: rows.select(:id))
                               .group("expenses.currency").sum(:amount)
          overdue = rows.where("due_on < ?", Date.current).where(
            "total_amount > COALESCE((SELECT SUM(amount) FROM expense_payments WHERE expense_payments.expense_id = expenses.id AND expense_payments.reversed_at IS NULL), 0)"
          ).count
          {
            currencies: totals.map do |currency, total|
              amount_paid = paid.fetch(currency, 0.to_d)
              { currency: currency, total_amount: total.to_s("F"), amount_paid: amount_paid.to_s("F"),
                balance_due: (total - amount_paid).to_s("F") }
            end,
            overdue_count: overdue
          }
        end
      end
    end
  end
end
