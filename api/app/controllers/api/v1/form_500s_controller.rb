# frozen_string_literal: true

module Api
  module V1
    class Form500sController < ApplicationController
      before_action :require_staff_access!
      before_action :set_pay_period!

      def defaults
        render json: {
          data: form500_payload,
          saved_at: @form500_filing&.updated_at
        }
      end

      def save
        filing = persist_form500_filing!

        render json: {
          data: filing.fields.deep_symbolize_keys,
          saved_at: filing.updated_at
        }
      end

      def preview
        send_form500_pdf(disposition: "inline", filename_prefix: "Form500_Preview")
      end

      def download
        send_form500_pdf(disposition: "attachment", filename_prefix: "Form500")
      end

      private

      def send_form500_pdf(disposition:, filename_prefix:)
        filing = persist_form500_filing!
        payload = filing.fields.deep_symbolize_keys
        pdf = Form500Generator.new(fields: payload).generate
        suffix = if @pay_period.pay_date
          quarter = ((@pay_period.pay_date.month - 1) / 3) + 1
          "#{@pay_period.pay_date.year}_Q#{quarter}"
        end

        send_data pdf,
          filename: [ filename_prefix, current_company.name.parameterize.presence, suffix ].compact.join("_") + ".pdf",
          type: "application/pdf",
          disposition: disposition
      end

      def defaults_payload
        Form500Generator.default_fields(company: current_company, pay_period: @pay_period)
      end

      def form500_payload
        merge_with_defaults(defaults_payload, saved_fields_payload)
      end

      def saved_fields_payload
        @form500_filing&.fields&.deep_symbolize_keys || {}
      end

      def set_pay_period!
        pay_period_id = params[:pay_period_id].presence || params.dig(:form_500, :pay_period_id).presence
        unless pay_period_id.present?
          render json: { error: "pay_period_id is required" }, status: :unprocessable_entity
          return
        end

        @pay_period = PayPeriod.find_by(id: pay_period_id, company_id: current_company_id)
        unless @pay_period
          render json: { error: "Pay period not found" }, status: :not_found
          return
        end

        @form500_filing = @pay_period.form500_filing
      end

      def persist_form500_filing!
        filing = @form500_filing || @pay_period.build_form500_filing(company: current_company)
        filing.created_by ||= current_user
        filing.updated_by = current_user
        filing.fields = merge_with_defaults(defaults_payload, form500_params.to_h.deep_symbolize_keys.except(:pay_period_id), preserve_blank_strings: true)
        filing.save!
        @form500_filing = filing
      end

      def form500_params
        params.fetch(:form_500, {}).permit(
          :pay_period_id,
          :company_name,
          :company_address_line1,
          :company_address_line2,
          :company_city,
          :company_state,
          :company_zip,
          :employer_identification_number,
          :total_taxes_dollars,
          :total_taxes_cents,
          :tax_year,
          :tax_period_quarter,
          :notes,
          :pay_date,
          :period_label,
          :income_tax_withholding_on_wages,
          :tax_withholding_30_percent,
          :corporate_estimated_tax,
          :income_tax_withholding_1099
        )
      end

      def require_staff_access!
        return if current_user&.admin? || current_user&.manager? || current_user&.accountant?

        render json: { error: "Access denied" }, status: :forbidden
      end

      def merge_with_defaults(defaults, overrides, preserve_blank_strings: false)
        overrides.each_with_object(defaults.deep_dup) do |(key, value), merged|
          next unless should_apply_override?(value, preserve_blank_strings:)

          merged[key] = value
        end
      end

      def should_apply_override?(value, preserve_blank_strings:)
        return true if value == false
        return preserve_blank_strings if value.is_a?(String) && value.blank?

        value.present?
      end
    end
  end
end
