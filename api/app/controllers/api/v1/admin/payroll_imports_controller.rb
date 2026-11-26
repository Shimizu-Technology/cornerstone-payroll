# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollImportsController < BaseController
        before_action :set_pay_period
        around_action :with_import_lock, only: %i[preview rematch remove_source tip_treatment installment_loan apply resolve_portal_source]

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
          source_package = PayrollImport::CurrentReview.source_package_for(@pay_period)
          import_record = PayrollImport::CurrentReview.import_record_for(@pay_period, source_package)
          unless source_package && import_record
            return render json: { error: "There is no current MoSa import waiting for review." }, status: :not_found
          end

          render json: preview_response(import_record, { session: source_package, duplicate: false })
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/preview_import
        # Upload the Revel PDF, the change workbook, or both. Files already in
        # the current package are kept, so the other file can be added later.
        def preview
          unless @pay_period.can_edit?
            return render json: { error: "Cannot import into a committed pay period" }, status: :unprocessable_entity
          end

          return preview_portal_submission if params[:submission_id].present?

          pdf_file = params[:pdf_file]
          excel_file = params[:excel_file]

          unless pdf_file || excel_file
            return render json: { error: "Choose the Revel hours PDF, the tips & loans workbook, or both." }, status: :unprocessable_entity
          end

          begin
            selected_source = pay_run_selection.source! if params[:use_submission_id].present?
            package_result = PayrollIntake::PreviewService.new(
              pay_period: @pay_period,
              source_type: "mosa_revel",
              files: [ pdf_file, excel_file ].compact,
              actor: current_user,
              portal_submission: selected_source,
              supersedes_package_id: params[:supersedes_package_id],
              supersession_reason: params[:supersession_reason],
              carry_forward: true
            ).call
            source_package = package_result.fetch(:session)
            if package_result[:duplicate] && !source_package.applyable?
              message = if source_package.superseded?
                "This exact Revel package belongs to a superseded revision. Continue with the current corrected package."
              else
                "This exact Revel package was already applied. Upload a corrected source only when something changed."
              end
              return render json: {
                error: message,
                details: { pending_submission_id: pending_portal_source_json&.fetch(:submission_id),
                  pending_revision: pending_portal_source_json&.fetch(:revision) }
              }, status: :unprocessable_entity
            end

            # The upload step shows the tip fallback beside the workbook it uploads.
            import_record = persist_preview(package_result, pdf_file, excel_file,
              tip_choice_offered: excel_file.present? && params.key?(:tips_paid_out_from_tips),
              portal_submission: selected_source)
            render json: preview_response(import_record, package_result)
          rescue PayrollIntake::PreviewService::ReplacementRequiredError => e
            render json: {
              error: e.message,
              details: { replacement_required: true, current_package: replacement_package_json(e.current_session) }
            }, status: :unprocessable_entity
          rescue ArgumentError => e
            render json: { error: e.message }, status: :unprocessable_entity
          rescue StandardError => e
            Rails.logger.error("[PayrollImportsController#preview] #{e.class}: #{e.message}")
            render json: { error: "Failed to parse files. Check the uploaded files and try again." }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/rematch_import
        # Matches the current review's retained files again, for example after
        # a worker it names was reactivated or a loan was set up. No upload or
        # reason is needed; an optional reason is recorded on the new version.
        # An unchanged roster and loan setup return the same review.
        def rematch
          unless @pay_period.can_edit?
            return render json: { error: "Cannot import into a committed pay period" }, status: :unprocessable_entity
          end

          current = PayrollImport::CurrentReview.source_package_for(@pay_period)
          current_record = PayrollImport::CurrentReview.import_record_for(@pay_period, current)
          unless current&.applyable? && current_record
            return render json: { error: "Only an import still in review can be matched again. Upload corrected files instead." }, status: :unprocessable_entity
          end
          if current_record.submission_imports.exists?
            return render json: { error: "Open the client revision again to match its files with the current employee list." }, status: :unprocessable_entity
          end

          package_result = PayrollIntake::PreviewService.new(
            pay_period: @pay_period, source_type: "mosa_revel", files: [], actor: current_user, carry_forward: true,
            supersession_reason: params[:reason].to_s.strip.first(500).presence
          ).call
          # A tip choice follows the workbook it was made for (see tip_confirmation_for).
          import_record = persist_preview(package_result, nil, nil, tips_paid_out_from_tips: false)
          render json: preview_response(import_record, package_result)
        rescue PayrollIntake::PreviewService::ReplacementRequiredError, ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue StandardError => e
          Rails.logger.error("[PayrollImportsController#rematch] #{e.class}: #{e.message}")
          render json: { error: "Could not match the files again. Try again or contact support." }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/remove_import_source
        # Takes one file out of an import still in review, for example a
        # workbook added by mistake. The other files are kept and matched
        # again, and the reason is recorded on the new import version.
        def remove_source
          unless @pay_period.can_edit?
            return render json: { error: "Cannot import into a committed pay period" }, status: :unprocessable_entity
          end

          current = PayrollImport::CurrentReview.source_package_for(@pay_period)
          current_record = PayrollImport::CurrentReview.import_record_for(@pay_period, current)
          unless current&.applyable? && current_record
            return render json: { error: "Only an import still in review can have a file removed." }, status: :unprocessable_entity
          end
          if current_record.submission_imports.exists?
            return render json: { error: "Files from a client revision can't be removed here. Open the client revision again instead." }, status: :unprocessable_entity
          end

          role = params[:source_role].to_s
          label = PayrollIntake::SourceCompleteness.new(session: current, company: @pay_period.company).labels_for([ role ]).first
          verified = current.documents.select { |document| document.verification_status == "verified" }
          unless role.in?(PayrollIntake::SourceCompleteness.roles_for("mosa_revel").keys) && verified.any? { |document| document.source_role == role }
            return render json: { error: "Import version #{current.package_revision} has no #{label} to remove." }, status: :unprocessable_entity
          end
          if verified.all? { |document| document.source_role == role }
            return render json: { error: "The #{label} is the only file in this import. Upload the corrected file instead." }, status: :unprocessable_entity
          end
          reason = params[:reason].to_s.strip
          if reason.blank? || reason.length > 500
            return render json: { error: "Say why the #{label} is being removed (up to 500 characters)." }, status: :unprocessable_entity
          end

          package_result = PayrollIntake::PreviewService.new(
            pay_period: @pay_period, source_type: "mosa_revel", files: [], actor: current_user, carry_forward: true,
            remove_roles: [ role ], supersedes_package_id: current.package_id, supersession_reason: "Removed: #{label}. #{reason}"
          ).call
          # A tip choice follows the workbook it was made for (see tip_confirmation_for).
          import_record = persist_preview(package_result, nil, nil, tips_paid_out_from_tips: false)
          render json: preview_response(import_record, package_result)
        rescue PayrollIntake::PreviewService::ReplacementRequiredError, ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue StandardError => e
          Rails.logger.error("[PayrollImportsController#remove_source] #{e.class}: #{e.message}")
          render json: { error: "Could not remove the file. Try again or contact support." }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/import_tip_treatment
        # Records how the tips in an older MoSa workbook were paid, on the
        # review itself. Apply uses only this saved choice, never one sent with apply.
        def tip_treatment
          unless @pay_period.can_edit?
            return render json: { error: "Cannot import into a committed pay period" }, status: :unprocessable_entity
          end

          current = PayrollImport::CurrentReview.source_package_for(@pay_period)
          import_record = PayrollImport::CurrentReview.import_record_for(@pay_period, current)
          unless current&.applyable? && import_record && import_record.id.to_s == params[:import_id].to_s
            return render json: { error: "This review is no longer current. Reopen the current import." }, status: :unprocessable_entity
          end
          unless legacy_workbook?(current)
            return render json: { error: "Only an older MoSa workbook needs this choice." }, status: :unprocessable_entity
          end
          unless params.key?(:tips_paid_out_from_tips)
            return render json: { error: "Choose whether the tips were already paid out daily." }, status: :unprocessable_entity
          end

          paid = ActiveModel::Type::Boolean.new.cast(params[:tips_paid_out_from_tips])
          import_record.update!(raw_data: import_record.raw_data.to_h.merge(
            "tips_paid_out_from_tips" => paid,
            "tip_treatment_confirmed" => { "source" => "review", "user_id" => current_user.id, "at" => Time.current.iso8601 }
          ))
          render json: preview_response(import_record, { session: current, duplicate: false })
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/import_installment_loan
        # Sets up, or resumes, the Employee Loan for an installment the current
        # review found in the workbook, with the same rules and access as the
        # Employee Loans screen. The browser then matches the files again so
        # the review reconciles. A repeat request never creates a second loan.
        def installment_loan
          skip_default_audit_log!
          unless @pay_period.can_edit?
            return render json: { error: "Cannot import into a committed pay period" }, status: :unprocessable_entity
          end
          access = loan_setup_access
          return render json: { error: access[:reason] }, status: :forbidden unless access[:allowed]

          current = PayrollImport::CurrentReview.source_package_for(@pay_period)
          import_record = PayrollImport::CurrentReview.import_record_for(@pay_period, current)
          unless current&.applyable? && import_record && import_record.id.to_s == params[:import_id].to_s
            return render json: { error: "This review is no longer current. Reopen the current import." }, status: :unprocessable_entity
          end
          row = import_record.matched_data.find { |candidate| candidate["employee_id"].to_s == params[:employee_id].to_s }
          offer = row && row["installment_loan_setup"].to_h
          employee = row && Employee.find_by(id: row["employee_id"], company_id: @pay_period.company_id)
          unless employee && offer.present?
            return render json: { error: "This review has no installment loan to set up for that worker. Reload the review." }, status: :unprocessable_entity
          end
          unless employee.active?
            return render json: { error: "#{employee.full_name} isn't active. Reactivate them before setting up the loan." }, status: :unprocessable_entity
          end

          # Its own savepoint: a failed setup leaves no partial loan behind.
          employee.with_lock(requires_new: true) do
            open_loans = employee.employee_loans.where(tracking_mode: "balance_tracked", status: %w[active suspended]).order(:id).to_a
            if offer["action"] == "resume"
              loan = open_loans.find { |candidate| candidate.id.to_s == offer["employee_loan_id"].to_s }
              raise ArgumentError, "#{offer['name']} is no longer paused or open in Employee Loans. Reload the review." unless loan
              if loan.active?
                next render(json: { loan_id: loan.id, already_set_up: true })
              end

              loan.reactivate!(notes: "Resumed from payroll import review for pay date #{@pay_period.pay_date.iso8601}.")
              record_loan_audit!("employee_loans#reactivate", loan, offer)
              next render(json: { loan_id: loan.id, already_set_up: false })
            end

            # Someone already set it up, for example from another window.
            existing = open_loans.find { |candidate| candidate.active? && candidate.repayment_schedule_active_on?(@pay_period.pay_date) }
            next render(json: { loan_id: existing.id, already_set_up: true }) if existing
            if open_loans.any?
              raise ArgumentError, "#{employee.full_name} already has #{open_loans.map(&:name).to_sentence} in Employee Loans. Review it there instead of adding another loan."
            end
            if offer["beginning_balance"].to_d.positive? && employee.employee_loans.exists?(tracking_mode: "balance_tracked", status: "paid_off")
              raise ArgumentError, "#{employee.full_name}'s installment loan was paid off in Employee Loans. Check the workbook with the client instead of adding another loan."
            end

            attributes, advance = installment_loan_attributes(offer)
            loan = EmployeeLoanSetupService.new(company: @pay_period.company, actor: current_user).create!(
              employee: employee, attributes: attributes, schedule_kind: "new",
              setup_mode: attributes.key?(:opening_balance) ? "existing_balance" : "new_loan"
            )
            # The workbook's new advance is its own ledger entry, as Record
            # addition on the Employee Loans screen makes it.
            if advance
              loan.record_addition!(amount: advance, date: loan.balance_as_of, recorded_by: current_user,
                notes: "New advance from the tips & loans workbook (pay date #{@pay_period.pay_date.iso8601}).")
            end
            record_loan_audit!("employee_loans#create", loan.reload, offer)
            render json: { loan_id: loan.id, already_set_up: false }, status: :created
          end
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "This loan schedule was linked by another update. Reload the review and try again." }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
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
            import_record.lock!
            raise ArgumentError, "This import was already applied. Reopen the current review." unless import_record.status == "previewed"
            raise ArgumentError, "Unapprove this pay run before applying an import" if @pay_period.approved?
            selection = import_record.submission_imports.find_by(id: params[:portal_source_id])
            if import_record.submission_imports.exists? && !selection
              raise ArgumentError, "Reopen the portal submission in import review to confirm its source revision"
            end
            if params[:portal_source_id].present? && !selection
              raise ArgumentError, "Portal source selection does not belong to this import"
            end
            if params[:use_submission_id].present?
              raise ArgumentError, "This import already has a portal source" if selection || import_record.submission_imports.exists?

              selection = pay_run_selection!(import_record)
            end
            if selection
              selection.period.lock! unless selection.new_record?
              selection.validate_current!
            elsif @pay_period.pending_portal_submission?
              raise ArgumentError, "Open the pending portal revision in import review or record a source disposition first"
            end
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
            revision_id = source_package.evidence_snapshot["payroll_submission_id"]
            if revision_id && selection&.payroll_submission_id != revision_id
              raise ArgumentError, "Select the client revision used to create this replacement review."
            end
            PayrollIntake::SourcePackageVerifier.new(session: source_package).verify!
            source_waivers = source_waivers_for!(source_package, selection)

            disposition_plan = PayrollIntake::DispositionPlan.new(
              session: source_package,
              row_overrides: mosa_disposition_overrides(source_package),
              actor: current_user
            ).validate!
            included_decisions = disposition_plan.decisions.select(&:included?)

            client_changes = PayrollSubmissions::ImportChanges.new(submission: selection.payroll_submission, pay_period: @pay_period) if selection
            validate_mosa_included_rows!(included_decisions, restorable_owner_ids: client_changes&.restorable_owner_ids || [])
            included_employee_ids = included_decisions.map { |decision| decision.row.employee_id }.compact.to_set

            low_confidence_matches = import_record.raw_data.to_h.fetch("low_confidence_matches", []).to_a
            low_confidence_matches = low_confidence_matches.select do |match|
              included_employee_ids.include?((match["employee_id"] || match[:employee_id]).to_i)
            end
            hand_edited = included_hand_edited_hours(import_record, included_employee_ids)
            if hand_edited.any? && !ActiveModel::Type::Boolean.new.cast(params[:confirm_hours_overwrite])
              return render json: {
                error: "Revel hours would replace hours entered by hand for #{hand_edited.map { |row| row['employee_name'] }.to_sentence}. Review and confirm before applying.",
                details: { hand_edited_hours: hand_edited }
              }, status: :unprocessable_entity
            end

            acknowledged_low_confidence = ActiveModel::Type::Boolean.new.cast(params[:acknowledge_low_confidence_matches])
            if low_confidence_matches.any? && !acknowledged_low_confidence
              return render json: {
                error: "Review and confirm the suggested employee name matches before applying.",
                details: { low_confidence_matches: low_confidence_matches }
              }, status: :unprocessable_entity
            end

            # The persisted server preview is authoritative. The browser may
            # exclude rows and select a saved job, but cannot rewrite hours or money.
            matched_data = import_record.matched_data
              .map(&:deep_symbolize_keys)
              .select { |row| included_employee_ids.include?(row[:employee_id].to_i) }

            rate_choices = params.permit(wage_rate_choices: {}).to_h.fetch("wage_rate_choices", {})
            matched_data.each do |row|
              next unless rate_choices.key?(row[:employee_id].to_s)

              id = rate_choices.fetch(row[:employee_id].to_s).to_s
              unless Array(row[:wage_rate_options]).any? { |option| option[:id].to_s == id }
                raise ArgumentError, "Choose a job and rate from this employee's saved rates. Preview again if rates changed."
              end
              row[:selected_wage_rate_id] = id.to_i
              row[:wage_rate_needs_review] = false
            end

            if selection
              matched_data = client_changes.apply_to(matched_data, reviewed: params.permit(reviewed_changes: [ :change_index, :amount, :hours, :decision, :reason, :pay_choice, :saved_period_pay, :workbook_period_pay ])[:reviewed_changes],
                  confirmed: params[:confirm_client_changes], dispositions: disposition_plan.decisions, source_employee_ids: import_record.matched_data.map { |row| row["employee_id"] })
            end

            unpaid_owners = client_changes&.unpaid_owners || {}
            matched_data.reject! { |row| unpaid_owners.key?(row[:employee_id].to_i) }
            if included_decisions.any? { |decision| !unpaid_owners.key?(decision.row.employee_id) } && matched_data.empty?
              return render json: {
                error: "Keep at least one matched employee in the import.",
                details: { remaining_matched_rows: matched_data.length }
              }, status: :unprocessable_entity
            end

            force_overwrite = params[:force_overwrite].to_s == "true"
            tips_paid_out_from_tips = tip_treatment_for!(source_package, import_record)
            results = { success: [], skipped: [], errors: [] }
            applied = false
            ActiveRecord::Base.transaction(requires_new: true) do
              # This selection resolves the pending-source gate only inside the
              # same transaction as successful calculation/apply. Any failure
              # rolls it back along with every payroll row and status event.
              selection.period.save! if selection && selection.period.changed?
              selection&.save! if selection&.new_record?
              selection&.update!(applied_at: Time.current)
              client_changes&.apply_period_decisions!(actor: current_user)
              if matched_data.any?
                service = PayrollImport::ImportService.new(@pay_period, actor: current_user)
                results = service.apply!(matched: matched_data, force_overwrite: force_overwrite, tips_paid_out_from_tips: tips_paid_out_from_tips)
              end
              raise ActiveRecord::Rollback if results[:errors].any?

              import_record.update!(status: "applied", validation_errors: [],
                import_origin: PayrollIntake::ImportOrigin.build(
                  session: source_package,
                  portal_submission: selection&.payroll_submission,
                  replaced_hand_edited_hours: hand_edited.any?
                ),
                raw_data: import_record.raw_data.to_h.merge("client_change_decisions" => client_changes&.review_decisions || [],
                  "source_waivers" => source_waivers, "replaced_hand_edited_hours" => hand_edited))
              disposition_plan.decisions.each do |decision|
                if decision.included? && unpaid_owners.key?(decision.row.employee_id)
                  decision.disposition = "excluded"
                  decision.reason = unpaid_owners[decision.row.employee_id]
                end
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
              if selection
                period = selection.period
                # Keep Imported tied to the actual selected revision; choosing
                # an old source does not label the newer files as imported.
                review_notes = client_changes.review_decisions.select { |row| %w[decline no_pay stale_none].include?(row[:decision]) }
                  .map do |row|
                    next row[:reason] if row[:decision] == "stale_none"

                    "#{row[:employee_name] || 'Missing employee'}: #{row[:decision] == 'no_pay' ? 'No pay this period' : "Don't apply"} — #{row[:reason]}"
                  end
                period.transition!("import", actor: current_user,
                  submission: selection.payroll_submission, note: ([ "Imported revision #{selection.payroll_submission.revision} into payroll review." ] + review_notes).join(" "))
                PayrollSubmissions::Audit.record!(actor: current_user, period: period, action: "payroll_submission_periods#import",
                  metadata: { pay_period_id: @pay_period.id, submission_id: selection.payroll_submission_id, current_submission_id: selection.current_submission_id,
                    superseded_reason: selection.superseded_reason, source_route: selection.source_route,
                    staff_workbook_document_id: selection.staff_workbook_document_id,
                    client_change_decisions: client_changes.review_decisions,
                    import_id: import_record.id, source_package_id: source_package.id })
                PortalNotifications.payroll_period!("payroll_submission_imported", period: period, actor: current_user,
                  dedupe: "import:#{import_record.id}", metadata: { submission_id: selection.payroll_submission_id, revision: selection.payroll_submission.revision })
              end
              applied = true
            end

            unless applied
              import_record.update!(status: "previewed", validation_errors: results[:errors].map { |error| error[:error] })
              return render json: {
                error: "Nothing was imported because one or more payroll rows failed. Correct the listed rows and retry.",
                details: { row_errors: results[:errors] }
              }, status: :unprocessable_entity
            end

            @audit_import_record = import_record
            @audit_import_results = results
            render json: {
              results: results,
              client_change_decisions: client_changes&.review_decisions || [],
              manual_review_warnings: client_changes&.manual_review_warnings || [],
              pay_period: pay_period_json(@pay_period.reload)
            }
          rescue ArgumentError, PayrollIntake::SourcePackageVerifier::VerificationError => e
            import_record&.update(status: "previewed", validation_errors: [ e.message ])
            render json: { error: e.message }, status: :unprocessable_entity
          rescue StandardError => e
            Rails.logger.error("[PayrollImportsController#apply] #{e.class}: #{e.message}")
            # Keep record previewed so operator can retry apply without re-uploading.
            import_record&.update(status: "previewed", validation_errors: [ "Import apply failed unexpectedly." ])
            render json: { error: "Import apply failed. Import session is still previewed — retry apply or re-preview files." }, status: :unprocessable_entity
          end
        end

        def resolve_portal_source
          skip_default_audit_log!
          period = PayrollSubmissionPeriod.lock.find_by!(company_id: @pay_period.company_id, start_date: @pay_period.start_date, end_date: @pay_period.end_date)
          unless period.pay_period_id == @pay_period.id
            return render json: { error: "This portal period is not linked to this pay run. Open it in import review for its matching regular run first." }, status: :unprocessable_entity
          end
          source = period.submissions.first
          reason = params[:reason].to_s.strip
          unless source && source.id.to_s == params[:submission_id].to_s && reason.present? && reason.length <= 2000
            return render json: { error: "Choose the current portal revision and explain why it will not be imported (up to 2,000 characters)." }, status: :unprocessable_entity
          end
          period.transition!("resolve_source", actor: current_user, submission: source, note: reason)
          PayrollSubmissions::Audit.record!(actor: current_user, period: period, action: "payroll_submission_periods#resolve_source",
            metadata: { pay_period_id: @pay_period.id, submission_id: source.id, revision: source.revision, reason: reason })
          render json: { resolved_submission_id: source.id }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Portal period not found" }, status: :not_found
        end

        private

        def preview_portal_submission
          skip_default_audit_log!
          PayrollSubmissions::ImportBridge.new(pay_period: @pay_period, actor: current_user, submission_id: params[:submission_id],
            superseded_reason: params[:superseded_reason], supersedes_package_id: params[:supersedes_package_id],
            supersession_reason: params[:supersession_reason], staff_workbook: params[:staff_workbook]).call do |result, submission, current, reason, files, carried_staff|
            record = persist_preview(result, files.first, files.second, portal_submission: submission)
            selection = record.submission_imports.find_or_create_by!(payroll_submission: submission, current_submission: current) do |link|
              link.selected_by = current_user
              link.superseded_reason = reason
              if params[:staff_workbook].present? || carried_staff
                # A carried workbook keeps who attached it and when.
                link.staff_workbook_document = record.payroll_intake_session.documents.find_by!(source_role: "supplemental_workbook")
                link.staff_workbook_attached_by = carried_staff&.staff_workbook_attached_by || current_user
                link.staff_workbook_attached_at = carried_staff&.staff_workbook_attached_at || Time.current
              end
            end
            PayrollSubmissions::Audit.record!(actor: current_user, period: submission.period, action: "payroll_submissions#open_import",
              metadata: { pay_period_id: @pay_period.id, submission_id: submission.id, revision: submission.revision, current_submission_id: current.id,
                superseded_reason: reason, import_id: record.id, duplicate: result[:duplicate],
                staff_workbook_document_id: selection.staff_workbook_document_id,
                staff_workbook_sha256: selection.staff_workbook_document&.sha256 })
            render json: preview_response(record, result, selection: selection)
          end
        rescue PayrollIntake::PreviewService::ReplacementRequiredError => e
          render json: { error: e.message, details: { replacement_required: true, current_package: replacement_package_json(e.current_session) } }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Portal submission not found for this company and period" }, status: :not_found
        rescue ArgumentError, PayrollIntake::SourcePackageVerifier::VerificationError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue StandardError => e
          Rails.logger.error("[PayrollImportsController#preview_portal_submission] #{e.class}: #{e.message}")
          render json: { error: "Could not open this portal submission for import review. Try again or contact support." }, status: :unprocessable_entity
        end

        def persist_preview(package_result, pdf_file, excel_file,
                            tips_paid_out_from_tips: ActiveModel::Type::Boolean.new.cast(params[:tips_paid_out_from_tips]),
                            tip_choice_offered: false,
                            portal_submission: nil)
          source_package = package_result.fetch(:session)
          unless source_package.applyable?
            raise ArgumentError, "This source package was already applied or superseded. Review a corrected current source."
          end
          preview_data = preview_from_source_package(source_package)
          tip_confirmation = tip_confirmation_for(source_package, tips_paid_out_from_tips, offered: tip_choice_offered)
          tips_paid_out_from_tips = tip_confirmation.fetch("tips_paid_out_from_tips")
          preview_data[:tips_paid_out_from_tips] = tips_paid_out_from_tips

          # Persist preview for later apply
          import_record = PayrollImportRecord.find_or_initialize_by(payroll_intake_session: source_package)
          return import_record if import_record.persisted? && package_result[:duplicate]
          import_record.assign_attributes(
            pay_period: @pay_period,
            company_id: @pay_period.company_id,
            status: "previewed",
            pdf_filename: retained_filename(source_package, "revel_hours") || pdf_file&.original_filename,
            excel_filename: retained_filename(source_package, "supplemental_workbook") || excel_file&.original_filename,
            import_origin: PayrollIntake::ImportOrigin.build(session: source_package, portal_submission: portal_submission),
            raw_data: {
              pdf_count: preview_data[:pdf_count],
              excel_count: preview_data[:excel_count],
              tips_paid_out_from_tips: tips_paid_out_from_tips,
              tip_treatment_confirmed: tip_confirmation["tip_treatment_confirmed"],
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

          import_record
        end

        def preview_response(import_record, package_result, selection: nil)
          @audit_import_record = import_record
          source_package = package_result.fetch(:session)
          preview = preview_from_source_package(source_package)
          preview[:tips_paid_out_from_tips] = ActiveModel::Type::Boolean.new.cast(import_record.raw_data.to_h["tips_paid_out_from_tips"])
          preview[:tip_treatment_confirmed] = import_record.raw_data.to_h["tip_treatment_confirmed"].present?
          selection ||= import_record.submission_imports.order(id: :desc).first
          source = selection&.payroll_submission || pending_portal_period&.current_submission
          preview[:source_warnings] += workbook_warnings(source_package, source)
          {
            import_id: import_record.id, preview: preview, source_package: source_package_json(source_package),
            pay_period: { start_date: @pay_period.start_date, end_date: @pay_period.end_date },
            duplicate: package_result[:duplicate], portal_source: portal_source_json(selection),
            pending_portal_source: pending_portal_source_json,
            loan_setup: loan_setup_access,
            client_change_prefill: (selection ? change_prefill(selection.payroll_submission, preview[:matched]) : nil),
            pending_change_prefill: (!selection && pending_portal_period&.pending_source_review? ? change_prefill(pending_portal_period.current_submission, preview[:matched]) : nil)
          }
        end

        # Names the files and people an import step covered, for the run's
        # Activity feed. File names and row details stay on the import itself.
        def audit_record_metadata(_record)
          return {} unless @audit_import_record

          metadata = { import_id: @audit_import_record.id, source_files: [
            ("revel_hours" if @audit_import_record.pdf_filename.present?),
            ("supplemental_workbook" if @audit_import_record.excel_filename.present?)
          ].compact }
          metadata[:matched_count] = Array(@audit_import_record.matched_data).size unless action_name == "apply"
          if @audit_import_results
            metadata[:applied_count] = @audit_import_results.fetch(:success, []).size
            metadata[:skipped_count] = @audit_import_results.fetch(:skipped, []).size
          end
          metadata[:source_role] = params[:source_role].to_s if action_name == "remove_source"
          if action_name == "tip_treatment"
            metadata[:tips_paid_out_from_tips] = ActiveModel::Type::Boolean.new.cast(params[:tips_paid_out_from_tips])
          end
          metadata
        end

        # The Employee Loans screen's own access rules decide who may set up a
        # loan from the review; the review shows the reason to everyone else.
        def loan_setup_access
          path = "api/v1/admin/employee_loans"
          capability = StaffRolePolicy.capability_for(controller_path: path, action_name: "create")
          allowed = (!capability || StaffRolePolicy.allowed?(current_user, capability, company: current_company)) &&
            TestWorkspaceAccessPolicy.allowed?(user: current_user, company: current_company, request_method: "POST",
              capability: capability, controller_path: path, action_name: "create") &&
            !(current_company&.contained? && TestWorkspaceSafetyPolicy.blocked?(controller_path: path, action_name: "create", request_method: "POST", demo: current_company.demo?, legacy_demo: current_company.legacy_demo?))
          return { allowed: true, reason: nil } if allowed

          { allowed: false, reason: "Your access can't set up employee loans for this client. Ask an admin to set up the loan in Employee Loans, then match the files again." }
        end

        # Staff confirm or edit the workbook's figures before the loan is created.
        # Returns the loan attributes and the workbook's new advance, when it is
        # recorded as its own addition on an existing balance.
        def installment_loan_attributes(offer)
          input = params.permit(:name, :starting_balance, :payment_amount, :first_deduction_date)
          name = input[:name].to_s.strip.presence || offer["name"]
          raise ArgumentError, "Loan name must be 100 characters or fewer" if name.length > 100

          starting = BigDecimal(input.fetch(:starting_balance, offer["starting_balance"]).to_s, exception: false)
          payment = BigDecimal(input.fetch(:payment_amount, offer["payment_amount"]).to_s, exception: false)
          raise ArgumentError, "Starting balance must be greater than zero" unless starting&.positive?
          raise ArgumentError, "Payment per payroll must be greater than zero" unless payment&.positive?
          raise ArgumentError, "Payment per payroll can't be more than the starting balance" if payment > starting
          # The first deduction is this payroll: an earlier date would deduct on
          # other runs, a later one would leave this review unreconciled.
          if input.key?(:first_deduction_date) && input[:first_deduction_date].to_s != @pay_period.pay_date.iso8601
            raise ArgumentError, "The first deduction is this payroll's pay date, #{@pay_period.pay_date.strftime('%-m/%-d/%Y')}."
          end

          first_date = @pay_period.pay_date
          starting = starting.round(2)
          beginning = offer["beginning_balance"].to_d.round(2)
          advance = offer["new_amount"].to_d.round(2)
          note = "Set up from the tips & loans workbook in payroll import review (pay date #{first_date.iso8601})."
          base = { employee_id: offer_employee_id, name: name, tracking_mode: "balance_tracked", payment_amount: payment.round(2),
            first_deduction_date: first_date, notes: note }
          # The loan's balance stands as of its first deduction, so earlier
          # paydays never deduct it and this payroll reconciles to it.
          return [ base.merge(original_amount: starting, start_date: first_date), nil ] unless beginning.positive?

          split = advance.positive? && beginning + advance == starting
          [ base.merge(opening_balance: split ? beginning : starting, balance_as_of: first_date,
            balance_source: "other_verified", principal_amount_known: false), split ? advance : nil ]
        end

        def offer_employee_id
          params[:employee_id].to_i
        end

        def record_loan_audit!(action, loan, offer)
          AuditLog.record!(user: current_user, company_id: @pay_period.company_id, action: action,
            record_type: "employee_loans", record_id: loan.id, subject_name: loan.employee.full_name,
            metadata: { source: "payroll_import_review", pay_period_id: @pay_period.id, import_id: params[:import_id].to_i,
              loan_name: loan.name, current_balance: loan.current_balance&.to_s("F"), payment_amount: loan.payment_amount&.to_s("F"),
              first_deduction_date: loan.first_deduction_date, balance_as_of: loan.balance_as_of,
              workbook: offer.slice("beginning_balance", "new_amount", "starting_balance", "payment_amount", "estimated_ending_balance") },
            ip_address: request.remote_ip, user_agent: request.user_agent, request_id: request.request_id)
        end

        def change_prefill(submission, rows)
          changes = PayrollSubmissions::ImportChanges.new(submission: submission, pay_period: @pay_period)
          { submission_id: submission.id, revision: submission.revision, rows: changes.proposals(source_rows: rows.map(&:deep_symbolize_keys)), removals: changes.removals,
            manual_review_warnings: changes.manual_review_warnings }
        end

        def pay_run_selection!(record)
          pay_run_selection.build(record)
        end

        def pay_run_selection
          PayrollSubmissions::PayRunSelection.new(pay_period: @pay_period, actor: current_user,
            period: pending_portal_period, submission_id: params[:use_submission_id])
        end

        def pending_portal_period
          @pending_portal_period ||= PayrollSubmissionPeriod.where(company_id: @pay_period.company_id,
            pay_period_id: [ nil, @pay_period.id ]).find_by(start_date: @pay_period.start_date, end_date: @pay_period.end_date)
        end

        def pending_portal_source_json
          period = pending_portal_period
          return unless period&.pending_source_review?

          source = period.current_submission
          submission_review_json(source)
        end

        def workbook_warnings(package, submission)
          unless package.documents.any? { |document| document.source_role == "supplemental_workbook" }
            none = submission&.workbook_choice == "none"
            return [ { code: none ? "client_no_tips_or_loans" : "missing_workbook",
              severity: none ? "info" : "warning",
              message: none ? "Client chose: No tips or loans this period." : "No tips or loans: the workbook wasn't included" } ]
          end
          return [] unless package.totals.to_h["total_reported_tips"].to_d.zero?

          [ { code: "zero_workbook_tips", severity: "info", message: "The workbook is included, but its tips total $0." } ]
        end

        def portal_source_json(selection)
          return unless selection

          submission = selection.payroll_submission
          submission_review_json(submission).merge(
            selection_id: selection.id, current: submission.id == submission.period.current_submission&.id,
            superseded_reason: selection.superseded_reason, staff_workbook: selection.staff_workbook_evidence
          )
        end

        def submission_review_json(submission)
          names = Employee.where(company_id: @pay_period.company_id).pluck(:id, :first_name, :last_name).to_h { |id, first, last| [ id, [ first, last ].join(" ") ] }
          {
            submission_id: submission.id, revision: submission.revision, period_id: submission.payroll_submission_period_id,
            notes: submission.notes, changes_link_url: submission.changes_link_url,
            no_changes: submission.no_changes, workbook_choice: submission.workbook_choice,
            changes: submission.change_rows.map { |row| row.merge("label" => PayrollSubmissions::ChangeRows::LABELS[row["kind"]],
              "employee_name" => names[row["employee_id"]], "employee_names" => Array(row["employee_ids"]).filter_map { |id| names[id] }) }
          }
        end

        def with_import_lock
          ApplicationRecord.transaction do
            Company.lock.find(@pay_period.company_id)
            @pay_period.lock!
            revalidate_current_company_write_access!
            yield
          end
        end


        def preview_from_source_package(source_package)
          evidence = source_package.evidence_snapshot.to_h
          preview = evidence.fetch("preview", {})
          matched = source_package.rows.filter_map do |row|
            payload = row.source_payload.to_h
            payload["preview_row"].to_h.merge("source_row_id" => row.id) if payload["row_kind"] == "matched"
          end
          matched = PayrollImport::LivePreviewRowState.new(@pay_period).refresh(matched)

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
          completeness = PayrollIntake::SourceCompleteness.new(session: source_package, company: @pay_period.company)
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
            # Shown beside the review; bytes come from the intake preview endpoint.
            documents: source_package.documents.reject { |document| document.verification_status == "legacy_unverified" }
              .sort_by(&:position).map do |document|
                { id: document.id, source_role: document.source_role, filename: document.filename,
                  content_type: document.content_type, byte_size: document.byte_size, sha256: document.sha256 }
              end,
            disposition_targets: disposition_targets_json,
            sources: completeness.sources,
            complete: completeness.complete?
          }
        end

        def retained_filename(source_package, role)
          source_package.documents.find { |document| document.source_role == role }&.filename
        end

        # Required files that are missing need an explicit, recorded choice. The
        # client's own "No tips or loans this period" counts for the revision
        # selected for this import.
        def source_waivers_for!(source_package, selection)
          completeness = PayrollIntake::SourceCompleteness.new(session: source_package, company: @pay_period.company)
          waivable = completeness.waivable_missing_roles
          staff_waived = ActiveModel::Type::Boolean.new.cast(params[:no_tips_or_loans])
          client_choice = selection&.payroll_submission&.workbook_choice
          # The client sent a workbook or a link to one; staff cannot record "none" over that.
          if staff_waived && client_choice.in?(%w[link attach]) && waivable.any?
            raise ArgumentError, client_choice == "link" ?
              "The client sent a link to the tips & loans workbook. Attach the workbook from the link before applying." :
              "The client attached a tips & loans workbook. Reopen the client revision so the workbook is included."
          end
          client_waived = client_choice == "none"
          waived = staff_waived || client_waived ? waivable : []
          missing = completeness.missing_required_roles(waived_roles: waived)
          if missing.any?
            labels = completeness.labels_for(missing).to_sentence
            message = (missing - waivable).empty? ? "Add the #{labels}, or confirm there are no tips or loans this period." : "Add the #{labels} before applying."
            raise ArgumentError, message
          end

          waived.map do |role|
            { "role" => role, "choice" => completeness.sources.find { |source| source[:role] == role }&.dig(:waiver_label),
              "confirmed_by" => client_waived && !staff_waived ? "client" : "staff", "user_id" => current_user&.id, "at" => Time.current.iso8601 }
          end
        end

        # An older MoSa workbook does not say per person whether tips were
        # already paid daily, so one saved choice covers it. A workbook added
        # from the review, or carried without a choice, was never offered the
        # upload fallback, so apply waits until the choice is recorded.
        def tip_treatment_for!(source_package, import_record)
          raw = import_record.raw_data.to_h
          if legacy_workbook?(source_package) && raw["tip_treatment_confirmed"].blank?
            raise ArgumentError, "Choose whether the tips in this older MoSa workbook were already paid out daily."
          end

          ActiveModel::Type::Boolean.new.cast(raw.fetch("tips_paid_out_from_tips", false))
        end

        def legacy_workbook?(source_package)
          Array(source_package.warnings).any? { |warning| warning.to_h.stringify_keys["code"] == "legacy_mosa_workbook" }
        end

        # Uploading the workbook with the fallback offered beside it is an
        # explicit choice, ticked or not. A new version that keeps the same
        # workbook bytes keeps the choice made for it.
        def tip_confirmation_for(source_package, uploaded_flag, offered:)
          if offered
            return { "tips_paid_out_from_tips" => uploaded_flag,
              "tip_treatment_confirmed" => { "source" => "upload", "user_id" => current_user.id, "at" => Time.current.iso8601 } }
          end

          workbook_sha = ->(session) { session&.documents&.find { |document| document.source_role == "supplemental_workbook" }&.sha256 }
          previous = source_package.supersedes
          previous_record = previous && PayrollImportRecord.find_by(payroll_intake_session: previous)
          kept = previous_record&.raw_data.to_h
          if kept.to_h["tip_treatment_confirmed"].present? && workbook_sha.call(previous).present? && workbook_sha.call(previous) == workbook_sha.call(source_package)
            return { "tips_paid_out_from_tips" => ActiveModel::Type::Boolean.new.cast(kept["tips_paid_out_from_tips"]),
              "tip_treatment_confirmed" => kept["tip_treatment_confirmed"].merge("carried_from_import_id" => previous_record.id) }
          end

          { "tips_paid_out_from_tips" => uploaded_flag, "tip_treatment_confirmed" => nil }
        end

        def included_hand_edited_hours(import_record, included_employee_ids)
          rows = import_record.matched_data.select { |row| included_employee_ids.include?(row["employee_id"].to_i) }
          items = @pay_period.payroll_items.where(employee_id: rows.map { |row| row["employee_id"] }).index_by(&:employee_id)
          applied_hours = PayrollImport::LivePreviewRowState.applied_hours_by_employee(@pay_period)
          rows.filter_map { |row| PayrollImport::LivePreviewRowState.hand_edited_hours(row, items[row["employee_id"].to_i], applied_hours: applied_hours) }
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

        def validate_mosa_included_rows!(decisions, restorable_owner_ids: [])
          duplicate_ids = decisions.filter_map { |decision| decision.row.employee_id }.tally.select { |_id, count| count > 1 }.keys
          excluded_ids = @pay_period.pay_period_excluded_employees.pluck(:employee_id).to_set
          errors = decisions.flat_map do |decision|
            row = decision.row
            messages = []
            messages << "#{row.source_employee_name} must be matched to a Cornerstone employee or given a non-payroll outcome." if row.employee.blank?
            if excluded_ids.include?(row.employee_id) && !restorable_owner_ids.include?(row.employee_id)
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
            requested_loan_deduction: item.requested_loan_deduction,
            loan_payment: item.loan_payment,
            import_source: item.import_source
          }
        end
      end
    end
  end
end
