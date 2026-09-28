# frozen_string_literal: true

module Api
  module V1
    module Admin
      class FinanceApiTokensController < BaseController
        before_action :require_admin!

        def index
          tokens = FinanceApiToken.where(finance_book: current_finance_book).order(created_at: :desc, id: :desc)
          render json: { finance_book_id: current_finance_book.id, tokens: tokens.map { |token| payload(token) } }
        end

        def create
          name = params.require(:name).to_s.strip
          raise ArgumentError, "Give this access key a name" if name.blank?

          scopes = params[:draft_write] == true || params[:draft_write] == "true" ? %w[read draft_write] : [ "read" ]
          token, secret = FinanceApiToken.transaction do
            issued = FinanceApiToken.issue!(finance_book: current_finance_book, actor: current_user, name: name, scopes: scopes)
            AuditLog.record!(user: current_user, organization_id: current_organization_id,
                             company_id: current_finance_book.company_id, action: "finance_api_tokens#create",
                             record_type: "finance_api_tokens", record_id: issued.first.id, subject_name: issued.first.name,
                             metadata: { finance_book_id: current_finance_book.id, scopes: issued.first.scopes }, event_category: "security")
            issued
          end
          render json: { token: payload(token), secret: secret }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def destroy
          token = FinanceApiToken.where(finance_book: current_finance_book).find(params[:id])
          FinanceApiToken.transaction do
            if token.revoked_at.nil?
              token.update!(revoked_at: Time.current)
              AuditLog.record!(user: current_user, organization_id: current_organization_id,
                               company_id: current_finance_book.company_id, action: "finance_api_tokens#revoke",
                               record_type: "finance_api_tokens", record_id: token.id, subject_name: token.name,
                               metadata: { finance_book_id: current_finance_book.id }, event_category: "security")
            end
          end
          render json: { token: payload(token) }
        end

        private

        def payload(token)
          token.as_json(only: %i[id organization_id finance_book_id name scopes expires_at revoked_at last_used_at created_at])
        end
      end
    end
  end
end
