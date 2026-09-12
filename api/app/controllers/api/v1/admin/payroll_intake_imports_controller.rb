# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollIntakeImportsController < BaseController
        before_action :set_pay_period
        before_action :set_session, only: [ :show, :apply, :download_source_document ]

        # GET /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports
        def index
          sessions = @pay_period.payroll_intake_sessions.includes(:documents, rows: :employee).recent_first
          render json: {
            imports: sessions.map { |session| session_json(session) },
            disposition_targets: disposition_targets_json
          }
        end

        # GET /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports/:id
        def show
          render json: { import: session_json(@session), disposition_targets: disposition_targets_json }
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports/preview
        def preview
          service = PayrollIntake::PreviewService.new(
            pay_period: @pay_period,
            source_type: params[:source_type].presence || "spike_email",
            pasted_text: params[:pasted_text],
            files: uploaded_files,
            actor: current_user,
            supersedes_package_id: params[:supersedes_package_id],
            supersession_reason: params[:supersession_reason]
          )

          result = service.call
          if result[:duplicate] && !result[:session].applyable?
            message = if result[:session].superseded?
              "This exact source belongs to a superseded revision. Continue with the current corrected package."
            else
              "This exact source package was already applied. Upload again only when the source changed."
            end
            return render json: { error: message }, status: :unprocessable_entity
          end
          render json: {
            import: session_json(result[:session]),
            duplicate: result[:duplicate],
            disposition_targets: disposition_targets_json
          }
        rescue PayrollIntake::PreviewService::ReplacementRequiredError => e
          render json: {
            error: e.message,
            details: { replacement_required: true, current_package: replacement_package_json(e.current_session) }
          }, status: :unprocessable_entity
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

        # GET /api/v1/admin/pay_periods/:pay_period_id/payroll_intake_imports/:id/documents/:document_id/download
        def download_source_document
          document = @session.documents.find(params[:document_id])
          if document.verification_status == "legacy_unverified"
            return render json: { error: "This legacy source predates verified package retention." }, status: :unprocessable_entity
          end

          bytes = PayrollIntake::SourcePackageVerifier.new(session: @session).verified_bytes!(document)
          AuditLog.record!(
            user: current_user,
            organization_id: @session.company.organization_id,
            company_id: @session.company_id,
            action: "payroll_intake_imports#download_source_document",
            record_type: "payroll_intake_sessions",
            record_id: @session.id,
            subject_name: @session.source_label,
            metadata: {
              package_id: @session.package_id,
              package_revision: @session.package_revision,
              document_id: document.id,
              source_role: document.source_role,
              sha256: document.sha256
            }
          )
          send_data bytes,
                    filename: document.filename.presence || "payroll-source-#{document.id}.txt",
                    type: document.content_type.presence || "text/plain",
                    disposition: "attachment"
        rescue PayrollIntake::SourcePackageVerifier::VerificationError => e
          render json: { error: e.message }, status: :unprocessable_entity
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
              :disposition, :disposition_reason, :target_pay_period_id,
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
            package_id: session.package_id,
            package_revision: session.package_revision,
            package_schema_version: session.package_schema_version,
            current: session.current?,
            superseded_at: session.superseded_at,
            supersedes_id: session.supersedes_id,
            supersedes_package_id: session.supersedes&.package_id,
            supersedes_revision: session.supersedes&.package_revision,
            supersession_reason: session.supersession_reason,
            replacement_package_id: session.replacement_session&.package_id,
            replacement_revision: session.replacement_session&.package_revision,
            evidence_snapshot: session.evidence_snapshot || {},
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
            source_role: document.source_role,
            position: document.position,
            filename: document.filename,
            content_type: document.content_type,
            byte_size: document.byte_size,
            sha256: document.sha256,
            verification_status: document.verification_status,
            verified_at: document.verified_at,
            metadata: document.metadata || {},
            text_preview: document.text_content.to_s.truncate(500),
            download_path: document.verification_status == "legacy_unverified" ? nil :
              "/api/v1/admin/pay_periods/#{document.payroll_intake_session.pay_period_id}/payroll_intake_imports/#{document.payroll_intake_session_id}/documents/#{document.id}/download"
          }
        end

        def row_json(row)
          {
            id: row.id,
            position: row.position,
            status: row.status,
            excluded: row.excluded,
            disposition: row.disposition,
            disposition_reason: row.disposition_reason,
            dispositioned_at: row.dispositioned_at,
            dispositioned_by_id: row.dispositioned_by_id,
            target_pay_period_id: row.target_pay_period_id,
            source_employee_name: row.source_employee_name,
            employee_id: row.employee_id,
            employee_name: row.employee&.full_name,
            match_method: row.match_method,
            match_confidence: row.match_confidence&.to_f,
            confidence: row.confidence&.to_f,
            week1_hours: row.week1_hours.to_f,
            week2_hours: row.week2_hours.to_f,
            extracted_total_hours: row.total_hours,
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

        def disposition_targets_json
          PayPeriod.where(company_id: @pay_period.company_id, cycle: "regular", correction_status: nil)
                   .where.not(id: @pay_period.id)
                   .where("start_date > ?", @pay_period.end_date)
                   .where.not(status: "committed")
                   .period_chronological
                   .map do |period|
            {
              id: period.id,
              label: "#{period.period_description} · pay #{period.pay_date.strftime('%m/%d/%Y')}",
              start_date: period.start_date,
              end_date: period.end_date,
              pay_date: period.pay_date
            }
          end
        end

        def replacement_package_json(session)
          {
            id: session.id,
            package_id: session.package_id,
            package_revision: session.package_revision,
            status: session.status,
            applied_at: session.applied_at,
            created_at: session.created_at
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
            intake_stale_at: pay_period.intake_stale_at,
            intake_stale_reason: pay_period.intake_stale_reason,
            intake_stale_session_id: pay_period.intake_stale_session_id,
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
