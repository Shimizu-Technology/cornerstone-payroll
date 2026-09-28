# frozen_string_literal: true

require "digest"
require "json"

module Api
  module V1
    module Finance
      # A separate boundary for book-scoped service keys. Clerk user routes never accept these keys.
      class AccessController < ActionController::API
        class WriteConflict < StandardError; end

        DRAFT_FIELDS = %w[
          invoice_recipient_id invoice_billing_profile_id invoice_number invoice_date due_date currency
          customer_reference service_period_start service_period_end notes payment_terms email_subject
          email_body discount_type discount_value line_items
        ].freeze
        LINE_ITEM_FIELDS = %w[id description quantity rate service_date position].freeze

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

        def recipients
          rows = InvoiceRecipient.where(finance_book_id: @book.id, organization_id: @token.organization_id).active.alphabetical
          render_scoped(recipients: rows.as_json(only: %i[id name email active]))
        end

        def billing_profiles
          rows = InvoiceBillingProfile.where(finance_book_id: @book.id, organization_id: @token.organization_id).active.ordered
          render_scoped(billing_profiles: rows.as_json(only: %i[id name legal_name is_default active]))
        end

        def create_invoice
          return unless require_draft_write!

          attributes, items = draft_input
          raise ArgumentError, "Choose an invoice recipient" if attributes[:invoice_recipient_id].blank?
          raise ArgumentError, "Choose a billing profile" if attributes[:invoice_billing_profile_id].blank?
          validate_party!(InvoiceRecipient, attributes[:invoice_recipient_id], "Invoice recipient")
          validate_party!(InvoiceBillingProfile, attributes[:invoice_billing_profile_id], "Billing profile")
          raise ArgumentError, "Add at least one line item" if items.blank?

          perform_write!(operation: "create", payload: attributes.to_h.merge("line_items" => items)) do
            invoice = Invoice.new(attributes)
            invoice.organization_id = @token.organization_id
            invoice.finance_book = @book
            invoice.company = @book.company
            invoice.created_by = @token.created_by
            invoice.updated_by = @token.created_by
            replace_line_items!(invoice, items)
            invoice.save!
            record_agent_event!(invoice, "draft_created")
            invoice
          end
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique => e
          if e.message.include?("idx_finance_api_requests_book_key")
            render json: { error: "Idempotency key was already used for a different request" }, status: :conflict
          else
            render json: { error: "Invoice number has already been taken" }, status: :unprocessable_entity
          end
        rescue WriteConflict => e
          render json: { error: e.message }, status: :conflict
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update_invoice
          return unless require_draft_write!

          invoice = invoice_scope.find(params[:id])
          attributes, items = draft_input
          validate_party!(InvoiceRecipient, attributes[:invoice_recipient_id], "Invoice recipient", current_id: invoice.invoice_recipient_id) if attributes[:invoice_recipient_id].present?
          validate_party!(InvoiceBillingProfile, attributes[:invoice_billing_profile_id], "Billing profile", current_id: invoice.invoice_billing_profile_id) if attributes[:invoice_billing_profile_id].present?
          version = Integer(request.headers["X-Invoice-Version"])
          raise ArgumentError, "Invoice version must be zero or greater" if version.negative?

          perform_write!(operation: "update:#{invoice.id}:#{version}", payload: attributes.to_h.merge("line_items" => items)) do
            invoice.lock!
            raise WriteConflict, "Invoice changed since you read it" unless invoice.lock_version == version
            raise ArgumentError, "Only active draft invoices can be edited" unless invoice.draft? && !invoice.archived?

            invoice.assign_attributes(attributes)
            invoice.updated_by = @token.created_by
            replace_line_items!(invoice, items) unless items.nil?
            invoice.updated_at = [ Time.current, invoice.updated_at + Rational(1, 1_000_000) ].max
            invoice.save!
            record_agent_event!(invoice, "draft_updated")
            invoice
          end
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "Invoice number has already been taken" }, status: :unprocessable_entity
        rescue WriteConflict => e
          render json: { error: e.message }, status: :conflict
        rescue ArgumentError, TypeError => e
          render json: { error: e.message }, status: :unprocessable_entity
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

        def require_draft_write!
          return true if @token.scopes.include?("draft_write")

          render json: { error: "This key cannot edit invoice drafts" }, status: :forbidden
          false
        end

        def draft_input
          source = params.require(:invoice)
          raise ArgumentError, "Invoice must be an object" unless source.is_a?(ActionController::Parameters)
          unknown = source.keys - DRAFT_FIELDS
          raise ArgumentError, "Unsupported invoice fields: #{unknown.join(', ')}" if unknown.any?

          items = if source.key?(:line_items)
            raise ArgumentError, "Line items must be an array" unless source[:line_items].is_a?(Array)
            raise ArgumentError, "Too many line items" if source[:line_items].length > 100
            source[:line_items].map do |item|
              raise ArgumentError, "Line item must be an object" unless item.is_a?(ActionController::Parameters)
              extra = item.keys - LINE_ITEM_FIELDS
              raise ArgumentError, "Unsupported line item fields: #{extra.join(', ')}" if extra.any?

              item.permit(*LINE_ITEM_FIELDS).to_h
            end
          end
          attributes = source.permit(*(DRAFT_FIELDS - [ "line_items" ]))
          [ attributes, items ]
        end

        def validate_party!(model, id, label, current_id: nil)
          party = model.find_by(id: id, organization_id: @token.organization_id, finance_book_id: @book.id)
          raise ArgumentError, "#{label} not found in this book" unless party
          raise ArgumentError, "#{label} is archived" unless party.active? || party.id == current_id
        end

        def replace_line_items!(invoice, items)
          existing = invoice.line_items.index_by { |item| item.id.to_s }
          seen_ids = []
          items.each_with_index do |item, position|
            id = item["id"].presence
            raise ArgumentError, "Line item does not belong to this invoice" if id && !existing.key?(id.to_s)
            raise ArgumentError, "Duplicate line item ID" if id && seen_ids.include?(id.to_s)

            line = id ? existing.fetch(id.to_s) : invoice.line_items.build
            line.assign_attributes(item.except("id"))
            line.position = position unless item.key?("position")
            seen_ids << id.to_s if id
          end
          invoice.line_items.each do |line|
            line.mark_for_destruction if line.persisted? && !seen_ids.include?(line.id.to_s)
          end
        end

        def record_agent_event!(invoice, event_type)
          InvoiceEvent.record!(invoice: invoice, event_type: event_type, actor: @token.created_by,
                               metadata: { finance_api_token_id: @token.id })
          AuditLog.record!(user: @token.created_by, organization_id: @token.organization_id,
                           company_id: @book.company_id, action: "finance_api##{event_type}",
                           record_type: "invoices", record_id: invoice.id, subject_name: invoice.invoice_number,
                           metadata: { finance_book_id: @book.id, finance_api_token_id: @token.id }, event_category: "finance")
        end

        def perform_write!(operation:, payload:)
          key = request.headers["Idempotency-Key"].to_s
          raise ArgumentError, "Idempotency-Key must be 8–128 letters, numbers, dashes, underscores, or colons" unless key.match?(/\A[A-Za-z0-9:_-]{8,128}\z/)

          digest = Digest::SHA256.hexdigest(JSON.generate(deep_sort({ operation: operation, payload: payload })))
          response_payload = nil
          replayed = false
          FinanceApiRequest.transaction do
            entry = FinanceApiRequest.create_or_find_by!(finance_book_id: @book.id, idempotency_key: key) do |record|
              record.organization_id = @token.organization_id
              record.finance_api_token = @token
              record.request_digest = digest
            end
            entry.lock!
            raise WriteConflict, "Idempotency key was already used for a different request" unless entry.request_digest == digest

            if entry.invoice_id
              replayed = true
              response_payload = entry.response_payload
            else
              invoice = yield
              response_payload = { invoice: InvoicePayloadBuilder.call(invoice.reload, detailed: true),
                                   scope: { organization_id: @token.organization_id, finance_book_id: @book.id } }
              entry.update!(invoice: invoice, response_payload: response_payload)
            end
          end
          render json: response_payload.merge(replayed: replayed), status: operation == "create" ? :created : :ok
        end

        def deep_sort(value)
          case value
          when Hash then value.keys.sort.to_h { |key| [ key, deep_sort(value[key]) ] }
          when Array then value.map { |item| deep_sort(item) }
          else value
          end
        end

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
