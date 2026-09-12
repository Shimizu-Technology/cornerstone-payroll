# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollImportsController < BaseController
        before_action :set_pay_period

        # GET /api/v1/admin/pay_periods/:pay_period_id/supplemental_template
        def supplemental_template
          unless @pay_period.company.payroll_intake_source_enabled?("mosa_revel")
            return render json: { error: "MoSa Revel intake is not enabled for this client" }, status: :unprocessable_entity
          end

          generator = PayrollImport::MosaSupplementalTemplate.new(@pay_period)
          send_data generator.generate,
                    filename: generator.filename,
                    type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    disposition: "attachment"
        end

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
            package_result = PayrollIntake::PreviewService.new(
              pay_period: @pay_period,
              source_type: "mosa_revel",
              files: [ pdf_file, excel_file ].compact,
              actor: current_user
            ).call
            source_package = package_result.fetch(:session)
            if package_result[:duplicate] && source_package.applied_at.present?
              return render json: {
                error: "This exact Revel package was already applied. Upload a corrected source only when something changed."
              }, status: :unprocessable_entity
            end

            preview_data = preview_from_source_package(source_package)
            tips_paid_out_from_tips = ActiveModel::Type::Boolean.new.cast(params[:tips_paid_out_from_tips])
            preview_data[:tips_paid_out_from_tips] = tips_paid_out_from_tips

            # Persist preview for later apply
            import_record = PayrollImportRecord.find_or_initialize_by(payroll_intake_session: source_package)
            import_record.assign_attributes(
              pay_period: @pay_period,
              status: "previewed",
              pdf_filename: pdf_file.original_filename,
              excel_filename: excel_file&.original_filename,
              raw_data: {
                pdf_count: preview_data[:pdf_count],
                excel_count: preview_data[:excel_count],
                tips_paid_out_from_tips: tips_paid_out_from_tips,
                unmatched_excel_names: preview_data[:unmatched_excel_names],
                duplicate_employee_matches: preview_data[:duplicate_employee_matches],
                low_confidence_matches: preview_data[:low_confidence_matches],
                package_id: source_package.package_id,
                package_revision: source_package.package_revision,
                package_schema_version: source_package.package_schema_version,
                source_document_count: source_package.documents.length
              },
              matched_data: preview_data[:matched],
              unmatched_pdf_names: preview_data[:unmatched_pdf_names]
            )
            import_record.save!

            render json: {
              import_id: import_record.id,
              preview: preview_data,
              source_package: source_package_json(source_package),
              duplicate: package_result[:duplicate]
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
            source_package = import_record.payroll_intake_session
            unless source_package
              return render json: { error: "This preview predates verified source retention. Preview the files again before applying." }, status: :unprocessable_entity
            end
            PayrollIntake::SourcePackageVerifier.new(session: source_package).verify!

            blocking_rows = source_package.rows.select(&:blocking_errors?)
            if blocking_rows.any?
              return render json: {
                error: "Resolve every blocked source row, then preview the corrected files again before applying.",
                details: {
                  blocked_rows: blocking_rows.map do |row|
                    {
                      source_employee_name: row.source_employee_name,
                      validation_errors: row.errors_payload
                    }
                  end
                }
              }, status: :unprocessable_entity
            end

            unresolved_names = import_record.unmatched_pdf_names.to_a + import_record.raw_data.to_h.fetch("unmatched_excel_names", []).to_a
            duplicate_matches = import_record.raw_data.to_h.fetch("duplicate_employee_matches", []).to_a

            if unresolved_names.any? || duplicate_matches.any?
              return render json: {
                error: "Resolve every unmatched or duplicate source row, then preview the files again before applying.",
                details: {
                  unmatched_names: unresolved_names,
                  duplicate_matches: duplicate_matches
                }
              }, status: :unprocessable_entity
            end

            low_confidence_matches = import_record.raw_data.to_h.fetch("low_confidence_matches", []).to_a
            acknowledged_low_confidence = ActiveModel::Type::Boolean.new.cast(params[:acknowledge_low_confidence_matches])
            if low_confidence_matches.any? && !acknowledged_low_confidence
              return render json: {
                error: "Review and confirm the suggested employee name matches before applying.",
                details: { low_confidence_matches: low_confidence_matches }
              }, status: :unprocessable_entity
            end

            service = PayrollImport::ImportService.new(@pay_period, actor: current_user)

            # The persisted server preview is authoritative. The browser may
            # exclude rows, but it cannot rewrite imported hours or money.
            excluded_employee_ids = Array(params[:excluded_employee_ids]).map(&:to_i).to_set
            matched_data = import_record.matched_data
              .map(&:deep_symbolize_keys)
              .reject { |row| excluded_employee_ids.include?(row[:employee_id].to_i) }

            if matched_data.empty?
              return render json: {
                error: "Keep at least one matched employee in the import.",
                details: { remaining_matched_rows: matched_data.length }
              }, status: :unprocessable_entity
            end

            force_overwrite = params[:force_overwrite].to_s == "true"
            tips_paid_out_from_tips = ActiveModel::Type::Boolean.new.cast(
              import_record.raw_data.to_h.fetch("tips_paid_out_from_tips", false)
            )
            results = nil
            applied = false
            ActiveRecord::Base.transaction do
              results = service.apply!(matched: matched_data, force_overwrite: force_overwrite, tips_paid_out_from_tips: tips_paid_out_from_tips)
              raise ActiveRecord::Rollback if results[:errors].any?

              import_record.update!(status: "applied", validation_errors: [])
              source_package.mark_reviewed!(actor: current_user) if source_package.status == "previewed"
              source_package.mark_applied!(actor: current_user)
              applied = true
            end

            unless applied
              import_record.update!(status: "previewed", validation_errors: results[:errors].map { |error| error[:error] })
              return render json: {
                error: "Nothing was imported because one or more payroll rows failed. Correct the listed rows and retry.",
                details: { row_errors: results[:errors] }
              }, status: :unprocessable_entity
            end

            render json: {
              results: results,
              pay_period: pay_period_json(@pay_period.reload)
            }
          rescue StandardError => e
            # Keep record previewed so operator can retry apply without re-uploading.
            import_record&.update(status: "previewed", validation_errors: [ e.message ])
            render json: { error: "Import apply failed. Import session is still previewed — retry apply or re-preview files. Details: #{e.message}" }, status: :unprocessable_entity
          end
        end

        private

        def preview_from_source_package(source_package)
          evidence = source_package.evidence_snapshot.to_h
          preview = evidence.fetch("preview", {})
          matched = source_package.rows.filter_map do |row|
            payload = row.source_payload.to_h
            payload["preview_row"] if payload["row_kind"] == "matched"
          end

          {
            matched: matched,
            unmatched_pdf_names: source_package.rows.filter_map do |row|
              row.source_employee_name if row.source_payload.to_h["row_kind"] == "unmatched_revel"
            end,
            unmatched_excel_names: source_package.rows.filter_map do |row|
              row.source_employee_name if row.source_payload.to_h["row_kind"] == "unmatched_workbook"
            end,
            duplicate_employee_matches: Array(preview["duplicate_employee_matches"]),
            low_confidence_matches: Array(preview["low_confidence_matches"]),
            pdf_count: preview["pdf_count"].to_i,
            excel_count: preview["excel_count"].to_i,
            matched_count: matched.length,
            source_warnings: source_package.warnings || [],
            can_apply: source_package.rows.none?(&:blocking_errors?) && Array(preview["duplicate_employee_matches"]).empty?
          }
        end

        def source_package_json(source_package)
          {
            id: source_package.id,
            package_id: source_package.package_id,
            package_revision: source_package.package_revision,
            package_schema_version: source_package.package_schema_version,
            verified_source_count: source_package.documents.count { |document| document.verification_status == "verified" },
            source_count: source_package.documents.length
          }
        end

        def set_pay_period
          @pay_period = PayPeriod.includes(:payroll_items).find(params[:pay_period_id] || params[:id])

          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found and return
          end
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
            employee_first_name: item.employee&.first_name,
            employee_last_name: item.employee&.last_name,
            employment_type: item.employment_type,
            contractor_pay_type: item.employee&.contractor_pay_type,
            pay_rate: item.pay_rate,
            salary_override: item.salary_override,
            non_taxable_pay: item.non_taxable_pay,
            bonus: item.bonus,
            bonus_source: item.bonus_source,
            imported_bonus: item.imported_bonus,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            additional_medicare_tax: item.additional_medicare_tax,
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
            import_source: item.import_source
          }
        end
      end
    end
  end
end
