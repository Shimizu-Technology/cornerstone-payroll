# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Client profitability: setup, "Refresh hours from Tax", linking Tax
      # clients and staff to Payroll records, the report and its CSV.
      # Admin-only (view_client_profitability). See docs/CLIENT_PROFITABILITY.md.
      class ClientProfitabilityController < BaseController
        BOOLEAN = ActiveModel::Type::Boolean.new

        before_action :resolve_profitability_organization!

        def show
          render json: overview
        end

        def update_settings
          saved = ClientProfitabilitySetting.transaction do
            settings.assign_attributes(settings_params.merge(updated_by: current_user))
            company_changed = settings.practice_company_id_changed?
            next false unless settings.save

            # Links to the old staff payroll client's employees would carry no
            # cost; they go back to "needs linking".
            settings.deactivate_stale_staff_links! if company_changed
            true
          end
          if saved
            render json: overview
          else
            render json: { error: settings.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        end

        def refresh
          configuration = TaxWorkHours::Configuration.current
          unless configuration.connected?
            return render json: { error: TaxWorkHours::Error.new("not_connected").message, code: "not_connected" }, status: :unprocessable_entity
          end

          period = ClientProfitability::Period.parse(params[:from], params[:through])
          today = PayrollBusinessClock.today
          if period.start_date > today
            return render json: { error: "Choose months that have already started." }, status: :unprocessable_entity
          end

          import = WorkHourImport.reserve!(organization: current_organization, requested_by: current_user, trigger: "manual",
                                           range_start: period.start_date, range_end: [ period.end_date, today ].min)
          enqueued = begin
            TaxWorkHoursImportJob.perform_later(import.id)
          rescue StandardError => e
            Rails.logger.error("[TaxWorkHours] could not enqueue import #{import.id}: #{e.class}")
            false
          end
          unless enqueued
            # Release the reservation so the next refresh isn't blocked.
            WorkHourImport.where(id: import.id, status: "queued")
                          .update_all(status: "failed", finished_at: Time.current, lease_expires_at: nil, error_code: "not_queued",
                                      error_message: "Payroll couldn't start the refresh. Nothing was changed. Try again in a minute.",
                                      updated_at: Time.current)
            import.reload
            return render json: { error: import.error_message, code: "not_queued", import: import.as_status_json }, status: :service_unavailable
          end

          render json: { import: import.as_status_json }, status: :accepted
        rescue WorkHourImport::Busy => e
          render json: { error: e.message, code: "in_progress" }, status: :conflict
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def import_status
          import = WorkHourImport.find_by(id: params[:import_id], organization_id: current_organization.id)
          return render json: { error: "Refresh not found" }, status: :not_found unless import

          render json: { import: import.as_status_json }
        end

        def links
          render json: ClientProfitability::LinkQueue.new(organization: current_organization, settings: settings).call
        end

        def link_client
          link = WorkHourClientLink.find_or_initialize_by(organization: current_organization, tax_client_id: tax_id(:tax_client_id))
          disposition = params[:disposition].to_s
          company = disposition == "company" ? Company.find_by(id: params[:company_id], organization_id: current_organization.id) : nil
          recipient = disposition == "recipient" ? InvoiceRecipient.find_by(id: params[:invoice_recipient_id], organization_id: current_organization.id) : nil
          link.assign_attributes(active: true, disposition: disposition, company: company, invoice_recipient: recipient, linked_by: current_user,
                                 tax_client_name: params[:tax_client_name].to_s.strip.presence || link.tax_client_name)
          save_link(link)
        end

        def unlink_client
          WorkHourClientLink.active.where(organization: current_organization, tax_client_id: tax_id(:tax_client_id))
                            .update_all(active: false, linked_by_id: current_user.id, updated_at: Time.current)
          head :no_content
        end

        def link_staff
          link = WorkHourStaffLink.find_or_initialize_by(organization: current_organization, tax_user_id: tax_id(:tax_user_id))
          disposition = params[:disposition].to_s
          employee = nil
          if disposition == "employee"
            practice = settings.effective_practice_company
            unless practice
              return render json: { error: "Choose the client that runs Cornerstone's own staff payroll first." }, status: :unprocessable_entity
            end

            employee = Employee.find_by(id: params[:employee_id], company_id: practice.id)
            return render json: { error: "Choose an employee of #{practice.name}." }, status: :unprocessable_entity unless employee
          end
          link.assign_attributes(active: true, disposition: disposition, employee: employee, linked_by: current_user,
                                 email: params[:email].to_s.strip.downcase.presence || link.email)
          save_link(link)
        end

        def unlink_staff
          WorkHourStaffLink.active.where(organization: current_organization, tax_user_id: tax_id(:tax_user_id))
                           .update_all(active: false, linked_by_id: current_user.id, updated_at: Time.current)
          head :no_content
        end

        def report
          render json: build_report.merge(connection: TaxWorkHours::Configuration.current.status_json)
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def export
          csv = ClientProfitability::CsvExport.new(build_report)
          send_data csv.generate, filename: csv.filename, type: "text/csv; charset=utf-8", disposition: "attachment"
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        # The organization chosen in the switcher, sent as X-Organization-Id
        # and validated like the finance controllers do: a super admin may
        # name any organization (and must name one), everyone else only their
        # own. This controller is not a finance request, so the selected
        # financial book header is ignored and the saved book is used.
        def resolve_profitability_organization!
          raw = request.headers["X-Organization-Id"].presence
          if raw.nil?
            return render json: { error: "Select an organization" }, status: :unprocessable_entity if current_user.super_admin?

            @profitability_organization = current_user.organization
          else
            return render json: { error: "Invalid organization context" }, status: :unprocessable_entity unless raw.to_s.match?(/\A[1-9]\d*\z/)

            organization = Organization.find_by(id: raw.to_i)
            return render json: { error: "Organization not found" }, status: :not_found unless organization
            unless current_user.super_admin? || organization.id == current_user.organization_id
              return render json: { error: "You do not have access to this organization" }, status: :forbidden
            end

            @profitability_organization = organization
          end
          render json: { error: "Select an organization" }, status: :unprocessable_entity unless @profitability_organization
        end

        def current_organization
          @profitability_organization
        end

        def settings
          @settings ||= ClientProfitabilitySetting.for(current_organization)
        end

        def settings_params
          permitted = params.permit(:practice_company_id, :finance_book_id, :default_cost_pending, :default_spread_overhead,
                                    :default_period, :cost_basis, tax_prep_service_names: [])
          permitted[:tax_prep_service_names] = [] if params.key?(:tax_prep_service_names) && params[:tax_prep_service_names].blank?
          permitted
        end

        def tax_id(name)
          value = params[name].to_s
          raise ActionController::BadRequest, "Invalid #{name}" unless value.match?(/\A[1-9]\d{0,17}\z/)

          value.to_i
        end

        def save_link(link)
          if link.save
            render json: { ok: true }
          else
            render json: { error: link.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        end

        def build_report
          ClientProfitability::Report.new(
            organization: current_organization,
            settings: settings,
            period: ClientProfitability::Period.parse(params[:from], params[:through]),
            cost_pending: BOOLEAN.cast(params[:cost_pending]) == true,
            spread_overhead: BOOLEAN.cast(params[:spread_overhead]) == true,
            # The basis the report on screen was built with, so its CSV matches
            # it even if someone changes the saved setting in between.
            cost_basis: params[:cost_basis].presence&.to_s
          ).call
        end

        def overview
          imports = WorkHourImport.where(organization_id: current_organization.id).includes(:requested_by).recent_first.limit(5)
          queue = ClientProfitability::LinkQueue.new(organization: current_organization, settings: settings).call
          book = settings.effective_finance_book
          {
            connection: TaxWorkHours::Configuration.current.status_json,
            settings: {
              practice_company_id: settings.practice_company_id,
              finance_book_id: settings.finance_book_id,
              effective_finance_book_id: book&.id,
              tax_prep_service_names: settings.tax_prep_service_names,
              default_cost_pending: settings.default_cost_pending,
              default_spread_overhead: settings.default_spread_overhead,
              default_period: settings.default_period,
              cost_basis: settings.cost_basis
            },
            options: {
              companies: queue[:companies],
              finance_books: FinanceBook.active.where(organization_id: current_organization.id).where.not(kind: "personal")
                                        .ordered.map { |finance_book| { id: finance_book.id, name: finance_book.name } },
              service_names: service_names(book)
            },
            imports: imports.map(&:as_status_json),
            has_hours: WorkHourRow.exists?(organization_id: current_organization.id),
            needs_linking: {
              clients: queue[:clients].count { |client| client[:link].nil? && !client[:handled_automatically] },
              staff: queue[:staff].count { |person| person[:link].nil? }
            }
          }
        end

        # Saved services from the book's senders plus product/service names
        # already used on issued fee lines, for choosing what is tax prep.
        def service_names(book)
          return [] unless book

          catalog = book.invoice_billing_profiles.flat_map { |profile| Array(profile.service_catalog) }
                        .filter_map { |entry| entry["name"] if entry.is_a?(Hash) && entry["line_kind"] == "service_fee" }
          used = InvoiceLineItem.joins(:invoice).where(invoices: { finance_book_id: book.id }, line_kind: "service_fee")
                                .where.not(item_name: "").distinct.limit(200).pluck(:item_name)
          (catalog + used).map(&:squish).uniq { |name| name.downcase }.sort_by(&:downcase)
        end
      end
    end
  end
end
