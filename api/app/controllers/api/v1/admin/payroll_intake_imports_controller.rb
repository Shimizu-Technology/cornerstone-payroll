# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollIntakeImportsController < BaseController
        before_action :set_pay_period
        before_action :set_session, only: [ :show, :apply ]

        # GET /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports
        def index
          sessions = @pay_period.payroll_intake_sessions.includes(:documents, rows: :employee).recent_first
          render json: { imports: sessions.map { |session| session_json(session) } }
        end

        # GET /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports/:id
        def show
          render json: { import: session_json(@session) }
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports/preview
        def preview
          service = PayrollIntake::PreviewService.new(
            pay_period: @pay_period,
            source_type: params[:source_type].presence || "spike_email",
            pasted_text: params[:pasted_text],
            files: uploaded_files,
            actor: current_user
          )

          result = service.call
          render json: { import: session_json(result[:session]), duplicate: result[:duplicate] }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        rescue StandardError => e
          Rails.logger.error("Payroll intake preview failed: #{e.class}: #{e.message}")
          render json: { error: "Payroll intake preview failed. #{e.message}" }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports/:id/apply
        def apply
          results = PayrollIntake::ApplyService.new(
            session: @session,
            row_overrides: apply_params[:rows] || [],
            actor: current_user,
            force_overwrite: ActiveModel::Type::Boolean.new.cast(apply_params[:force_overwrite]),
            acknowledge_warnings: ActiveModel::Type::Boolean.new.cast(apply_params[:acknowledge_warnings])
          ).call

          status = results[:errors].any? ? :unprocessable_entity : :ok
          render json: {
            results: results,
            import: session_json(@session.reload),
            pay_period: pay_period_json(@pay_period.reload)
          }, status: status
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue StandardError => e
          Rails.logger.error("Payroll intake apply failed: #{e.class}: #{e.message}")
          render json: { error: "Payroll intake apply failed. #{e.message}" }, status: :unprocessable_entity
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.includes(:payroll_items).find(params[:pay_period_id])
          return if @pay_period.company_id == current_company_id

          render json: { error: "Pay period not found" }, status: :not_found and return
        end

        def set_session
          @session = @pay_period.payroll_intake_sessions.includes(:documents, rows: :employee).find(params[:id])
        end

        def uploaded_files
          Array(params[:files] || params[:attachments] || params[:file]).compact
        end

        def apply_params
          params.permit(
            :force_overwrite,
            :acknowledge_warnings,
            rows: [
              :id, :row_id, :position, :include, :employee_id,
              :week1_hours, :week2_hours, :regular_hours, :overtime_hours,
              :week1_tips, :week2_tips, :reported_tips, :tips_paid_out,
              :loan_deduction, :acknowledge_warnings
            ]
          )
        end

        def session_json(session)
          {
            id: session.id,
            company_id: session.company_id,
            pay_period_id: session.pay_period_id,
            source_type: session.source_type,
            source_label: session.source_label,
            status: session.status,
            import_hash: session.import_hash,
            parser_version: session.parser_version,
            warnings: session.warnings || [],
            totals: session.totals || {},
            error_message: session.error_message,
            duplicate: false,
            created_at: session.created_at,
            reviewed_at: session.reviewed_at,
            applied_at: session.applied_at,
            documents: session.documents.map { |document| document_json(document) },
            rows: session.rows.map { |row| row_json(row) }
          }
        end

        def document_json(document)
          {
            id: document.id,
            document_type: document.document_type,
            filename: document.filename,
            content_type: document.content_type,
            metadata: document.metadata || {},
            text_preview: document.text_content.to_s.truncate(500)
          }
        end

        def row_json(row)
          {
            id: row.id,
            position: row.position,
            status: row.status,
            excluded: row.excluded,
            source_employee_name: row.source_employee_name,
            employee_id: row.employee_id,
            employee_name: row.employee&.full_name,
            match_method: row.match_method,
            match_confidence: row.match_confidence&.to_f,
            confidence: row.confidence&.to_f,
            week1_hours: row.week1_hours.to_f,
            week2_hours: row.week2_hours.to_f,
            regular_hours: row.regular_hours.to_f,
            overtime_hours: row.overtime_hours.to_f,
            week1_tips: row.week1_tips.to_f,
            week2_tips: row.week2_tips.to_f,
            reported_tips: row.reported_tips.to_f,
            tips_paid_out: row.tips_paid_out.to_f,
            loan_deduction: row.loan_deduction.to_f,
            warnings: row.warnings || [],
            errors: row.errors_payload,
            source_payload: row.source_payload || {},
            staff_overrides: row.staff_overrides || {},
            applied_payroll_item_id: row.applied_payroll_item_id
          }
        end

        def pay_period_json(pay_period)
          {
            id: pay_period.id,
            company_id: pay_period.company_id,
            start_date: pay_period.start_date,
            end_date: pay_period.end_date,
            pay_date: pay_period.pay_date,
            status: pay_period.status,
            period_description: pay_period.period_description,
            payroll_intake_source_types: pay_period.company.payroll_intake_source_types,
            employee_count: pay_period.payroll_items.count,
            total_gross: pay_period.payroll_items.not_voided.sum(:gross_pay),
            total_net: pay_period.payroll_items.not_voided.sum(:net_pay),
            payroll_items: pay_period.payroll_items.includes(:employee, :payroll_item_field_entries).map { |item| payroll_item_json(item) }
          }
        end

        def payroll_item_json(item)
          {
            id: item.id,
            employee_id: item.employee_id,
            employee_name: item.employee_full_name,
            employment_type: item.employment_type,
            pay_rate: item.pay_rate,
            salary_override: item.salary_override,
            non_taxable_pay: item.non_taxable_pay,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            holiday_hours: item.holiday_hours,
            pto_hours: item.pto_hours,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            employer_social_security_tax: item.employer_social_security_tax,
            employer_medicare_tax: item.employer_medicare_tax,
            reported_tips: item.reported_tips,
            tips_paid_out: item.tips_paid_out,
            tips: item.tips,
            tip_pool: item.tip_pool,
            loan_deduction: item.loan_deduction,
            loan_payment: item.loan_payment,
            import_source: item.import_source,
            custom_earnings: item.custom_earnings || [],
            custom_deductions: item.custom_deductions || [],
            payroll_adjustments: item.payroll_adjustments || [],
            wage_rate_hours: item.wage_rate_hours,
            payroll_field_entries: item.payroll_item_field_entries.map do |entry|
              {
                id: entry.id,
                payroll_item_id: entry.payroll_item_id,
                payroll_field_definition_id: entry.payroll_field_definition_id,
                label: entry.label,
                kind: entry.kind,
                tax_treatment: entry.tax_treatment,
                category: entry.category,
                reporting_group: entry.reporting_group,
                amount: entry.amount.to_f,
                source: entry.source,
                employee_paid: entry.employee_paid,
                employer_paid: entry.employer_paid,
                active: entry.active,
                notes: entry.notes
              }
            end
          }
        end
      end
    end
  end
end
