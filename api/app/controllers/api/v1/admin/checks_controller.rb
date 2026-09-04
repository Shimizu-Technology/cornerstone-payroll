# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Handles all check-printing operations for a committed pay period.
      #
      # Routes (nested under pay_periods):
      #   GET    /pay_periods/:pay_period_id/checks              → index
      #   POST   /pay_periods/:pay_period_id/checks/batch_pdf    → batch_pdf
      #   POST   /pay_periods/:pay_period_id/checks/mark_all_printed → mark_all_printed
      #
      # Routes (nested under payroll_items):
      #   GET    /payroll_items/:payroll_item_id/check           → show (single PDF)
      #   POST   /payroll_items/:payroll_item_id/check/mark_printed → mark_printed
      #   POST   /payroll_items/:payroll_item_id/void            → void
      #   POST   /payroll_items/:payroll_item_id/reprint         → reprint
      #
      # Company-level:
      #   GET    /companies/:company_id/check_settings           → check_settings (show)
      #   PATCH  /companies/:company_id/check_settings           → update_check_settings
      #   GET    /companies/:company_id/alignment_test_pdf       → alignment_test_pdf
      #   PATCH  /companies/:company_id/next_check_number        → update_next_check_number
      class ChecksController < BaseController
        CHECK_SETTINGS_SCALAR_PARAMS = %i[
          check_stock_type
          check_offset_x
          check_offset_y
          bank_name
          bank_address
          check_memo_template
          auto_create_fit_check
        ].freeze
        CHECK_SETTINGS_PARAM_KEYS = (CHECK_SETTINGS_SCALAR_PARAMS + [ :check_layout_config ]).freeze

        before_action :set_pay_period,    only: [ :index, :batch_pdf, :mark_all_printed ]
        before_action :set_payroll_item,  only: [ :show, :mark_printed, :mark_delivered, :void, :reprint, :update_check_number, :replace_preview, :replace_check ]
        before_action :set_company,       only: [ :check_settings, :update_check_settings, :check_layout, :test_check_pdf, :alignment_test_pdf, :update_next_check_number ]

        # -----------------------------------------------------------------------
        # GET /api/v1/admin/pay_periods/:pay_period_id/checks
        # List all checks for a committed pay period.
        # -----------------------------------------------------------------------
        def index
          unless @pay_period.committed?
            return render json: { error: "Checks are only available for committed pay periods" }, status: :unprocessable_entity
          end

          items = @pay_period.payroll_items
                             .includes({ check_events: :user }, employee: :department)
                             .left_outer_joins(:employee)
                             .with_check_number
                             .order("employees.last_name ASC, employees.first_name ASC, payroll_items.id ASC")

          loaded_items = items.to_a

          render json: {
            checks: loaded_items.map { |item| check_item_json(item) },
            meta: {
              total: loaded_items.size,
              delivered: loaded_items.count { |i| i.check_status == "delivered" },
              printed: loaded_items.count { |i| i.check_status == "printed" },
              unprinted: loaded_items.count { |i| i.check_printed_at.nil? && !i.voided },
              voided: loaded_items.count(&:voided),
              check_stock_type: @pay_period.company.check_stock_type
            }
          }
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/pay_periods/:pay_period_id/checks/batch_pdf
        # Generate a single merged PDF containing all checks for the period.
        # -----------------------------------------------------------------------
        def batch_pdf
          unless @pay_period.committed?
            return render json: { error: "Can only generate check PDF for committed pay periods" }, status: :unprocessable_entity
          end

          items = @pay_period.payroll_items
                             .includes(:payroll_item_earnings, :payroll_item_field_entries, { payroll_item_deductions: :deduction_type, employee: :department, pay_period: :company })
                             .with_check_number
                             .order(Arel.sql("check_number::integer ASC"))
                             .to_a

          # Skip $0 net pay checks unless they're voided (voided checks still print with watermark for traceability)
          printable_items = items.reject { |item| !item.voided? && item.net_pay.to_d <= 0 }

          if printable_items.empty?
            return render json: { error: "No checks to print for this pay period (all items have $0 net pay)" }, status: :unprocessable_entity
          end

          combined_pdf =
            if @pay_period.company.first_hawaiian_4up_checks?
              FirstHawaiianFourUpCheckGenerator.new(
                company: @pay_period.company,
                payroll_items: printable_items,
                starting_slot: params[:starting_slot]
              ).generate
            else
              combine_pdfs(
                printable_items.map do |item|
                  generator = CheckGenerator.new(item)
                  item.voided? ? generator.generate_voided : generator.generate
                end
              )
            end

          # Log batch download event for each printable item in a single INSERT
          user = User.find(current_user_id)
          now = Time.current
          event_records = printable_items.map do |item|
            {
              payroll_item_id: item.id,
              user_id: user.id,
              event_type: "batch_downloaded",
              check_number: item.check_number,
              ip_address: request.remote_ip,
              created_at: now,
              updated_at: now
            }
          end
          CheckEvent.insert_all!(event_records)

          pay_date_token = @pay_period.pay_date&.strftime("%Y-%m-%d") || "undated"
          filename = "checks_#{pay_date_token}_batch.pdf"
          send_data combined_pdf,
            type: "application/pdf",
            disposition: "attachment",
            filename: filename
        rescue LoadError
          render json: {
            error: "Batch PDF requires the combine_pdf gem. Please install it or contact your administrator."
          }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "User not found" }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Failed to record audit events: #{e.record.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/pay_periods/:pay_period_id/checks/mark_all_printed
        # Mark all unprinted checks in the period as printed.
        # -----------------------------------------------------------------------
        def mark_all_printed
          unless @pay_period.committed?
            return render json: { error: "Pay period is not committed" }, status: :unprocessable_entity
          end

          user = User.find(current_user_id)
          items = @pay_period.payroll_items.unprinted.with_check_number
          count = 0

          ActiveRecord::Base.transaction do
            items.each do |item|
              item.mark_printed!(user: user, ip_address: request.remote_ip)
              count += 1
            end
          end

          render json: { marked_printed: count }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "User not found" }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Failed to record audit event: #{e.record.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # GET /api/v1/admin/payroll_items/:payroll_item_id/check
        # Download a single check PDF.
        # -----------------------------------------------------------------------
        def show
          unless @payroll_item.pay_period.committed?
            return render json: { error: "Check PDF is only available for committed pay periods" }, status: :unprocessable_entity
          end

          if @payroll_item.check_number.blank?
            return render json: { error: "No check number assigned to this payroll item" }, status: :unprocessable_entity
          end

          if @payroll_item.pay_period.company.first_hawaiian_4up_checks?
            generator = FirstHawaiianFourUpCheckGenerator.new(
              company: @payroll_item.pay_period.company,
              payroll_items: [ @payroll_item ],
              starting_slot: params[:starting_slot]
            )
            pdf_data = generator.generate
            filename = "fhb_check_#{@payroll_item.check_number || 'UNASSIGNED'}_#{@payroll_item.employee_id}.pdf"
          else
            generator = CheckGenerator.new(@payroll_item)
            pdf_data  = @payroll_item.voided? ? generator.generate_voided : generator.generate
            filename = generator.filename
          end

          send_data pdf_data,
            type: "application/pdf",
            disposition: "attachment",
            filename: filename
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/payroll_items/:payroll_item_id/check/mark_printed
        # -----------------------------------------------------------------------
        def mark_printed
          unless @payroll_item.pay_period.committed?
            return render json: { error: "Check actions are only available for committed pay periods" }, status: :unprocessable_entity
          end

          user = User.find(current_user_id)
          result = @payroll_item.mark_printed!(user: user, ip_address: request.remote_ip)

          render json: {
            payroll_item: check_item_json(@payroll_item.reload),
            already_printed: result[:already_printed]
          }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "User not found" }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Failed to record audit event: #{e.record.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
        end

        # Printing prepares a paper check; delivery is the explicit payment event.
        def mark_delivered
          unless @payroll_item.pay_period.committed?
            message = "Check actions are only available for committed pay periods"
            return render json: { error: message, details: { base: [ message ] } }, status: :unprocessable_entity
          end

          user = User.find(current_user_id)
          result = @payroll_item.mark_delivered!(user: user, ip_address: request.remote_ip)

          render json: {
            data: { payroll_item: check_item_json(@payroll_item.reload) },
            meta: { already_delivered: result[:already_delivered] }
          }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "User not found", details: { user: [ "not found" ] } }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message, details: { base: [ e.message ] } }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          message = "Failed to record audit event: #{e.record.errors.full_messages.join(', ')}"
          render json: { error: message, details: e.record.errors.messages }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/payroll_items/:payroll_item_id/void
        # Void a check with a written reason.
        # Body: { reason: "..." }
        # -----------------------------------------------------------------------
        def void
          unless @payroll_item.pay_period.committed?
            return render json: { error: "Check actions are only available for committed pay periods" }, status: :unprocessable_entity
          end

          reason = params[:reason].to_s.strip
          user   = User.find(current_user_id)

          @payroll_item.void!(user: user, reason: reason, ip_address: request.remote_ip)

          render json: { payroll_item: check_item_json(@payroll_item.reload) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "User not found" }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Failed to record audit event: #{e.record.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/payroll_items/:payroll_item_id/reprint
        #
        # Reprint flow (in-place reassignment — no duplicate payroll items):
        #   1. Audit-log the old check number as voided (check_event: "voided")
        #   2. Reserve a new check number from the company sequence
        #   3. Reassign the payroll item's check_number to the new value
        #   4. Clear the printed-at timestamp so it's ready for printing
        #   5. Store reprint_of_check_number for traceability
        #   6. Audit-log the reprint event
        #
        # The payroll item itself (gross/net pay etc.) is NEVER changed.
        # The voided=true flag is NOT set — the payroll obligation is still valid.
        # -----------------------------------------------------------------------
        def reprint
          unless @payroll_item.pay_period.committed?
            return render json: { error: "Check actions are only available for committed pay periods" }, status: :unprocessable_entity
          end

          reason = params[:reason].to_s.strip
          if reason.blank?
            return render json: { error: "A reason is required to reissue a check" }, status: :unprocessable_entity
          end

          requested_check_number = params[:replacement_check_number].to_s.strip.presence

          user    = User.find(current_user_id)
          company = @payroll_item.pay_period.company

          original_check_number = nil
          new_check_number = nil

          ActiveRecord::Base.transaction do
            @payroll_item.lock!
            raise ArgumentError, "Cannot reissue: check is already voided" if @payroll_item.voided?
            raise ArgumentError, "Cannot reissue: no check number assigned" if @payroll_item.check_number.blank?

            original_check_number = @payroll_item.check_number

            # Step 1: Void the old physical check (audit trail only — item itself stays active)
            @payroll_item.check_events.create!(
              user: user,
              event_type: "voided",
              check_number: original_check_number,
              reason: reason,
              ip_address: request.remote_ip
            )

            # Step 2: Reserve or validate the replacement check number
            new_check_number = requested_check_number.present? ? reserve_requested_reissue_check_number!(company, requested_check_number, original_check_number) : company.next_check_number!

            # Step 3 & 4 & 5: Reassign in-place
            @payroll_item.update!(
              reprint_of_check_number: original_check_number,
              check_number:    new_check_number,
              check_printed_at: nil,
              check_print_count: 0
            )

            # Step 6: Log the reprint event
            @payroll_item.check_events.create!(
              user: user,
              event_type: "reprinted",
              check_number: new_check_number,
              reason: "Reissued replacement for voided check ##{original_check_number}: #{reason}",
              ip_address: request.remote_ip
            )
          end

          render json: {
            original_check_number: original_check_number,
            replacement_check_number: new_check_number,
            reprint: check_item_json(@payroll_item.reload)
          }, status: :created
        rescue ActiveRecord::RecordNotFound
          render json: { error: "User not found" }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Failed to record audit event: #{e.record.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # PATCH /api/v1/admin/payroll_items/:payroll_item_id/check_number
        # Correct an assigned check number without changing payroll dollars.
        # -----------------------------------------------------------------------
        def update_check_number
          unless current_user
            return render json: { error: "User not found" }, status: :unprocessable_entity
          end

          updated_item = CheckNumberCorrectionService.new(
            payroll_item: @payroll_item,
            new_check_number: params[:check_number],
            reason: params[:reason],
            actor: current_user,
            ip_address: request.remote_ip
          ).call

          render json: { payroll_item: check_item_json(updated_item) }
        rescue CheckNumberCorrectionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/payroll_items/:payroll_item_id/replace_check_preview
        #
        # Read-only delta preview for the Replace (uncashed) modal. Returns the
        # original snapshot, the recomputed corrected snapshot, the mode
        # (:in_place vs :void_and_reissue based on whether the original was
        # printed), and a meta block driving the UI's submit-button state.
        # -----------------------------------------------------------------------
        def replace_preview
          unless @payroll_item.pay_period.committed?
            return render json: { error: "Replace flow is only available for committed pay periods" }, status: :unprocessable_entity
          end

          preview = ReplaceCheckService.preview(
            payroll_item:    @payroll_item,
            corrected_inputs: permit_replace_check_inputs
          )
          render json: preview
        rescue ReplaceCheckService::ReplaceError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/payroll_items/:payroll_item_id/replace_check
        #
        # Atomically:
        #   1. Subtract the original item's contribution from employee + company YTD.
        #   2. (printed-only) Audit-log the void of the original check #.
        #   3. Apply the corrected inputs to the item and re-run PayrollCalculator
        #      with YTD context that excludes this item (so taxes match a
        #      from-scratch run with the new inputs).
        #   4. (printed-only) Assign a fresh check #; set replaced_check_number
        #      to the original. (unprinted: keep same check #.)
        #   5. Re-add to YTD with the new (corrected) values.
        #   6. Audit-log a `replaced` event with a structured before/after summary.
        #
        # Body: { corrected_inputs: {...}, reason: "..." }
        # -----------------------------------------------------------------------
        def replace_check
          unless @payroll_item.pay_period.committed?
            return render json: { error: "Replace flow is only available for committed pay periods" }, status: :unprocessable_entity
          end

          # `current_user` on ApplicationController already memoizes the
          # User object — calling `User.find(current_user_id)` would
          # re-issue a SELECT for the same row we already loaded for
          # auth. Use `current_user` directly.
          unless current_user
            return render json: { error: "User not found" }, status: :unprocessable_entity
          end

          updated_item = ReplaceCheckService.replace!(
            payroll_item:    @payroll_item,
            corrected_inputs: permit_replace_check_inputs,
            reason:          params[:reason].to_s.strip,
            actor:           current_user,
            ip_address:      request.remote_ip
          )

          render json: { payroll_item: check_item_json(updated_item) }, status: :ok
        rescue ReplaceCheckService::InvalidStateError,
               ReplaceCheckService::UnsupportedEmployeeError,
               ReplaceCheckService::MissingHistoricalContextError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ReplaceCheckService::InvalidInputError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # GET /api/v1/admin/companies/:company_id/check_settings
        # -----------------------------------------------------------------------
        def check_settings
          render json: { check_settings: company_check_settings_json(@company) }
        end

        # -----------------------------------------------------------------------
        # PATCH /api/v1/admin/companies/:company_id/check_settings
        # -----------------------------------------------------------------------
        def update_check_settings
          permitted = check_settings_update_params

          [ :check_offset_x, :check_offset_y ].each do |key|
            next unless permitted.key?(key)
            value = permitted[key]
            if value.blank?
              permitted[key] = 0
              next
            end
            next if value.is_a?(Numeric)
            next if value.to_s.match?(/\A-?\d+(\.\d+)?\z/)

            return render json: { errors: [ "#{key} must be a number" ] }, status: :unprocessable_entity
          end

          normalize_and_sanitize_layout_config!(permitted, current_stock_type: @company.check_stock_type)
          permitted[:active_printer_profile_id] = nil if printer_calibration_settings_changed?(permitted)

          if @company.update(permitted)
            render json: { check_settings: company_check_settings_json(@company) }
          else
            render json: { errors: @company.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # GET /api/v1/admin/companies/:company_id/check_layout
        # Returns the generator-resolved layout so the UI can edit the same
        # field coordinates used by the PDF renderer.
        # -----------------------------------------------------------------------
        def check_layout
          render json: { check_layout: company_check_layout_json(layout_preview_company(@company)) }
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/companies/test_check_pdf
        # Renders a sample check using draft settings from the Check Settings UI.
        # Nothing is persisted and no real check/payroll records are created.
        # -----------------------------------------------------------------------
        def test_check_pdf
          preview_company = check_settings_preview_company(@company)
          sample_type = params[:sample_type].presence || "payroll"

          pdf_data = case sample_type
          when "payroll"
            sample_item = build_test_payroll_item(preview_company)
            if preview_company.first_hawaiian_4up_checks?
              FirstHawaiianFourUpCheckGenerator.new(company: preview_company, payroll_items: [ sample_item ]).generate
            else
              CheckGenerator.new(sample_item).generate
            end
          when "fit", "grt", "vendor"
            sample_check = build_test_non_employee_check(preview_company, sample_type)
            if preview_company.first_hawaiian_4up_checks?
              FirstHawaiianFourUpCheckGenerator.new(company: preview_company, non_employee_checks: [ sample_check ]).generate
            else
              NonEmployeeCheckGenerator.new(sample_check, layout_config: preview_company.check_layout_config).generate
            end
          else
            return render json: { error: "Unknown test check type" }, status: :unprocessable_entity
          end

          send_data pdf_data,
            type: "application/pdf",
            disposition: "inline",
            filename: "test_check_#{sample_type}_#{Date.current}.pdf"
        rescue StandardError => e
          render json: { error: "Failed to generate test check: #{e.message}" }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # PATCH /api/v1/admin/companies/:company_id/next_check_number
        # Admin-only: manually set the next blank check number.
        # If checks already exist, the next number can move forward but cannot
        # move backward into an already-issued range.
        # -----------------------------------------------------------------------
        def update_next_check_number
          new_number = params[:next_check_number].to_i
          if new_number < 1
            return render json: { error: "Check number must be a positive integer" }, status: :unprocessable_entity
          end

          if new_number > 9_999_999
            return render json: { error: "Check number cannot exceed 9,999,999" }, status: :unprocessable_entity
          end

          if new_number < @company.next_check_number.to_i
            return render json: {
              error: "Next check number cannot move backward. Current next check number is #{@company.next_check_number}."
            }, status: :unprocessable_entity
          end

          issued_numbers = issued_check_numbers_for_company(@company)
          highest_issued_number = issued_numbers.max
          if highest_issued_number && new_number <= highest_issued_number
            return render json: {
              error: "Next check number must be higher than the highest issued check number " \
                     "(#{highest_issued_number}). Enter #{highest_issued_number + 1} or higher."
            }, status: :unprocessable_entity
          end

          @company.update!(next_check_number: new_number)
          render json: { check_settings: company_check_settings_json(@company) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # GET /api/v1/admin/companies/:company_id/alignment_test_pdf
        # -----------------------------------------------------------------------
        def alignment_test_pdf
          pdf_data =
            if @company.first_hawaiian_4up_checks?
              FirstHawaiianFourUpCheckGenerator.new(company: @company).alignment_test
            else
              # Build a dummy payroll item for the alignment generator
              stub_item = build_alignment_stub_item(@company)
              CheckGenerator.new(stub_item).alignment_test
            end

          # Log the alignment test event (uses system user — company-level action)
          # We log to audit_logs rather than check_events since there's no real payroll item
          AuditLog.record!(
            user: User.find(current_user_id),
            company_id: @company.id,
            action: "alignment_test_generated",
            record_type: "Company",
            record_id: @company.id,
            metadata: { company_name: @company.name },
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )

          send_data pdf_data,
            type: "application/pdf",
            disposition: "attachment",
            filename: "alignment_test_#{@company.name.parameterize}_#{Date.current}.pdf"
        rescue StandardError => e
          render json: { error: "Failed to generate alignment test: #{e.message}" }, status: :unprocessable_entity
        end

        private

        def reserve_requested_reissue_check_number!(company, requested_check_number, original_check_number)
          normalized = requested_check_number.to_s.strip
          raise ArgumentError, "Replacement check number must be numeric" unless normalized.match?(/\A\d+\z/)
          raise ArgumentError, "Replacement check number must be greater than 0" if normalized.to_i < 1
          raise ArgumentError, "Replacement check number cannot exceed 9,999,999" if normalized.to_i > 9_999_999
          raise ArgumentError, "Replacement check number must be different from the original check number" if normalized == original_check_number.to_s

          company.lock!
          if PayrollItem.where(company_id: company.id, check_number: normalized).where.not(id: @payroll_item.id).exists? ||
             NonEmployeeCheck.where(company_id: company.id, check_number: normalized).exists?
            raise ArgumentError, "Check number #{normalized} is already in use for this company"
          end

          next_number = normalized.to_i + 1
          company.update!(next_check_number: next_number) if next_number > company.next_check_number.to_i
          normalized
        end

        def issued_check_numbers_for_company(company)
          payroll_max = PayrollItem
            .joins(:pay_period)
            .where(pay_periods: { company_id: company.id })
            .where.not(check_number: nil)
            .where("payroll_items.check_number ~ ?", "^[0-9]+$")
            .maximum(Arel.sql("CAST(payroll_items.check_number AS integer)"))

          non_employee_max = NonEmployeeCheck
            .where(company_id: company.id)
            .where.not(check_number: nil)
            .where("non_employee_checks.check_number ~ ?", "^[0-9]+$")
            .maximum(Arel.sql("CAST(non_employee_checks.check_number AS integer)"))

          [ payroll_max, non_employee_max ].compact
        end

        # -----------------------------------------------------------------------
        # Strong-params extraction for the replace-check endpoints'
        # `corrected_inputs` payload.
        #
        # The service layer already does
        # `(corrected_inputs || {}).symbolize_keys.slice(*REPLACEABLE_INPUT_FIELDS)`
        # — so `to_unsafe_h` here was *safe*, but it bypassed the
        # strong-params discipline the rest of the API follows. This
        # helper expresses the contract at the controller boundary:
        # scalar replaceable fields are explicitly permitted, and the
        # array fields (`custom_earnings`, `wage_rate_hours`) are
        # permitted with their known nested shapes. Anything else is
        # dropped. The `wage_rate_hours` shape mirrors the one used by
        # PayrollItemsController#payroll_item_params for consistency.
        # -----------------------------------------------------------------------
        def permit_replace_check_inputs
          raw = params[:corrected_inputs]
          return {} if raw.blank?

          raw = ActionController::Parameters.new(raw) unless raw.is_a?(ActionController::Parameters)

          scalar_fields = ReplaceCheckService::REPLACEABLE_INPUT_FIELDS - %i[custom_earnings custom_deductions wage_rate_hours]

          raw.permit(
            *scalar_fields,
            custom_earnings: [ :label, :amount ],
            custom_deductions: [ :label, :amount ],
            wage_rate_hours: [
              :employee_wage_rate_id, :label, :rate, :regular_hours,
              :overtime_hours, :holiday_hours, :pto_hours, :is_primary, :active
            ]
          ).to_h
        end

        # -----------------------------------------------------------------------
        # Finders
        # -----------------------------------------------------------------------

        def set_pay_period
          @pay_period = PayPeriod.find(params[:pay_period_id])
          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found and return
          end
        end

        def set_payroll_item
          @payroll_item = PayrollItem.includes(:payroll_item_earnings, :payroll_item_field_entries, { payroll_item_deductions: :deduction_type, check_events: :user, employee: :department, pay_period: :company }).find(params[:payroll_item_id])
          unless @payroll_item.pay_period.company_id == current_company_id
            render json: { error: "Payroll item not found" }, status: :not_found and return
          end
        end

        def set_company
          @company = Company.find_by(id: current_company_id)
          render json: { error: "Company not found" }, status: :not_found and return unless @company
        end

        # -----------------------------------------------------------------------
        # JSON helpers
        # -----------------------------------------------------------------------

        def check_item_json(item)
          {
            id: item.id,
            pay_period_id: item.pay_period_id,
            employee_id: item.employee_id,
            employee_name: item.employee&.full_name,
            department_id: item.employee&.department_id,
            department_name: item.employee&.department&.name,
            check_number: item.check_number,
            net_pay: item.net_pay,
            gross_pay: item.gross_pay,
            check_status: item.check_status,
            check_printed_at: item.check_printed_at,
            check_print_count: item.check_print_count,
            voided: item.voided,
            voided_at: item.voided_at,
            void_reason: item.void_reason,
            reprint_of_check_number: item.reprint_of_check_number,
            replaced_check_number: item.replaced_check_number,
            events: item.check_events.to_a.sort_by(&:created_at).map { |e| check_event_json(e) }
          }
        end

        def check_event_json(event)
          {
            id: event.id,
            event_type: event.event_type,
            check_number: event.check_number,
            reason: event.reason,
            user_id: event.user_id,
            user_name: event.user&.name,
            ip_address: event.ip_address,
            created_at: event.created_at
          }
        end

        def company_check_settings_json(company)
          {
            next_check_number: company.next_check_number,
            check_stock_type: company.check_stock_type,
            check_offset_x: company.check_offset_x,
            check_offset_y: company.check_offset_y,
            bank_name: company.bank_name,
            bank_address: company.bank_address,
            check_memo_template: company.check_memo_template,
            auto_create_fit_check: company.auto_create_fit_check,
            check_layout_config: sanitize_check_layout_config(company.check_stock_type, company.check_layout_config || {}),
            active_printer_profile_id: company.active_printer_profile_id,
            active_printer_profile_name: company.active_printer_profile&.name
          }
        end

        def printer_calibration_settings_changed?(permitted)
          return true if permitted.key?(:check_stock_type) && permitted[:check_stock_type].to_s != @company.check_stock_type.to_s
          return true if permitted.key?(:check_offset_x) && BigDecimal(permitted[:check_offset_x].to_s) != @company.check_offset_x.to_d
          return true if permitted.key?(:check_offset_y) && BigDecimal(permitted[:check_offset_y].to_s) != @company.check_offset_y.to_d

          if permitted.key?(:check_layout_config)
            current_layout = JSON.parse((@company.check_layout_config || {}).to_json)
            next_layout = JSON.parse((permitted[:check_layout_config] || {}).to_json)
            return true if next_layout != current_layout
          end

          false
        end

        def check_settings_preview_company(company)
          permitted = preview_check_settings_params
          company.dup.tap do |preview|
            preview.id = company.id
            preview.check_stock_type = permitted[:check_stock_type] if permitted.key?(:check_stock_type)
            preview.check_offset_x = permitted[:check_offset_x] if permitted.key?(:check_offset_x)
            preview.check_offset_y = permitted[:check_offset_y] if permitted.key?(:check_offset_y)
            preview.bank_name = permitted[:bank_name] if permitted.key?(:bank_name)
            preview.bank_address = permitted[:bank_address] if permitted.key?(:bank_address)
            preview.check_memo_template = permitted[:check_memo_template] if permitted.key?(:check_memo_template)
            preview.check_layout_config = permitted[:check_layout_config] if permitted.key?(:check_layout_config)
          end
        end

        def check_settings_update_params
          source = check_settings_update_param_source
          source.slice(*CHECK_SETTINGS_PARAM_KEYS).permit(
            *CHECK_SETTINGS_SCALAR_PARAMS,
            check_layout_config: {}
          ).to_h.with_indifferent_access
        end

        def check_settings_update_param_source
          root_has_settings = CHECK_SETTINGS_PARAM_KEYS.any? { |key| params.key?(key) }
          raw = root_has_settings ? params : params[:check]
          raw = {} if raw.blank?
          raw = ActionController::Parameters.new(raw) unless raw.is_a?(ActionController::Parameters)
          raw
        end

        def preview_check_settings_params
          raw = params[:check_settings].presence || {}
          raw = ActionController::Parameters.new(raw) unless raw.is_a?(ActionController::Parameters)
          permitted = raw.permit(
            :check_stock_type,
            :check_offset_x,
            :check_offset_y,
            :bank_name,
            :bank_address,
            :check_memo_template,
            check_layout_config: {}
          )

          normalize_and_sanitize_layout_config!(permitted, current_stock_type: @company.check_stock_type)

          [ :check_offset_x, :check_offset_y ].each do |key|
            permitted[key] = 0 if permitted.key?(key) && permitted[key].blank?
          end

          permitted
        end

        def company_check_layout_json(company)
          layout_company = company.dup
          layout_company.id = company.id
          layout_company.check_layout_config = sanitize_check_layout_config(company.check_stock_type, company.check_layout_config || {})

          if layout_company.first_hawaiian_4up_checks?
            generator = FirstHawaiianFourUpCheckGenerator
            layout = generator.resolved_layout_for(layout_company)
            page = generator.page_layout_metadata(layout_company)
          else
            generator = CheckGenerator
            layout = generator.resolved_layout_for(layout_company)
            page = generator.page_layout_metadata(layout_company)
          end

          {
            check_stock_type: layout_company.check_stock_type,
            check_offset_x: layout_company.check_offset_x,
            check_offset_y: layout_company.check_offset_y,
            default_layout_config: generator.default_layout_config,
            resolved_layout_config: layout,
            page: page
          }
        end

        def layout_preview_company(company)
          requested_stock_type = params[:check_stock_type].presence
          return company unless requested_stock_type && Company::CHECK_STOCK_TYPES.include?(requested_stock_type)

          company.dup.tap do |preview|
            preview.id = company.id
            preview.check_stock_type = requested_stock_type
            preview.check_layout_config = sanitize_check_layout_config(requested_stock_type, company.check_layout_config || {})
          end
        end

        def normalize_and_sanitize_layout_config!(permitted, current_stock_type:)
          target_stock_type = permitted[:check_stock_type].presence || current_stock_type
          if permitted.key?(:check_layout_config)
            permitted[:check_layout_config] = sanitize_check_layout_config(target_stock_type, permitted[:check_layout_config])
          elsif permitted.key?(:check_stock_type) && target_stock_type.to_s != current_stock_type.to_s
            permitted[:check_layout_config] = {}
          end
        end

        def sanitize_check_layout_config(stock_type, raw_config)
          CheckLayoutConfigSanitizer.call(stock_type: stock_type, config: raw_config)
        end

        # -----------------------------------------------------------------------
        # PDF merging (concatenate raw PDF binaries using Prawn)
        # -----------------------------------------------------------------------

        def combine_pdfs(pdf_binaries)
          # Use pdf-reader to merge page by page if available;
          # otherwise fall back to concatenation via a Prawn document with imports.
          # Since we don't have pdf-reader, we use CombinePDF-style approach:
          # Rebuild a single Prawn doc with one page per check.
          # Simplest robust approach: just concatenate — each PDF is already one page.
          # Use ghostscript if available, otherwise return first-page workaround.
          #
          # Production note: install `combine_pdf` gem for proper merging.
          # For now we build a simple multi-page doc from generators directly.
          return pdf_binaries.first if pdf_binaries.size == 1

          # Re-generate using a fresh shared Prawn doc — not possible to merge binary PDFs
          # without an external library. Use combine_pdf if available; otherwise return
          # a single-blob response and note in header.
          require "combine_pdf"
          combined = CombinePDF.new
          pdf_binaries.each { |data| combined << CombinePDF.parse(data) }
          combined.to_pdf
        rescue LoadError
          raise
        rescue StandardError => e
          raise ArgumentError, "Failed to merge check PDFs: #{e.message}"
        end

        # -----------------------------------------------------------------------
        # Alignment test stub (fake PayrollItem-like object for CheckGenerator)
        # -----------------------------------------------------------------------

        def build_alignment_stub_item(company)
          # Build a real unsaved stub for the generator
          pay_period = company.pay_periods.order(created_at: :desc).first ||
            PayPeriod.new(
              company: company,
              start_date: Date.current.beginning_of_month,
              end_date: Date.current,
              pay_date: Date.current,
              status: "committed"
            )

          employee = company.employees.active.first ||
            Employee.new(first_name: "Jane", last_name: "Sample", employment_type: "hourly", pay_rate: 12)

          item = PayrollItem.new(
            pay_period: pay_period,
            employee: employee,
            employment_type: "hourly",
            pay_rate: 12.00,
            hours_worked: 80,
            gross_pay: 960.00,
            net_pay: 742.50,
            withholding_tax: 96.00,
            social_security_tax: 59.52,
            medicare_tax: 13.92,
            total_deductions: 169.44,
            check_number: "XXXX",
            check_print_count: 0,
            voided: false
          )
          item
        end

        def build_test_payroll_item(company)
          pay_period = PayPeriod.new(
            company: company,
            start_date: Date.current.beginning_of_month,
            end_date: Date.current.beginning_of_month + 13.days,
            pay_date: Date.current,
            status: "committed"
          )
          employee = Employee.new(
            company: company,
            first_name: "Jane",
            last_name: "Sample",
            employment_type: "hourly",
            pay_frequency: "biweekly",
            pay_rate: 15.55,
            address_line1: "123 Marine Dr",
            city: "Hagatna",
            state: "GU",
            zip: "96910"
          )

          PayrollItem.new(
            company: company,
            pay_period: pay_period,
            employee: employee,
            employment_type: "hourly",
            pay_rate: 15.55,
            hours_worked: 80,
            gross_pay: 1244.00,
            net_pay: 947.26,
            withholding_tax: 124.40,
            social_security_tax: 77.13,
            medicare_tax: 18.04,
            retirement_payment: 62.20,
            insurance_payment: 15.00,
            total_deductions: 296.74,
            check_number: "TEST",
            check_print_count: 0,
            voided: false
          )
        end

        def build_test_non_employee_check(company, sample_type)
          attrs = case sample_type
          when "fit"
            {
              payable_to: "Treasurer of Guam",
              amount: 1240.55,
              check_type: "tax_deposit",
              memo: "FIT deposit for payroll period",
              description: "Sample Federal Income Tax deposit",
              reference_number: "FIT-TEST",
              payment_period_type: "pay_period"
            }
          when "grt"
            {
              payable_to: "Treasurer of Guam",
              amount: 438.22,
              check_type: "grt",
              memo: "GRT payment for #{Date.current.strftime('%B %Y')}",
              description: "Sample Gross Receipts Tax payment",
              reference_number: "GRT-TEST",
              payment_period_type: "month",
              tax_year: Date.current.year,
              tax_month: Date.current.month
            }
          else
            {
              payable_to: "Sample Vendor LLC",
              amount: 325.00,
              check_type: "vendor",
              memo: "Sample vendor payment",
              description: "Sample vendor invoice payment",
              reference_number: "INV-TEST",
              payment_period_type: "none"
            }
          end

          NonEmployeeCheck.new(attrs.merge(
            company: company,
            check_number: "TEST",
            payment_date: Date.current,
            created_at: Time.current,
            updated_at: Time.current
          ))
        end
      end
    end
  end
end
