# frozen_string_literal: true

module Api
  module V1
    module Client
      class PayrollSubmissionPeriodsController < BaseController
        before_action :require_payroll_files, only: %i[submissions template]
        include PayrollSubmissionPeriodActions

        # GET /api/v1/client/payroll_submission_periods/:ref/template?file_format=xlsx|csv
        def template
          descriptor = payroll_catalog_company.portal_submittable_intake_descriptor
          file_format = (params[:file_format].presence || params[:format].presence || "xlsx").to_s.downcase

          case descriptor&.key
          when "cornerstone_workbook"
            unless file_format.in?(%w[xlsx csv])
              return render json: { error: "Unsupported template format '#{file_format}'. Use xlsx or csv." }, status: :unprocessable_entity
            end

            generator = PayrollIntake::UniversalWorkbook::Template.new(
              company: payroll_catalog_company,
              pay_period: payroll_catalog.live_pay_period(@entry),
              start_date: @entry.start_date,
              end_date: @entry.end_date,
              pay_date: payroll_catalog.pay_date_for(@entry)
            )
            payload = file_format == "csv" ? generator.generate_csv : generator.generate_xlsx
            send_data payload,
                      filename: generator.filename(format: file_format),
                      type: generator.content_type(format: file_format),
                      disposition: "attachment"
          when "mosa_revel"
            unless file_format == "xlsx"
              return render json: { error: "MoSa change workbook template is available in xlsx format only." }, status: :unprocessable_entity
            end

            pay_period = payroll_catalog.live_pay_period(@entry)
            unless pay_period
              return render json: { error: "This pay period is not ready for a change workbook download yet." }, status: :unprocessable_entity
            end

            generator = PayrollImport::MosaSupplementalTemplate.new(pay_period)
            send_data generator.generate,
                      filename: generator.filename,
                      type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                      disposition: "attachment"
          else
            render json: { error: "No downloadable payroll template is configured for this client." }, status: :unprocessable_entity
          end
        end

        # Send a new revision: descriptor-defined payroll files, changes, notes, attachments.
        def submissions
          skip_default_audit_log!
          portal_role_keys = (payroll_catalog_company.portal_submittable_intake_descriptor&.portal_roles || []).map(&:to_sym)
          permitted_keys = (%i[revel_payroll changes_workbook workbook_choice no_changes changes_link_url notes
                               idempotency_key based_on_revision excel_attachments_supporting] + portal_role_keys).uniq
          result = PayrollSubmissions::CreateRevision.new(
            company: payroll_catalog_company, actor: current_user, entry: @entry, catalog: payroll_catalog,
            params: params.permit(*permitted_keys, attachments: [], keep_document_ids: []).to_h.merge(changes: params[:changes]),
            request_context: payroll_request_context
          ).call
          @entry = payroll_catalog.resolve(result.submission.payroll_submission_period_id)
          render json: { data: payroll_serializer.detail(@entry), outcome: result.outcome },
            status: result.outcome == :created ? :created : :ok
        end

        # Approve the posted draft, or request a change with a note.
        def decision
          skip_default_audit_log!
          payroll_actions.decide!(saved_period!, decision: params[:decision], draft_id: params[:draft_id], note: params[:note])
          render_period
        rescue ActiveRecord::RecordNotFound => error
          Rails.logger.warn("[Client::PayrollSubmissionPeriodsController#decision] #{error.class}: #{error.message}")
          render json: { error: "Payroll period or draft not found" }, status: :not_found
        end
        private

        def require_payroll_files
          unless payroll_catalog_company.portal_payroll_files_enabled?
            render json: { error: "Payroll files are not enabled for this client" }, status: :forbidden
          end
        end
      end
    end
  end
end
