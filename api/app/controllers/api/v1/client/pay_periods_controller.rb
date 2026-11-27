# frozen_string_literal: true

module Api
  module V1
    module Client
      class PayPeriodsController < BaseController
        include ClientComponentHistoryErrors

        PAY_LINE_DETAILS_UNAVAILABLE = "Details for this pay line aren't available yet. Contact Cornerstone."
        REVIEW_DETAILS_UNAVAILABLE = "Some pay lines can't be shown yet, so this review can't be approved. Contact Cornerstone."

        audit_actions :approve_review
        before_action :set_pay_period, only: %i[show approve_review request_changes preview_pdf]

        def index
          result = PayrollHistoryQuery.new(
            company_id: current_company_id,
            params: params,
            audience: :client,
            client_actor: current_user
          ).call
          render json: {
            pay_periods: result.data,
            meta: result.meta,
            open_period: open_period
          }
        end

        def show
          render json: {
            pay_period: pay_period_summary(@pay_period, include_items: true)
          }
        end

        def approve_review
          unless current_user&.client?
            return render json: { error: "A client portal user must approve this payroll revision." }, status: :forbidden
          end

          review_package = PayrollReview::RevisionService.new(pay_period: @pay_period, actor: current_user).approve!(
            approver: current_user,
            recorded_by: current_user,
            method: "client_portal",
            acknowledgement: params[:acknowledgement],
            notes: params[:notes],
            revision_id: params[:revision_id]
          ) do |locked_period|
            ActiveRecord::Base.uncached do
              if client_pay_items(locked_period).any? { |item| pay_item_summary(item, locked_period).key?(:details_error) }
                raise PayrollReview::RevisionService::Error, REVIEW_DETAILS_UNAVAILABLE
              end
            end
          end
          render json: { payroll_review: PayrollReview::PackagePresenter.call(review_package, include_notification_status: true) }
        rescue PayrollReview::RevisionService::StaleRevisionError => e
          render json: { error: e.message, code: "stale_payroll_review_revision" }, status: :unprocessable_entity
        rescue PayrollReview::RevisionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def request_changes
          return render json: { error: "A client portal user must request changes." }, status: :forbidden unless current_user&.client?

          package = PayrollReview::RevisionService.new(pay_period: @pay_period, actor: current_user)
            .request_changes!(revision_id: params[:revision_id], note: params[:note])
          render json: { payroll_review: PayrollReview::PackagePresenter.call(package, include_notification_status: true) }
        rescue PayrollReview::RevisionService::StaleRevisionError => e
          render json: { error: e.message, code: "stale_payroll_review_revision" }, status: :unprocessable_entity
        rescue PayrollReview::RevisionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def preview_pdf
          package = current_preview_package!
          PayrollReview::RevisionService.new(pay_period: @pay_period).verify_current_checksum!(package)
          pdf = PayrollPreviewPdf.generate(pay_period: @pay_period, company: @pay_period.company, part: params[:part].presence)
          @pay_period.with_lock do
            begin
              current = current_preview_package!
              raise PayrollReview::RevisionService::StaleRevisionError, "Revision changed" unless current.id == package.id

              PayrollReview::RevisionService.new(pay_period: @pay_period).verify_current_checksum!(current)
            rescue PayrollReview::RevisionService::Error
              return render json: { error: "This payroll changed while the preview was being prepared. Review the latest preview.", code: "stale_payroll_review_revision" }, status: :conflict
            end
            AuditLog.record!(user: current_user, company_id: @pay_period.company_id,
              action: "client_payroll_review#preview_pdf", record_type: "PayrollReviewPackage", record_id: package.id,
              event_category: "document_access", ip_address: request.remote_ip, user_agent: request.user_agent,
              metadata: { pay_period_id: @pay_period.id, revision: package.revision, part: params[:part].presence || "combined" })
          end
          response.headers["Cache-Control"] = "private, no-store"
          part_token = params[:part].present? ? "_#{params[:part]}" : ""
          send_data pdf, type: "application/pdf", disposition: "attachment",
            filename: "Payroll_PREVIEW_#{@pay_period.pay_date.iso8601}_rev#{package.revision}#{part_token}.pdf"
        rescue PayrollReview::RevisionService::StaleRevisionError => e
          render json: { error: e.message, code: "stale_payroll_review_revision" }, status: :unprocessable_entity
        rescue PayrollComponentMirrors::AmbiguousHistoryError, PayrollInsuranceComponents::AmbiguousHistoryError
          raise
        rescue PayrollReview::RevisionService::Error, ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::ActiveRecordError
          render json: { error: "Could not record the preview download. Try again." }, status: :service_unavailable
        end

        private

        def open_period
          catalog = PayrollSubmissions::Catalog.new(company: Company.find(current_company_id))
          entries = catalog.entries.select { |entry| entry.start_date <= catalog.today }
          catalog.preload_live_pay_periods(entries)
          open_entries = entries.select do |candidate|
            next false if catalog.voided_pay_period?(candidate)

            date = catalog.pay_date_for(candidate) || candidate.end_date
            date >= catalog.today && !catalog.live_pay_period(candidate)&.client_finished?
          end
          entry = open_entries.find { |candidate| catalog.open_for_files?(candidate) } || open_entries.first
          return unless entry

          PayrollSubmissions::Serializer.new(current_user: current_user, catalog: catalog).summary(entry)
            .slice(:ref, :start_date, :end_date, :pay_date, :review_pay_period_id, :client_payroll_status)
        end

        def current_preview_package!
          unless @pay_period.client_payroll_approval_required?
            raise PayrollReview::RevisionService::Error, "Client payroll review is disabled for this company."
          end
          raise PayrollReview::RevisionService::Error, "Preview is available only while payroll is approved." unless @pay_period.approved? && @pay_period.correction_status != "voided"

          package = @pay_period.payroll_review_packages.current.first
          unless package && package.published_at && package.id.to_s == params[:revision_id].to_s
            raise PayrollReview::RevisionService::StaleRevisionError, "This preview revision changed. Reload the pay run."
          end
          package
        end

        def set_pay_period
          scope = PayPeriod.reportable_periods.where(company_id: current_company_id)
          @pay_period = scope.find_by(id: params[:id])
          @pay_period = nil unless client_visible_period?(@pay_period)
          return if @pay_period

          render json: { error: "Pay period not found" }, status: :not_found
        end

        def client_pay_items(pay_period)
          pay_period.payroll_items.reportable.includes(
            :employee,
            :payroll_item_earnings,
            { payroll_item_field_entries: :payroll_field_definition },
            { payroll_item_deductions: :deduction_type }
          ).select(&:payroll_included?)
        end

        def pay_period_summary(pay_period, include_items: false)
          items = client_pay_items(pay_period)
          json = {
            id: pay_period.id,
            company_id: pay_period.company_id,
            start_date: pay_period.start_date,
            end_date: pay_period.end_date,
            pay_date: pay_period.pay_date,
            status: pay_period.status,
            test_workspace_role: pay_period.test_workspace_role,
            run_purpose: pay_period.run_purpose,
            includes_base_salary: pay_period.includes_base_salary,
            includes_recurring_items: pay_period.includes_recurring_items,
            period_description: pay_period.period_description,
            employee_count: items.size,
            total_gross: items.sum(&:gross_pay),
            total_net: items.sum(&:net_pay),
            committed_at: pay_period.committed_at,
            created_at: pay_period.created_at,
            updated_at: pay_period.updated_at
          }

          json[:client_payroll_approval_required] = pay_period.client_payroll_approval_required?
          review = if pay_period.client_payroll_approval_required?
            pay_period.payroll_review_packages.summary.current.where.not(published_at: nil)
              .includes(:generated_by, :approved_by, :approval_recorded_by).order(revision: :desc).first
          end
          json[:payroll_review] = PayrollReview::PackagePresenter.call(review, include_notification_status: true)
          json[:can_decide_payroll_review] = pay_period.approved? &&
            PayrollReview::RevisionService.client_can_decide?(review, current_user) == true

          if include_items
            json[:payroll_review_history] = pay_period.payroll_review_packages.where.not(published_at: nil)
              .select(PayrollReviewPackage.column_names - %w[calculation_snapshot source_manifest])
              .includes(:generated_by, :approved_by, :approval_recorded_by, :changes_requested_by).order(revision: :desc)
              .map { |package| PayrollReview::PackagePresenter.call(package, include_source_manifest: false) }
            json[:payroll_review_history] = [] unless pay_period.client_payroll_approval_required?
            json[:payroll_items] = items.map { |item| pay_item_summary(item, pay_period) }
            json[:can_decide_payroll_review] = false if json[:payroll_items].any? { |item| item.key?(:details_error) }
          end

          json
        end

        def pay_item_summary(item, pay_period)
          summary = {
            id: item.id,
            pay_stub_available: pay_period.client_finished? && EarningsStatementEligibility.printable?(item),
            employee_id: item.employee_id,
            employee_name: item.employee_full_name,
            employment_type: item.employment_type,
            salary_type: item.calculation_context_snapshot.to_h.dig("employee", "salary_type") || item.timekeeping_context_snapshot.to_h["salary_type"],
            contractor_pay_type: item.calculation_context_snapshot.to_h.dig("employee", "contractor_pay_type"),
            pay_rate: item.pay_rate,
            total_hours: item.total_hours,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            gross_pay: item.gross_pay,
            net_pay: item.net_pay,
            # The date the check and its stub print; the run's pay date unless this check has its own.
            effective_check_date: (item.check_date || pay_period.pay_date)&.iso8601
          }
          summary.merge(pay_item_breakdown(item))
        rescue PayrollComponentMirrors::AmbiguousHistoryError, PayrollInsuranceComponents::AmbiguousHistoryError => error
          Rails.logger.warn("Client pay line #{item.id} for company #{item.company_id}: #{error.class}: #{error.message}")
          Rails.error.report(error, handled: true, context: { company_id: item.company_id, payroll_item_id: item.id })
          summary.merge(details_error: PAY_LINE_DETAILS_UNAVAILABLE, pay_stub_available: false)
        end

        def pay_item_breakdown(item)
          breakdown = PayrollStatementYtdBreakdown.new(item)
          deduction_rows = breakdown.current_rows(:deduction)
          non_taxable_additions_total = breakdown.current_rows(:other_pay).sum(0.to_d, &:current).round(2)

          taxes_total = (
            item.withholding_tax.to_d +
            item.additional_withholding.to_d +
            item.social_security_tax.to_d +
            item.medicare_tax.to_d
          ).round(2)
          roth_retirement_total = deduction_rows
            .select { |row| row.semantic == PayrollReportingGroups::GROUP_401K_AFTER_TAX.to_sym }
            .sum(0.to_d, &:current).round(2)
          retirement_total = deduction_rows
            .select { |row| PayrollReportingGroups.retirement_group?(row.semantic.to_s) }
            .sum(0.to_d, &:current).round(2)
          traditional_retirement_total = (retirement_total - roth_retirement_total).round(2)
          loans_total = deduction_rows
            .select { |row| row.semantic == :loan }
            .sum(0.to_d, &:current).round(2)
          insurance_total = deduction_rows
            .select { |row| row.semantic == :insurance }
            .sum(0.to_d, &:current).round(2)
          other_deductions_total = (
            item.total_deductions.to_d - (taxes_total + retirement_total + loans_total + insurance_total)
          ).round(2)

          {
            non_taxable_additions_total: non_taxable_additions_total,
            retirement_payment: traditional_retirement_total,
            roth_retirement_payment: roth_retirement_total,
            loan_payment: loans_total,
            insurance_payment: insurance_total,
            other_deductions: other_deductions_total,
            withholding_tax: item.withholding_tax,
            additional_withholding: item.additional_withholding,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            additional_medicare_tax: item.additional_medicare_tax,
            state_withheld: 0,
            loan_deduction: item.loan_deduction,
            custom_deductions: item.custom_deductions || [],
            payroll_adjustments: item.payroll_adjustments || [],
            total_deductions: item.total_deductions
          }
        end

        def client_visible_period?(pay_period)
          return false unless pay_period
          return true if pay_period.client_finished?

          pay_period.client_payroll_approval_required? && pay_period.approved? &&
            pay_period.payroll_review_packages.current.where.not(published_at: nil).exists?
        end
      end
    end
  end
end
