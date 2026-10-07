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
          printer_profile_lock_version
        ].freeze
        CHECK_SETTINGS_PARAM_KEYS = (CHECK_SETTINGS_SCALAR_PARAMS + [ :check_layout_config ]).freeze

        before_action :set_pay_period,    only: [ :index, :rehearsal_preview_pdf, :batch_pdf, :mark_all_printed ]
        before_action :set_payroll_item,  only: [ :show, :mark_printed, :mark_delivered, :confirm_direct_deposit_payment, :void, :reprint, :update_check_number, :replace_preview, :replace_check ]
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
                             .includes(:time_tracking_entry_allocations, { check_events: :user }, employee: :department)
                             .left_outer_joins(:employee)
                             .reportable.with_check_number
                             .order("employees.last_name ASC, employees.first_name ASC, payroll_items.id ASC")

          loaded_items = items.to_a
          statement_items = @pay_period.payroll_items.not_voided.reportable
            .includes(:employee, :direct_deposit_payment_confirmation, :payroll_item_earnings, :payroll_item_deductions, :payroll_item_field_entries)
            .select { |item| EarningsStatementEligibility.printable?(item) }
