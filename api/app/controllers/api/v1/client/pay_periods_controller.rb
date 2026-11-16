# frozen_string_literal: true

module Api
  module V1
    module Client
      class PayPeriodsController < BaseController
        audit_actions :approve_review
        before_action :set_pay_period, only: %i[show approve_review request_changes preview_pdf]

        def index
          result = PayrollHistoryQuery.new(
            company_id: current_company_id,
            params: params,
            audience: :client
          ).call
          render json: {
            pay_periods: result.data,
            meta: result.meta
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
          )
          render json: { payroll_review: PayrollReview::PackagePresenter.call(review_package) }
        rescue PayrollReview::RevisionService::StaleRevisionError => e
          render json: { error: e.message, code: "stale_payroll_review_revision" }, status: :unprocessable_entity
        rescue PayrollReview::RevisionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def request_changes
          return render json: { error: "A client portal user must request changes." }, status: :forbidden unless current_user&.client?

          package = PayrollReview::RevisionService.new(pay_period: @pay_period, actor: current_user)
            .request_changes!(revision_id: params[:revision_id], note: params[:note])
          render json: { payroll_review: PayrollReview::PackagePresenter.call(package) }
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
          send_data pdf, type: "application/pdf", disposition: "attachment",
            filename: "Payroll_PREVIEW_#{@pay_period.pay_date.iso8601}_rev#{package.revision}.pdf"
        rescue PayrollReview::RevisionService::StaleRevisionError => e
          render json: { error: e.message, code: "stale_payroll_review_revision" }, status: :unprocessable_entity
        rescue PayrollReview::RevisionService::Error, ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::ActiveRecordError
          render json: { error: "Could not record the preview download. Try again." }, status: :service_unavailable
        end

        private

        def current_preview_package!
          unless Company.find(@pay_period.company_id).client_payroll_approval_required?
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
          @pay_period = scope.includes(payroll_items: :employee).find_by(id: params[:id])
          @pay_period = nil unless client_visible_period?(@pay_period)
          return if @pay_period

          render json: { error: "Pay period not found" }, status: :not_found
        end

        def pay_period_summary(pay_period, include_items: false)
          items = pay_period.payroll_items.reportable.select(&:payroll_included?)
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

          json[:client_payroll_approval_required] = pay_period.company.client_payroll_approval_required?
          json[:payroll_review] = pay_period.company.client_payroll_approval_required? ? PayrollReview::PackagePresenter.call(
            pay_period.payroll_review_packages.summary.current.where.not(published_at: nil).includes(:generated_by, :approved_by, :approval_recorded_by).order(revision: :desc).first
          ) : nil

          if include_items
            json[:payroll_review_history] = pay_period.payroll_review_packages.where.not(published_at: nil)
              .select(PayrollReviewPackage.column_names - %w[calculation_snapshot source_manifest])
              .includes(:generated_by, :approved_by, :approval_recorded_by, :changes_requested_by).order(revision: :desc)
              .map { |package| PayrollReview::PackagePresenter.call(package, include_source_manifest: false) }
            json[:payroll_review_history] = [] unless pay_period.company.client_payroll_approval_required?
            json[:payroll_items] = items.map do |item|
              {
                id: item.id,
                pay_stub_available: pay_period.client_finished? && EarningsStatementEligibility.printable?(item),
                employee_id: item.employee_id,
                employee_name: item.employee_full_name,
                employment_type: item.employment_type,
                pay_rate: item.pay_rate,
                total_hours: item.total_hours,
                hours_worked: item.hours_worked,
                overtime_hours: item.overtime_hours,
                gross_pay: item.gross_pay,
                withholding_tax: item.withholding_tax,
                social_security_tax: item.social_security_tax,
                medicare_tax: item.medicare_tax,
                additional_medicare_tax: item.additional_medicare_tax,
                state_withheld: 0,
                retirement_payment: item.retirement_payment,
                roth_retirement_payment: item.roth_retirement_payment,
                loan_payment: item.loan_payment,
                loan_deduction: item.loan_deduction,
                insurance_payment: item.insurance_payment,
                custom_deductions: item.custom_deductions || [],
                payroll_adjustments: item.payroll_adjustments || [],
                total_deductions: item.total_deductions,
                net_pay: item.net_pay
              }
            end
          end

          json
        end

        def client_visible_period?(pay_period)
          return false unless pay_period
          return true if pay_period.client_finished?

          pay_period.company.client_payroll_approval_required? && pay_period.approved? &&
            pay_period.payroll_review_packages.current.where.not(published_at: nil).exists?
        end
      end
    end
  end
end
