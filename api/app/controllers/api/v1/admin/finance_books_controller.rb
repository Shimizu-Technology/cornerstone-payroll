# frozen_string_literal: true

module Api
  module V1
    module Admin
      class FinanceBooksController < BaseController
        before_action :require_admin!

        def index
          books = FinanceBook.active.accessible_to(current_user).where(organization_id: current_organization_id).ordered
          books = books.select { |book| book.company_id.nil? || current_user.can_access_company?(book.company_id) }
          render json: {
            organization_id: current_organization_id,
            effective_finance_book_id: books.one? ? books.first.id : nil,
            finance_books: books.map do |book|
              payload(book)
            end
          }
        end

        def create
          attributes = params.require(:finance_book).permit(:name, :legal_name, :kind, :company_id)
          if attributes[:kind] == "personal"
            unless current_user.super_admin? || current_organization_id == current_user.organization_id
              return render json: { error: "You do not have access to a personal book in this organization" }, status: :forbidden
            end
            attributes[:owner_user] = current_user
          end
          if attributes[:company_id].present?
            company = Company.find_by(id: attributes[:company_id], organization_id: current_organization_id)
            return render json: { error: "Client company not found" }, status: :not_found unless company
            return render json: { error: "You do not have access to this client" }, status: :forbidden unless current_user.can_access_company?(company.id)
          end
          book = current_organization.finance_books.create!(attributes.merge(is_default: false))
          render json: { finance_book: payload(book) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "A financial book with these details already exists" }, status: :conflict
        end

        def update
          book = current_organization.finance_books.accessible_to(current_user).find(params[:id])
          if book.company_id && !current_user.can_access_company?(book.company_id)
            return render json: { error: "You do not have access to this financial book" }, status: :forbidden
          end
          book.update!(params.require(:finance_book).permit(:name, :legal_name))
          render json: { finance_book: payload(book) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "A financial book with this name already exists" }, status: :conflict
        end

        private

        def payload(book)
          book.as_json(only: %i[id organization_id company_id name legal_name kind is_default active])
        end
      end
    end
  end
end
