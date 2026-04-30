# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayStubsController < BaseController
        before_action :set_payroll_item, only: [ :show, :generate, :download ]

        # GET /api/v1/admin/pay_stubs/:payroll_item_id
        # Get pay stub info (not the PDF itself)
        def show
          existing_key = existing_storage_key

          render json: {
            pay_stub: {
              payroll_item_id: @payroll_item.id,
              employee_name: @payroll_item.employee.full_name,
              pay_period: @payroll_item.pay_period.period_description,
              pay_date: @payroll_item.pay_period.pay_date,
              net_pay: @payroll_item.net_pay,
              generated: existing_key.present?,
              storage_key: existing_key || storage_key
            }
          }
        end

        # POST /api/v1/admin/pay_stubs/:payroll_item_id/generate
        # Generate and store the PDF
        def generate
          # Generate PDF
          generator = PayStubGenerator.new(@payroll_item)
          pdf_data = generator.generate

          # Store in R2 (if configured)
          if r2_configured?
            storage = R2StorageService.new
            storage.upload(storage_key, pdf_data, content_type: "application/pdf")
          end

          render json: {
            pay_stub: {
              payroll_item_id: @payroll_item.id,
              employee_name: @payroll_item.employee.full_name,
              generated: true,
              storage_key: storage_key,
              message: r2_configured? ? "PDF generated and stored" : "PDF generated (storage not configured)"
            }
          }
        rescue R2StorageService::UploadError => e
          render json: { error: e.message }, status: :service_unavailable
        end

        # GET /api/v1/admin/pay_stubs/:payroll_item_id/download
        # Download the PDF (generate on-the-fly or from storage)
        def download
          # Try to get from storage first
          if r2_configured?
            storage = R2StorageService.new
            key = existing_storage_key(storage: storage)
            pdf_data = storage.download(key) if key.present?
          end

          # Generate fresh if not in storage
          if pdf_data.nil?
            generator = PayStubGenerator.new(@payroll_item)
            pdf_data = generator.generate
          end

          send_data pdf_data,
                    filename: "paystub_#{@payroll_item.employee.last_name}_#{@payroll_item.pay_period.pay_date}.pdf",
                    type: "application/pdf",
                    disposition: "attachment"
        end

        # POST /api/v1/admin/pay_stubs/batch_generate
        # Generate pay stubs for all employees in a pay period
        def batch_generate
          pay_period = PayPeriod.find(params[:pay_period_id])

          unless pay_period.company_id == current_company_id
            return render json: { error: "Pay period not found" }, status: :not_found
          end

          results = { success: [], errors: [] }

          pay_period.payroll_items.includes(:employee).each do |item|
            begin
              generator = PayStubGenerator.new(item)
              pdf_data = generator.generate

              if r2_configured?
                storage = R2StorageService.new
                key = pay_stub_key(item)
                storage.upload(key, pdf_data, content_type: "application/pdf")
              end

              results[:success] << {
                payroll_item_id: item.id,
                employee_name: item.employee.full_name
              }
            rescue StandardError => e
              results[:errors] << {
                payroll_item_id: item.id,
                employee_name: item.employee.full_name,
                error: e.message
              }
            end
          end

          render json: {
            pay_period_id: pay_period.id,
            total: pay_period.payroll_items.count,
            generated: results[:success].count,
            errors: results[:errors].count,
            results: results
          }
        end

        # POST /api/v1/admin/pay_stubs/batch_pdf
        # Generate one plain-paper PDF containing all or selected pay stubs for a pay period.
        def batch_pdf
          pay_period = PayPeriod.find(params[:pay_period_id])

          unless pay_period.company_id == current_company_id
            return render json: { error: "Pay period not found" }, status: :not_found
          end

          unless pay_period.committed?
            return render json: { error: "Pay stubs are only available for committed pay periods" }, status: :unprocessable_entity
          end

          requested_ids = Array(params[:payroll_item_ids]).compact_blank.map(&:to_i).uniq
          base_items = pay_period.payroll_items
                                 .includes(:employee, :pay_period)
                                 .left_outer_joins(:employee)

          if requested_ids.any?
            selected_items = base_items.where(id: requested_ids).to_a

            if selected_items.size != requested_ids.size
              return render json: { error: "One or more selected pay stubs were not found" }, status: :not_found
            end

            voided_items = selected_items.select(&:voided?)
            if voided_items.any?
              names = voided_items.map { |item| item.employee&.full_name || "Payroll item ##{item.id}" }.to_sentence
              return render json: {
                error: "Voided checks do not have printable pay stubs",
                details: "Remove #{names} from the selection and try again."
              }, status: :unprocessable_entity
            end

            items = base_items.where(id: requested_ids)
          else
            items = base_items.where(voided: false)
          end

          items = items.order("employees.last_name ASC, employees.first_name ASC, payroll_items.id ASC").to_a

          if items.empty?
            return render json: { error: "No pay stubs found for this pay period" }, status: :unprocessable_entity
          end

          combined_pdf = combine_pdfs(items.map { |item| PayStubGenerator.new(item).generate })
          pay_date = pay_period.pay_date&.strftime("%Y-%m-%d") || "undated"
          filename_prefix = requested_ids.any? ? "selected_paystubs" : "paystubs"

          send_data combined_pdf,
            type: "application/pdf",
            disposition: "attachment",
            filename: "#{filename_prefix}_#{pay_date}.pdf"
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Pay period not found" }, status: :not_found
        rescue LoadError
          render json: {
            error: "Batch pay stub PDF requires the combine_pdf gem. Please install it or contact your administrator."
          }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/pay_stubs/employee/:employee_id
        # List all pay stubs for an employee
        def employee_stubs
          employee = Employee.find(params[:employee_id])

          unless employee.company_id == current_company_id
            return render json: { error: "Employee not found" }, status: :not_found
          end

          items = employee.payroll_items
                         .includes(:pay_period)
                         .where(pay_periods: {
                           id: PayPeriod.reportable_committed
                                        .where(company_id: employee.company_id)
                                        .select(:id)
                         })
                         .order("pay_periods.pay_date DESC")
                         .limit(params[:limit] || 12)

          render json: {
            employee: {
              id: employee.id,
              name: employee.full_name
            },
            pay_stubs: items.map do |item|
              {
                payroll_item_id: item.id,
                pay_period: item.pay_period.period_description,
                pay_date: item.pay_period.pay_date,
                net_pay: item.net_pay,
                storage_key: pay_stub_key(item)
              }
            end
          }
        end

        private

        def set_payroll_item
          @payroll_item = PayrollItem.includes(:employee, :pay_period).find(params[:payroll_item_id] || params[:id])

          unless @payroll_item.pay_period.company_id == current_company_id
            render json: { error: "Payroll item not found" }, status: :not_found
          end
        end

        def storage_key
          pay_stub_key(@payroll_item)
        end

        def pay_stub_key(item)
          year = item.pay_period.pay_date.year
          pay_date = item.pay_period.pay_date.strftime("%Y%m%d")
          "paystubs/#{year}/company_#{item.company_id}/employee_#{item.employee_id}/payroll_item_#{item.id}_#{pay_date}.pdf"
        end

        def legacy_pay_stub_key(item)
          year = item.pay_period.pay_date.year
          pay_date = item.pay_period.pay_date.strftime("%Y%m%d")
          "paystubs/#{year}/#{item.employee_id}/paystub_#{pay_date}.pdf"
        end

        def existing_storage_key(item = @payroll_item, storage: nil)
          return nil unless r2_configured?

          storage ||= R2StorageService.new
          [ pay_stub_key(item), legacy_pay_stub_key(item) ].uniq.find do |key|
            storage.exists?(key)
          end
        rescue StandardError
          nil
        end

        def pay_stub_exists?
          existing_storage_key.present?
        end

        def combine_pdfs(pdf_binaries)
          require "combine_pdf"

          combined = CombinePDF.new
          pdf_binaries.each { |data| combined << CombinePDF.parse(data) }
          combined.to_pdf
        end

        def r2_configured?
          ENV["R2_ACCOUNT_ID"].present? &&
            ENV["R2_ACCESS_KEY_ID"].present? &&
            ENV["R2_SECRET_ACCESS_KEY"].present?
        end
      end
    end
  end
end
