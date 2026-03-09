# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollImportsController < BaseController
        before_action :set_pay_period

        # POST /api/v1/admin/pay_periods/:pay_period_id/preview_import
        # Upload PDF + optional Excel, get matched preview
        def preview
          unless @pay_period.can_edit?
            return render json: { error: "Cannot import into a committed pay period" }, status: :unprocessable_entity
          end

          pdf_file = params[:pdf_file]
          excel_file = params[:excel_file]

          unless pdf_file
            return render json: { error: "PDF file is required" }, status: :unprocessable_entity
          end

          begin
            service = PayrollImport::ImportService.new(@pay_period)
            preview_data = service.preview(pdf_file: pdf_file, excel_file: excel_file)

            # Persist preview for later apply
            import_record = PayrollImportRecord.create!(
              pay_period: @pay_period,
              status: "previewed",
              pdf_filename: pdf_file.original_filename,
              excel_filename: excel_file&.original_filename,
              raw_data: {
                pdf_count: preview_data[:pdf_count],
                excel_count: preview_data[:excel_count]
              },
              matched_data: preview_data[:matched],
              unmatched_pdf_names: preview_data[:unmatched_pdf_names]
            )

            render json: {
              import_id: import_record.id,
              preview: preview_data
            }
          rescue ArgumentError => e
            render json: { error: e.message }, status: :unprocessable_entity
          rescue StandardError => e
            render json: { error: "Failed to parse files: #{e.message}" }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/apply_import
        # Apply a previewed import
        def apply
          unless @pay_period.can_edit?
            return render json: { error: "Cannot import into a committed pay period" }, status: :unprocessable_entity
          end

          import_record = PayrollImportRecord.find_by(id: params[:import_id], pay_period_id: @pay_period.id)

          unless import_record&.status == "previewed"
            return render json: { error: "No valid preview found. Please preview again." }, status: :unprocessable_entity
          end

          begin
            service = PayrollImport::ImportService.new(@pay_period)

            # Allow overrides from frontend (e.g., removing employees or adjusting hours)
            matched_data = if params[:matched].present?
              params[:matched].map(&:to_unsafe_h)
            else
              import_record.matched_data.map(&:deep_symbolize_keys)
            end

            results = service.apply!(matched: matched_data)

            final_status = results[:errors].any? ? "partially_applied" : "applied"
            import_record.update!(
              status: final_status,
              validation_errors: results[:errors].map { |e| e[:error] }
            )

            render json: {
              results: results,
              pay_period: pay_period_json(@pay_period.reload)
            }
          rescue StandardError => e
            import_record&.update(status: "failed", validation_errors: [ e.message ])
            render json: { error: "Import failed: #{e.message}" }, status: :unprocessable_entity
          end
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.includes(:payroll_items).find(params[:pay_period_id])

          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found and return
          end
        end

        def pay_period_json(pay_period)
          {
            id: pay_period.id,
            start_date: pay_period.start_date,
            end_date: pay_period.end_date,
            pay_date: pay_period.pay_date,
            status: pay_period.status,
            period_description: pay_period.period_description,
            employee_count: pay_period.payroll_items.count,
            total_gross: pay_period.payroll_items.sum(:gross_pay),
            total_net: pay_period.payroll_items.sum(:net_pay),
            payroll_items: pay_period.payroll_items.includes(:employee).map { |item| payroll_item_json(item) }
          }
        end

        def payroll_item_json(item)
          {
            id: item.id,
            employee_id: item.employee_id,
            employee_name: item.employee_full_name,
            employment_type: item.employment_type,
            pay_rate: item.pay_rate,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            reported_tips: item.reported_tips,
            tips: item.tips,
            tip_pool: item.tip_pool,
            loan_deduction: item.loan_deduction,
            loan_payment: item.loan_payment,
            import_source: item.import_source
          }
        end
      end
    end
  end
end
