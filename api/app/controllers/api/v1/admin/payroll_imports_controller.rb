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

        # GET /api/v1/admin/pay_periods/:pay_period_id/current_import
        # Reopens the latest unapplied MoSa review without requiring another upload.
        def current
          source_package = @pay_period.payroll_intake_sessions.current
                                      .where(source_type: "mosa_revel", status: %w[previewed reviewed])
                                      .order(package_revision: :desc, id: :desc)
                                      .first
          import_record = PayrollImportRecord.find_by(
            pay_period: @pay_period,
            payroll_intake_session: source_package,
            status: "previewed"
          ) if source_package
          unless source_package && import_record
            return render json: { error: "There is no current MoSa import waiting for review." }, status: :not_found
          end

          preview_data = preview_from_source_package(source_package)
          preview_data[:tips_paid_out_from_tips] = ActiveModel::Type::Boolean.new.cast(
            import_record.raw_data.to_h.fetch("tips_paid_out_from_tips", false)
          )
          render json: {
            import_id: import_record.id,
            preview: preview_data,
            source_package: source_package_json(source_package),
            duplicate: false
          }
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
              actor: current_user,
              supersedes_package_id: params[:supersedes_package_id],
              supersession_reason: params[:supersession_reason]
            ).call
            source_package = package_result.fetch(:session)
            if package_result[:duplicate] && !source_package.applyable?
              message = if source_package.superseded?
                "This exact Revel package belongs to a superseded revision. Continue with the current corrected package."
              else
                "This exact Revel package was already applied. Upload a corrected source only when something changed."
              end
              return render json: {
                error: message
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
          rescue PayrollIntake::PreviewService::ReplacementRequiredError => e
            render json: {
              error: e.message,
              details: { replacement_required: true, current_package: replacement_package_json(e.current_session) }
            }, status: :unprocessable_entity
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
            unless source_package.applyable?
              return render json: {
                error: source_package.superseded? ?
                  "This source package was replaced by a corrected revision. Review and apply the current package." :
                  "Only the current previewed source package can be applied."
              }, status: :unprocessable_entity
            end
            PayrollIntake::SourcePackageVerifier.new(session: source_package).verify!

            disposition_plan = PayrollIntake::DispositionPlan.new(
              session: source_package,
              row_overrides: mosa_disposition_overrides(source_package),
              actor: current_user
            ).validate!
            included_decisions = disposition_plan.decisions.select(&:included?)

            validate_mosa_included_rows!(included_decisions)
            included_employee_ids = included_decisions.map { |decision| decision.row.employee_id }.compact.to_set

            low_confidence_matches = import_record.raw_data.to_h.fetch("low_confidence_matches", []).to_a
            low_confidence_matches = low_confidence_matches.select do |match|
              included_employee_ids.include?((match["employee_id"] || match[:employee_id]).to_i)
            end
            acknowledged_low_confidence = ActiveModel::Type::Boolean.new.cast(params[:acknowledge_low_confidence_matches])
            if low_confidence_matches.any? && !acknowledged_low_confidence
              return render json: {
                error: "Review and confirm the suggested employee name matches before applying.",
                details: { low_confidence_matches: low_confidence_matches }
              }, status: :unprocessable_entity
            end

            # The persisted server preview is authoritative. The browser may
            # exclude rows, but it cannot rewrite imported hours or money.
            matched_data = import_record.matched_data
              .map(&:deep_symbolize_keys)
              .select { |row| included_employee_ids.include?(row[:employee_id].to_i) }

            if included_decisions.any? && matched_data.empty?
              return render json: {
                error: "Keep at least one matched employee in the import.",
                details: { remaining_matched_rows: matched_data.length }
              }, status: :unprocessable_entity
            end

            force_overwrite = params[:force_overwrite].to_s == "true"
            tips_paid_out_from_tips = ActiveModel::Type::Boolean.new.cast(
              import_record.raw_data.to_h.fetch("tips_paid_out_from_tips", false)
            )
            results = { success: [], skipped: [], errors: [] }
            applied = false
            ActiveRecord::Base.transaction do
              if matched_data.any?
                service = PayrollImport::ImportService.new(@pay_period, actor: current_user)
                results = service.apply!(matched: matched_data, force_overwrite: force_overwrite, tips_paid_out_from_tips: tips_paid_out_from_tips)
              end
              raise ActiveRecord::Rollback if results[:errors].any?

              import_record.update!(status: "applied", validation_errors: [])
              disposition_plan.decisions.each do |decision|
                if decision.included?
                  payroll_item = @pay_period.payroll_items.find_by!(employee_id: decision.row.employee_id)
                  disposition_plan.apply!(
                    decision,
                    status: "applied",
                    employee: decision.row.employee,
                    payroll_item: payroll_item
                  )
                else
                  disposition_plan.apply!(decision, status: "skipped")
                  results[:skipped] << {
                    employee_id: decision.row.employee_id,
                    name: decision.row.source_employee_name,
                    reason: decision.reason
                  }
                end
              end
              source_package.mark_reviewed!(actor: current_user) if source_package.status == "previewed"
              source_package.mark_applied!(actor: current_user)
              @pay_period.clear_intake_stale! if @pay_period.intake_stale_session_id == source_package.id
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
          rescue ArgumentError => e
            import_record&.update(status: "previewed", validation_errors: [ e.message ])
            render json: { error: e.message }, status: :unprocessable_entity
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
            payload["preview_row"].to_h.merge("source_row_id" => row.id) if payload["row_kind"] == "matched"
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
            source_rows: source_package.rows.map { |row| source_row_json(row) },
            can_apply: source_package.rows.none?(&:blocking_errors?) && Array(preview["duplicate_employee_matches"]).empty?
          }
        end

        def source_package_json(source_package)
          {
            id: source_package.id,
            package_id: source_package.package_id,
            package_revision: source_package.package_revision,
            package_schema_version: source_package.package_schema_version,
            current: source_package.current?,
            superseded_at: source_package.superseded_at,
            supersedes_package_id: source_package.supersedes&.package_id,
            supersedes_revision: source_package.supersedes&.package_revision,
            supersession_reason: source_package.supersession_reason,
            replacement_package_id: source_package.replacement_session&.package_id,
            replacement_revision: source_package.replacement_session&.package_revision,
            verified_source_count: source_package.documents.count { |document| document.verification_status == "verified" },
            source_count: source_package.documents.length,
            disposition_targets: disposition_targets_json
          }
        end

        def source_row_json(row)
          {
            id: row.id,
            position: row.position,
            source_employee_name: row.source_employee_name,
            employee_id: row.employee_id,
            employee_name: row.employee&.full_name,
            row_kind: row.source_payload.to_h["row_kind"],
            disposition: row.disposition,
            disposition_reason: row.disposition_reason,
            target_pay_period_id: row.target_pay_period_id,
            errors: row.errors_payload,
            warnings: row.warnings_payload
          }
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

        def mosa_disposition_overrides(source_package)
          submitted = params.permit(rows: [ :id, :row_id, :position, :disposition, :disposition_reason, :target_pay_period_id ])[:rows]
          return submitted if submitted.present?

          excluded_ids = Array(params[:excluded_employee_ids]).map(&:to_i).to_set
          source_package.rows.map do |row|
            if row.source_payload.to_h["row_kind"] == "matched"
              excluded = excluded_ids.include?(row.employee_id)
              {
                id: row.id,
                disposition: excluded ? "excluded" : "included",
                disposition_reason: excluded ? "Excluded through the legacy reviewed import control." : nil
              }
            else
              { id: row.id, disposition: "pending" }
            end
          end
        end

        def validate_mosa_included_rows!(decisions)
          duplicate_ids = decisions.filter_map { |decision| decision.row.employee_id }.tally.select { |_id, count| count > 1 }.keys
          excluded_ids = @pay_period.pay_period_excluded_employees.pluck(:employee_id).to_set
          errors = decisions.flat_map do |decision|
            row = decision.row
            messages = []
            messages << "#{row.source_employee_name} must be matched to a Cornerstone employee or given a non-payroll outcome." if row.employee.blank?
            if excluded_ids.include?(row.employee_id)
              messages << "#{row.source_employee_name} is excluded from this pay period; choose Excluded and record why."
            end
            row.errors_payload.each do |payload|
              code = (payload["code"] || payload[:code]).to_s
              next if code == "duplicate_employee" && !duplicate_ids.include?(row.employee_id)

              messages << (payload["message"] || payload[:message] || "Resolve the retained source-row error.")
            end
            messages
          end
          if duplicate_ids.any?
            errors << "Multiple included source rows map to the same employee. Exclude, defer, or mark the extra row informational."
          end
          raise ArgumentError, errors.uniq.join(" ") if errors.any?
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
            intake_stale_at: pay_period.intake_stale_at,
            intake_stale_reason: pay_period.intake_stale_reason,
            intake_stale_session_id: pay_period.intake_stale_session_id,
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
