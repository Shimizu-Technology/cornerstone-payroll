# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoiceBillingProfilesController < BaseController
        before_action :require_admin!

        before_action :set_profile, only: [ :show, :update, :destroy, :upload_logo, :remove_logo, :sample_pdf ]

        def index
          profiles = current_finance_book.invoice_billing_profiles.ordered
          profiles = profiles.active if ActiveModel::Type::Boolean.new.cast(params[:active])

          render json: { invoice_billing_profiles: profiles.map { |profile| profile_payload(profile) } }
        end

        def show
          render json: { invoice_billing_profile: profile_payload(@profile) }
        end

        def create
          profile = current_finance_book.invoice_billing_profiles.build(profile_attributes.merge(organization: current_organization))

          if profile.save
            render json: { invoice_billing_profile: profile_payload(profile) }, status: :created
          else
            render json: { errors: profile.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotUnique
          render_record_not_unique
        end

        def update
          if @profile.update(profile_attributes)
            render json: { invoice_billing_profile: profile_payload(@profile.reload) }
          else
            render json: { errors: @profile.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotUnique
          render_record_not_unique
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

        def upload_logo
          InvoiceLogoStorageService.new.upload!(profile: @profile, file: params.require(:file))
          render json: { invoice_billing_profile: profile_payload(@profile.reload) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue R2StorageService::UploadError
          render json: { error: "Unable to store the logo" }, status: :unprocessable_entity
        end

        def remove_logo
          InvoiceLogoStorageService.new.remove!(profile: @profile)
          render json: { invoice_billing_profile: profile_payload(@profile.reload) }
        end

        # Renders a made-up invoice in this profile's style. Unsaved style
        # fields and an unsaved logo may be sent to preview a change; nothing
        # is stored. Read-only, so it is allowed wherever the profile can be
        # viewed.
        def sample_pdf
          @profile.assign_attributes(style_preview_attributes) if params[:invoice_billing_profile].present?
          @profile.validate
          style_errors = @profile.errors.select { |error| STYLE_PREVIEW_FIELDS.include?(error.attribute.to_s) }
          if style_errors.any?
            render json: { errors: style_errors.map(&:full_message) }, status: :unprocessable_entity
            return
          end

          generator = InvoicePdfGenerator.new(nil, snapshot: InvoicePdf::Sample.snapshot(@profile), logo: preview_logo)
          disposition = params[:disposition] == "attachment" ? "attachment" : "inline"
          send_data generator.generate, filename: "invoice-style-sample-#{@profile.invoice_theme}.pdf",
                                        type: "application/pdf", disposition: disposition
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue R2StorageService::DownloadError, Prawn::Errors::CannotFit => e
          Rails.logger.warn("Invoice style sample failed: #{e.class}: #{e.message}")
          render json: { error: "Unable to render the sample invoice" }, status: :unprocessable_entity
        end

        private

        def set_profile
          @profile = current_finance_book.invoice_billing_profiles.find_by(id: params[:id])
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
            :numbering_style,
            :next_invoice_number,
            :invoice_number_width,
            :remit_to,
            :footer_note,
            :invoice_theme,
            :accent_color,
            :logo_size,
            :show_service_period,
            :show_item_column,
            :show_how_to_pay,
            :active,
            :is_default,
            service_catalog: [ :name, :description_template, :line_kind ]
          )
        end

        STYLE_PREVIEW_FIELDS = %w[
          invoice_theme accent_color logo_size show_service_period show_item_column show_how_to_pay
          footer_note payment_instructions
        ].freeze

        def style_preview_attributes
          params.require(:invoice_billing_profile).permit(*STYLE_PREVIEW_FIELDS)
        end

        # A chosen-but-unsaved logo, the monogram when removal is pending, or
        # the saved logo.
        def preview_logo
          return InvoiceLogoStorageService.new.validated_bytes(params[:logo]).first if params[:logo].present?
          return InvoicePdfGenerator::NO_LOGO if ActiveModel::Type::Boolean.new.cast(params[:remove_logo])

          nil
        end

        def render_record_not_unique
          render json: { errors: [ "A billing profile with those settings already exists" ] }, status: :unprocessable_entity
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
            numbering_style: profile.numbering_style,
            next_invoice_number: profile.next_invoice_number,
            invoice_number_width: profile.invoice_number_width,
            next_invoice_number_preview: profile.format_continuing_number(profile.next_invoice_number),
            service_catalog: profile.service_catalog,
            remit_to: profile.remit_to,
            footer_note: profile.footer_note,
            invoice_theme: profile.invoice_theme,
            accent_color: profile.accent_color,
            effective_accent_color: profile.invoice_style.accent_hex,
            logo_size: profile.logo_size,
            show_service_period: profile.show_service_period,
            show_item_column: profile.show_item_column,
            show_how_to_pay: profile.show_how_to_pay,
            has_logo: profile.logo_storage_key.present?,
            logo_content_type: profile.logo_content_type,
            logo_byte_size: profile.logo_byte_size,
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
