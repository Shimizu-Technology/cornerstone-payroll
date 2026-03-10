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
        before_action :set_pay_period,    only: [ :index, :batch_pdf, :mark_all_printed ]
        before_action :set_payroll_item,  only: [ :show, :mark_printed, :void, :reprint ]
        before_action :set_company,       only: [ :check_settings, :update_check_settings, :alignment_test_pdf, :update_next_check_number ]

        # -----------------------------------------------------------------------
        # GET /api/v1/admin/pay_periods/:pay_period_id/checks
        # List all checks for a committed pay period.
        # -----------------------------------------------------------------------
        def index
          unless @pay_period.committed?
            return render json: { error: "Checks are only available for committed pay periods" }, status: :unprocessable_entity
          end

          items = @pay_period.payroll_items
                             .includes(:employee, :check_events)
                             .with_check_number
                             .order(:check_number)

          render json: {
            checks: items.map { |item| check_item_json(item) },
            meta: {
              total: items.count,
              printed: items.printed.count,
              unprinted: items.unprinted.count,
              voided: items.voided_checks.count
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
                             .includes(:employee, :pay_period)
                             .checks_only
                             .order(:check_number)

          if items.empty?
            return render json: { error: "No checks to print for this pay period" }, status: :unprocessable_entity
          end

          # Build combined PDF: each item is one page (3-part layout)
          combined_pdf = combine_pdfs(items.map { |item| CheckGenerator.new(item).generate })

          # Log batch download event for each item
          items.each do |item|
            item.check_events.create!(
              user_id: current_user_id,
              event_type: "batch_downloaded",
              check_number: item.check_number,
              ip_address: request.remote_ip
            )
          end

          filename = "checks_#{@pay_period.pay_date.strftime('%Y-%m-%d')}_batch.pdf"
          send_data combined_pdf,
            type: "application/pdf",
            disposition: "attachment",
            filename: filename
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

          items.each do |item|
            item.mark_printed!(user: user, ip_address: request.remote_ip)
            count += 1
          end

          render json: { marked_printed: count }
        end

        # -----------------------------------------------------------------------
        # GET /api/v1/admin/payroll_items/:payroll_item_id/check
        # Download a single check PDF.
        # -----------------------------------------------------------------------
        def show
          generator = CheckGenerator.new(@payroll_item)
          pdf_data  = @payroll_item.voided? ? generator.generate_voided : generator.generate

          send_data pdf_data,
            type: "application/pdf",
            disposition: "attachment",
            filename: generator.filename
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/payroll_items/:payroll_item_id/check/mark_printed
        # -----------------------------------------------------------------------
        def mark_printed
          user = User.find(current_user_id)
          already_printed = @payroll_item.check_printed_at.present?

          @payroll_item.mark_printed!(user: user, ip_address: request.remote_ip)

          render json: {
            payroll_item: check_item_json(@payroll_item.reload),
            already_printed: already_printed
          }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # -----------------------------------------------------------------------
        # POST /api/v1/admin/payroll_items/:payroll_item_id/void
        # Void a check with a written reason.
        # Body: { reason: "..." }
        # -----------------------------------------------------------------------
        def void
          reason = params[:reason].to_s.strip
          user   = User.find(current_user_id)

          @payroll_item.void!(user: user, reason: reason)

          render json: { payroll_item: check_item_json(@payroll_item.reload) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
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
          user    = User.find(current_user_id)
          company = @payroll_item.pay_period.company

          raise ArgumentError, "Cannot reprint: check is already voided" if @payroll_item.voided?
          raise ArgumentError, "Cannot reprint: no check number assigned" if @payroll_item.check_number.blank?

          original_check_number = @payroll_item.check_number

          ActiveRecord::Base.transaction do
            # Step 1: Void the old physical check (audit trail only — item itself stays active)
            void_reason = params[:reason].presence || "Reprint requested — physical check damaged/lost"
            @payroll_item.check_events.create!(
              user: user,
              event_type: "voided",
              check_number: original_check_number,
              reason: void_reason,
              ip_address: request.remote_ip
            )

            # Step 2: Reserve a new check number
            new_check_number = company.next_check_number!

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
              reason: "Replacement for voided check ##{original_check_number}",
              ip_address: request.remote_ip
            )
          end

          render json: {
            original_check_number: original_check_number,
            reprint: check_item_json(@payroll_item.reload)
          }, status: :created
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
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
          permitted = params.permit(:check_stock_type, :check_offset_x, :check_offset_y, :bank_name, :bank_address)
          if @company.update(permitted)
            render json: { check_settings: company_check_settings_json(@company) }
          else
            render json: { errors: @company.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # -----------------------------------------------------------------------
        # PATCH /api/v1/admin/companies/:company_id/next_check_number
        # Admin-only: manually set the starting check number.
        # Allowed only if no checks have been issued for the current calendar year.
        # -----------------------------------------------------------------------
        def update_next_check_number
          new_number = params[:next_check_number].to_i
          if new_number < 1
            return render json: { error: "Check number must be a positive integer" }, status: :unprocessable_entity
          end

          # Safety guard: disallow if checks already issued this year
          current_year = Date.current.year
          checks_this_year = PayrollItem
            .joins(:pay_period)
            .where(pay_periods: { company_id: @company.id })
            .where("EXTRACT(YEAR FROM pay_periods.pay_date) = ?", current_year)
            .where.not(check_number: nil)
            .exists?

          if checks_this_year
            return render json: {
              error: "Cannot change starting check number — checks have already been issued this year. " \
                     "To reset, void all issued checks first or contact Cornerstone support."
            }, status: :unprocessable_entity
          end

          @company.update!(next_check_number: new_number)
          render json: { check_settings: company_check_settings_json(@company) }
        end

        # -----------------------------------------------------------------------
        # GET /api/v1/admin/companies/:company_id/alignment_test_pdf
        # -----------------------------------------------------------------------
        def alignment_test_pdf
          # Build a dummy payroll item for the alignment generator
          stub_item = build_alignment_stub_item(@company)
          generator = CheckGenerator.new(stub_item)
          pdf_data  = generator.alignment_test

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
        end

        private

        # -----------------------------------------------------------------------
        # Finders
        # -----------------------------------------------------------------------

        def set_pay_period
          @pay_period = PayPeriod.find(params[:pay_period_id])
          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found
          end
        end

        def set_payroll_item
          @payroll_item = PayrollItem.includes(:employee, :pay_period, :check_events).find(params[:payroll_item_id])
          unless @payroll_item.pay_period.company_id == current_company_id
            render json: { error: "Payroll item not found" }, status: :not_found
          end
        end

        def set_company
          @company = Company.find_by(id: current_company_id)
          render json: { error: "Company not found" }, status: :not_found unless @company
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
            events: item.check_events.order(:created_at).map { |e| check_event_json(e) }
          }
        end

        def check_event_json(event)
          {
            id: event.id,
            event_type: event.event_type,
            check_number: event.check_number,
            reason: event.reason,
            user_id: event.user_id,
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
            bank_address: company.bank_address
          }
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
          begin
            require "combine_pdf"
            combined = CombinePDF.new
            pdf_binaries.each { |data| combined << CombinePDF.parse(data) }
            combined.to_pdf
          rescue LoadError
            # combine_pdf not installed — return first PDF only and set a warning header
            response.set_header("X-Cornerstone-Warning", "combine_pdf gem not installed; only first check returned")
            pdf_binaries.first
          end
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
      end
    end
  end
end
