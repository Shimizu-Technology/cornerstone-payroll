# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ExpenseVendorsController < BaseController
        before_action :require_admin!

        def index
          vendors = scope.alphabetical
          vendors = vendors.where(active: true) if ActiveModel::Type::Boolean.new.cast(params[:active])
          render json: { expense_vendors: vendors.as_json(only: %i[id organization_id name email notes active]) }
        end

        def create
          vendor = scope.create!(vendor_params.merge(organization: current_organization, finance_book: current_finance_book))
          render json: { expense_vendor: vendor_payload(vendor) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        def update
          vendor = scope.find(params[:id])
          vendor.update!(vendor_params)
          render json: { expense_vendor: vendor_payload(vendor) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def scope
          ExpenseVendor.where(organization_id: current_organization_id, finance_book_id: current_finance_book.id)
        end

        def vendor_params
          params.require(:expense_vendor).permit(:name, :email, :notes, :active)
        end

        def vendor_payload(vendor)
          vendor.as_json(only: %i[id organization_id name email notes active])
        end
      end
    end
  end
end
