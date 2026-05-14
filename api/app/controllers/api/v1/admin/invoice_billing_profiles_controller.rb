# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoiceBillingProfilesController < BaseController
        before_action :set_profile, only: [ :show, :update, :destroy ]

        def index
          profiles = current_organization.invoice_billing_profiles.ordered
          profiles = profiles.active if ActiveModel::Type::Boolean.new.cast(params[:active])

          render json: { invoice_billing_profiles: profiles.map { |profile| profile_payload(profile) } }
        end

        def show
          render json: { invoice_billing_profile: profile_payload(@profile) }
        end

        def create
          profile = current_organization.invoice_billing_profiles.build(profile_attributes)

          if profile.save
            render json: { invoice_billing_profile: profile_payload(profile) }, status: :created
          else
            render json: { errors: profile.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @profile.update(profile_attributes)
            render json: { invoice_billing_profile: profile_payload(@profile.reload) }
          else
            render json: { errors: @profile.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          if @profile.invoices.exists?
            @profile.update!(active: false, is_default: false)
            render json: { invoice_billing_profile: profile_payload(@profile), message: "Billing profile archived" }
          else
            @profile.destroy!
            render json: { message: "Billing profile deleted" }
          end
        end

        private

        def set_profile
          @profile = current_organization.invoice_billing_profiles.find_by(id: params[:id])
          return if @profile

          render json: { error: "Invoice billing profile not found" }, status: :not_found
        end

        def profile_attributes
          params.require(:invoice_billing_profile).permit(
            :name,
            :legal_name,
            :website,
            :phone,
            :email,
            :address,
            :payment_instructions,
            :default_payment_terms,
            :invoice_prefix,
            :remit_to,
            :footer_note,
            :active,
            :is_default
          )
        end

        def profile_payload(profile)
          {
            id: profile.id,
            organization_id: profile.organization_id,
            name: profile.name,
            legal_name: profile.legal_name,
            website: profile.website,
            phone: profile.phone,
            email: profile.email,
            address: profile.address,
            payment_instructions: profile.payment_instructions,
            default_payment_terms: profile.default_payment_terms,
            invoice_prefix: profile.invoice_prefix,
            remit_to: profile.remit_to,
            footer_note: profile.footer_note,
            active: profile.active,
            is_default: profile.is_default,
            created_at: profile.created_at,
            updated_at: profile.updated_at
          }
        end
      end
    end
  end
end
