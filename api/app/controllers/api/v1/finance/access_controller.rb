# frozen_string_literal: true

module Api
  module V1
    module Finance
      # A separate boundary for book-scoped service keys. Clerk user routes never accept these keys.
      class AccessController < ActionController::API
        before_action :authenticate_token!
        before_action :require_explicit_scope!

        def context
          render_scoped(book: @book.as_json(only: %i[id organization_id company_id name legal_name kind active]),
                        scopes: @token.scopes)
        end

        def overview
          raw_date = params[:as_of]
          raise ArgumentError, "As-of date must use YYYY-MM-DD" unless raw_date.nil? || raw_date.is_a?(String)

          as_of = raw_date.present? ? Date.iso8601(raw_date) : Date.current
          render_scoped(overview: FinanceOverviewSummary.new(finance_book: @book, as_of: as_of).call)
        rescue Date::Error
          render json: { error: "As-of date must use YYYY-MM-DD" }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def invoices
          rows = invoice_scope.recent
                              .includes(:invoice_recipient, :invoice_billing_profile, :line_items, :artifacts,
                                        :payments, :credit_notes, :deliveries, :created_by, :updated_by)
                              .offset(offset).limit(per_page)
          render_scoped(invoices: rows.map { |invoice| InvoicePayloadBuilder.call(invoice) },
                        meta: { page: page, per_page: per_page, total_count: invoice_scope.count })
        rescue ArgumentError
          invalid_pagination
        end

        def invoice
          record = invoice_scope.find(params[:id])
          render_scoped(invoice: InvoicePayloadBuilder.call(record, detailed: true))
        end

        def expenses
          rows = expense_scope.includes(:expense_vendor, :expense_payments, :expense_artifacts)
                              .order(expense_on: :desc, id: :desc).offset(offset).limit(per_page)
          render_scoped(expenses: rows.map { |expense| ExpensePayloadBuilder.call(expense) },
                        meta: { page: page, per_page: per_page, total_count: expense_scope.count })
        rescue ArgumentError
          invalid_pagination
        end

        def expense
          record = expense_scope.find(params[:id])
          render_scoped(expense: ExpensePayloadBuilder.call(record, detailed: true))
        end

        private

        def authenticate_token!
          secret = request.authorization.to_s.match(/\ABearer (cfin_[a-f0-9]{64})\z/)&.captures&.first
          @token = FinanceApiToken.authenticate(secret)
          return render json: { error: "Invalid or expired finance access key" }, status: :unauthorized unless @token

          @book = @token.finance_book
          @token.update_columns(last_used_at: Time.current) if @token.last_used_at.nil? || @token.last_used_at < 1.hour.ago
        end

        def require_explicit_scope!
          organization_id = request.headers["X-Organization-Id"]
          book_id = request.headers["X-Finance-Book-Id"]
          unless organization_id.to_s.match?(/\A[1-9]\d*\z/) && book_id.to_s.match?(/\A[1-9]\d*\z/)
            return render json: { error: "Organization and financial book are required" }, status: :unprocessable_entity
          end
          unless organization_id.to_i == @token.organization_id && book_id.to_i == @token.finance_book_id
            return render json: { error: "Access key is not authorized for this financial book" }, status: :forbidden
          end

          response.set_header("X-Effective-Organization-Id", @token.organization_id.to_s)
          response.set_header("X-Effective-Finance-Book-Id", @token.finance_book_id.to_s)
        end

        def render_scoped(data)
          render json: data.merge(scope: { organization_id: @token.organization_id, finance_book_id: @book.id })
        end

        def invoice_scope
          Invoice.where(organization_id: @token.organization_id, finance_book_id: @book.id)
        end

        def expense_scope
          Expense.where(organization_id: @token.organization_id, finance_book_id: @book.id)
        end

        def page
          value = Integer(params.fetch(:page, 1))
          raise ArgumentError unless value.positive?

          value
        end

        def per_page
          value = Integer(params.fetch(:per_page, 50))
          raise ArgumentError unless value.between?(1, 100)

          value
        end

        def offset
          (page - 1) * per_page
        end

        def invalid_pagination
          render json: { error: "Page and per_page must be positive numbers (per_page at most 100)" },
                 status: :unprocessable_entity
        end
      end
    end
  end
end
