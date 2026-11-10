# frozen_string_literal: true

module Api
  module V1
    module Integrations
      module Aire
        # Server-to-server reads for the AIRE worker app. AIRE signs in the worker
        # and proxies these requests with its source credential; Payroll resolves
        # the worker only through that source's saved employee mapping.
        class WorkerStatementsController < ActionController::API
          include ConnectedPayrollControl
          before_action :require_connected_payroll!
          before_action :authenticate_source!
          before_action :set_employee!
          before_action :set_statement_item!, only: %i[show pdf]

          UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

          def index
            items = statement_items
            record_access!("worker_statements#listed", record_type: "Employee", record_id: @employee.id, count: items.size)
            render json: { worker: worker_json, statements: items.map { |item| summary_json(item) } }
          end

          def show
            statement = PayStubGenerator.new(@item).statement
            record_access!("worker_statement#viewed", record_type: "PayrollItem", record_id: @item.id)
            render json: summary_json(@item).merge(
              earnings: statement.fetch(:earnings).map do |row|
                { label: row[:label], hours: hours(row[:hours]), rate: money(row[:rate]), amount: money(row[:amount]), ytd: money(row[:ytd]),
                  kind: row[:kind] }
              end,
              taxes: statement.fetch(:taxes).map { |row| amount_row(row) },
              deductions: statement.fetch(:deductions).map { |row| amount_row(row) },
              other_pay: statement.fetch(:other_pay).map { |row| amount_row(row) },
              ytd: { gross: money(statement.dig(:ytd, :gross)), net: money(statement.dig(:ytd, :net)) },
              source_entries: source_entries_json(@item)
            )
          end

          def pdf
            unless EarningsStatementEligibility.printable?(@item)
              return render json: { error: "This payroll record does not have a current earnings statement" }, status: :unprocessable_entity
            end

            generator = PayStubGenerator.new(@item)
            pdf_data = generator.generate
            record_access!("worker_statement#pdf_downloaded", record_type: "PayrollItem", record_id: @item.id)
            send_data pdf_data, filename: generator.filename, type: "application/pdf", disposition: "inline"
          end

          private

          # The events endpoint finds its source through the calendar period in
          # the payload. A read has no payload, so compare the credential with
          # every active AIRE source in constant time and require one match.
          def authenticate_source!
            secret = (request.headers["X-Shared-Secret"].presence || request.headers["X-Payroll-Shared-Secret"]).to_s
            matches = TimeTrackingSource.active.where(source_type: "aire_services").select do |source|
              expected = source.shared_secret.to_s
              expected.present? && secret.present? && expected.bytesize == secret.bytesize &&
                ActiveSupport::SecurityUtils.secure_compare(expected, secret)
            end
            return @source = matches.first if matches.one?

            Rails.logger.warn("AIRE worker statement credential matched #{matches.size} active sources") if matches.many?
            render json: { error: "Invalid AIRE integration credentials" }, status: :unauthorized
          end

          def set_employee!
            mapping = TimeTrackingEmployeeMapping.find_by(
              time_tracking_source_id: @source.id, company_id: @source.company_id, source_user_uuid: source_user_uuid
            ) if source_user_uuid
            @employee = Employee.find_by(id: mapping.employee_id, company_id: @source.company_id) if mapping
            not_found unless @employee
          end

          # Load the statement as the staff pay stub route does, not from the
          # list preload, so rows print and serialize in the same order.
          def set_statement_item!
            listed = statement_items.find { |item| item.id.to_s == params[:id].to_s }
            return not_found unless listed

            @item = PayrollItem.includes(:payroll_item_earnings, :payroll_item_field_entries, :time_tracking_entry_allocations,
              { payroll_item_deductions: :deduction_type, employee: :department, pay_period: :company }).find(listed.id)
          end

          def source_user_uuid
            value = params[:source_user_uuid].to_s.downcase
            value if UUID_FORMAT.match?(value)
          end

          # Every committed paycheck for this worker in this company, newest first.
          # Reversed and voided payroll stays listed as voided history; roster rows
          # without statement activity are not statements.
          def statement_items
            @statement_items ||= @employee.payroll_items.reportable
              .joins(:pay_period)
              .where(company_id: @source.company_id, pay_periods: { company_id: @source.company_id, status: "committed" })
              .includes(:pay_period, :check_events, :direct_deposit_payment_confirmation, :payroll_item_earnings,
                :payroll_item_deductions, :payroll_item_field_entries, :time_tracking_entry_allocations)
              .order("pay_periods.pay_date DESC, pay_periods.id DESC, payroll_items.id DESC")
              .select { |item| EarningsStatementEligibility.printable?(item) || voided_history?(item) }
          end

          def voided_history?(item)
            !item.payroll_included? && (item.gross_pay.to_d.nonzero? || item.net_pay.to_d.nonzero? || item.check_number.present?)
          end

          def worker_json
            {
              employment_type: @employee.employment_type,
              contractor: @employee.contractor?,
              display_name: [ @employee.first_name, @employee.last_name ].compact_blank.join(" ")
            }
          end

          def summary_json(item)
            period = item.pay_period
            {
              id: item.id,
              pay_period: {
                start_date: period.start_date&.iso8601, end_date: period.end_date&.iso8601,
                pay_date: period.pay_date&.iso8601, run_purpose: period.run_purpose
              },
              check_date: (item.check_date || period.pay_date)&.iso8601,
              gross_pay: money(item.gross_pay),
              net_pay: money(item.net_pay),
              total_hours: hours(item.total_hours),
              payment: payment_json(item),
              has_source_entries: item.time_tracking_entry_allocations.any?
            }
          end

          # Status follows the recorded payment evidence, the same rules as the
          # employee pay history and AIRE payment receipts: delivered checks and
          # confirmed transfers are issued; prepared or printed checks are
          # prepared; voided checks and reversed or voided payroll are voided.
          def payment_json(item)
            method = item.effective_payment_delivery_method
            evidence = EmployeePayrollPaymentEvidence.new(item).call
            status = if !item.payroll_included?
              "voided"
            else
              { "voided" => "voided", "issued" => "issued", "printed" => "prepared", "prepared" => "prepared" }.fetch(evidence[:status], "pending")
            end
            {
              method: method,
              status: status,
              issued_on: (evidence[:effective_on]&.iso8601 if status == "issued"),
              check_number_last4: (item.check_number.to_s.last(4).presence if method == "paper_check")
            }
          end

          def source_entries_json(item)
            item.time_tracking_entry_allocations.sort_by { |row| [ row.original_work_date, row.source_time_entry_id.to_s, row.id ] }.map do |row|
              {
                source_time_entry_id: row.source_time_entry_id.to_s,
                work_date: row.original_work_date.iso8601,
                hours: hours(row.total_hours),
                regular_hours: hours(row.regular_hours),
                overtime_hours: hours(row.overtime_hours),
                source_kind: row.source_kind,
                category: row.category_snapshot.to_h["name"]
              }
            end
          end

          def amount_row(row)
            { label: row[:label], amount: money(row[:amount]), ytd: money(row[:ytd]) }
          end

          def money(value)
            return nil if value.nil?

            format("%.2f", value.to_d.round(2))
          end

          def hours(value)
            return nil if value.nil?

            format("%.2f", value.to_d.round(2))
          end

          def record_access!(action, record_type:, record_id:, count: nil)
            AuditLog.record!(
              user: nil,
              company_id: @source.company_id,
              action: action,
              record_type: record_type,
              record_id: record_id,
              subject_name: @employee.full_name,
              metadata: {
                employee_id: @employee.id,
                payroll_item_id: (@item&.id),
                time_tracking_source_id: @source.id,
                source_user_uuid: source_user_uuid,
                statement_count: count
              }.compact,
              ip_address: request.remote_ip,
              user_agent: request.user_agent,
              request_id: request.request_id,
              event_category: "integration"
            )
          end

          def not_found
            render json: { error: "Not found" }, status: :not_found
          end
        end
      end
    end
  end
end
