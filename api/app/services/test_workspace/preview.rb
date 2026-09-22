# frozen_string_literal: true

module TestWorkspace
  class Preview
    COPY_MODES = %w[setup_only all_committed exclude_recent through_pay_period].freeze
    EXCLUDED_PAYROLL_RANGE = 1..12

    def initialize(source_company:, copy_mode: "all_committed", excluded_payrolls: 2, cutoff_pay_period_id: nil)
      @source_company = source_company
      @copy_mode = copy_mode.to_s
      @excluded_payrolls = excluded_payrolls.to_i
      @cutoff_pay_period_id = cutoff_pay_period_id.to_i if cutoff_pay_period_id.present?
    end

    def call
      blockers = validation_errors
      selected = blockers.empty? ? selected_periods : []

      {
        source_company: { id: source_company.id, name: source_company.name },
        ready: blockers.empty?,
        blockers: blockers,
        warnings: warnings,
        copy_mode: copy_mode,
        excluded_payrolls: copy_mode == "exclude_recent" ? excluded_payrolls : 0,
        cutoff_pay_period_id: copy_mode == "through_pay_period" ? cutoff_pay_period_id : nil,
        copy_summary: {
          employees: source_company.employees.count,
          active_employees: source_company.employees.active.count,
          committed_payrolls_available: committed_periods.length,
          payrolls_to_copy: selected.length,
          recent_payrolls_excluded: excluded_periods.length,
          open_payrolls_not_copied: open_periods.length,
          other_open_payrolls_not_copied: open_periods.where.not(id: excluded_periods.map(&:id)).count
        },
        recent_payrolls: recent_periods.map { |period| period_summary(period) },
        assignable_staff: assignable_staff
      }
    end

    def selected_periods
      @selected_periods ||= case copy_mode
      when "setup_only"
        []
      when "all_committed"
        committed_periods
      when "exclude_recent"
        boundary = excluded_periods.last
        boundary ? committed_periods.select { |period| (period_key(period) <=> period_key(boundary)).negative? } : []
      when "through_pay_period"
        boundary = cutoff_period
        boundary ? committed_periods.select { |period| (period_key(period) <=> period_key(boundary)) <= 0 } : []
      else
        []
      end
    end

    private

    attr_reader :source_company, :copy_mode, :excluded_payrolls, :cutoff_pay_period_id

    def validation_errors
      errors = []
      errors << "Choose a production client as the source" unless source_company.live_payroll?
      errors << "Choose a supported copy option" unless copy_mode.in?(COPY_MODES)
      if copy_mode == "exclude_recent"
        errors << "Choose between 1 and 12 recent payrolls to leave out" unless EXCLUDED_PAYROLL_RANGE.cover?(excluded_payrolls)
        errors << "This client does not have enough payrolls to leave out" if recent_periods.length < excluded_payrolls
      end
      if copy_mode == "through_pay_period"
        errors << "Choose the last payroll to include" unless cutoff_period
      end
      errors
    end

    def committed_periods
      @committed_periods ||= source_company.pay_periods
        .reportable_committed
        .period_chronological
        .to_a
    end

    def recent_periods
      @recent_periods ||= source_company.pay_periods
        .reportable_periods
        .regular_cycle
        .where(status: %w[draft calculated approved committed])
        .period_reverse_chronological
        .limit(24)
        .to_a
    end

    def excluded_periods
      return [] unless copy_mode == "exclude_recent" && EXCLUDED_PAYROLL_RANGE.cover?(excluded_payrolls)

      recent_periods.first(excluded_payrolls)
    end

    def cutoff_period
      return unless cutoff_pay_period_id

      @cutoff_period ||= recent_periods.find { |period| period.id == cutoff_pay_period_id }
    end

    def open_periods
      @open_periods ||= source_company.pay_periods
        .reportable_periods
        .where(status: %w[draft calculated approved])
    end

    def assignable_staff
      @assignable_staff ||= source_company.organization.users.active
        .where(role: %w[manager accountant])
        .order(:name, :email)
        .map { |user| { id: user.id, name: user.name, email: user.email, role: user.role } }
    end

    def warnings
      messages = [
        "The production client stays unchanged. The copy cannot commit payroll, issue checks, move money, file returns, send reminders, or sync external systems.",
        "Copied payroll history is locked reference data. Staff can create and process new practice payrolls in the workspace.",
        "Check numbers, payment state, filings, messages, documents, and external connections are never copied."
      ]
      if historical_ytd_opening_balances?
        messages << "This client has imported opening YTD balances. A general workspace copies Cornerstone payroll history, not the imported source archive; use a verified migration rehearsal when exact migration evidence is required."
      end
      messages
    end

    def historical_ytd_opening_balances?
      HistoricalEmployeeYtdBalance
        .joins(:historical_ytd_bridge)
        .where(company_id: source_company.id, historical_ytd_bridges: { status: "applied" })
        .exists?
    end

    def period_key(period)
      [ period.start_date || Date.new(1900, 1, 1), period.end_date || Date.new(1900, 1, 1), period.pay_date || Date.new(1900, 1, 1), period.id ]
    end

    def period_summary(period)
      {
        id: period.id,
        start_date: period.start_date,
        end_date: period.end_date,
        pay_date: period.pay_date,
        status: period.status,
        employee_count: period.payroll_items.not_voided.distinct.count(:employee_id)
      }
    end
  end
end
