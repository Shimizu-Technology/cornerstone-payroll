# frozen_string_literal: true

module TrainingReplay
  class Preview
    PRACTICE_PERIOD_COUNT = 2

    def initialize(source_company:)
      @source_company = source_company
    end

    def call
      blockers = []
      blockers << "Choose a live client as the training source" unless source_company.live_payroll?
      blockers << "Archive the existing training replay before creating another" if active_replay
      blockers << "At least two completed regular payrolls are required" if candidate_periods.length < PRACTICE_PERIOD_COUNT
      if candidate_periods.length == PRACTICE_PERIOD_COUNT && candidate_periods.any? { |period| !period.committed? }
        blockers << "Commit both latest payrolls before creating their immutable training benchmarks"
      end
      blockers << "Add an active manager or accountant before creating a training replay" if assignable_staff.empty?

      {
        source_company: { id: source_company.id, name: source_company.name },
        ready: blockers.empty?,
        blockers: blockers,
        warnings: warnings,
        existing_replay: active_replay && company_summary(active_replay),
        practice_periods: candidate_periods.reverse.map { |period| period_summary(period) },
        copy_summary: copy_summary,
        assignable_staff: assignable_staff
      }
    end

    def practice_periods
      return [] if planned_practice_periods.empty? || !planned_practice_periods.all?(&:committed?)

      planned_practice_periods
    end

    private

    attr_reader :source_company

    def candidate_periods
      @candidate_periods ||= source_company.pay_periods
        .reportable_periods
        .regular_cycle
        .where(status: %w[calculated approved committed])
        .period_reverse_chronological
        .limit(PRACTICE_PERIOD_COUNT)
        .to_a
    end

    def baseline_periods
      return PayPeriod.none unless planned_practice_periods.any?

      first = planned_practice_periods.first
      source_company.pay_periods
        .reportable_committed
        .regular_cycle
        .where(pay_date: first.pay_date.beginning_of_year..)
        .where("pay_date < ? OR (pay_date = ? AND id < ?)", first.pay_date, first.pay_date, first.id)
    end

    def planned_practice_periods
      return [] unless candidate_periods.length == PRACTICE_PERIOD_COUNT

      candidate_periods.reverse
    end

    def active_replay
      @active_replay ||= source_company.test_workspaces
        .where(test_workspace_purpose: "training_replay", test_workspace_archived_at: nil, active: true)
        .order(created_at: :desc)
        .first
    end

    def copy_summary
      {
        employees: source_company.employees.count,
        active_employees: source_company.employees.active.count,
        baseline_pay_periods: baseline_periods.count,
        practice_pay_periods: planned_practice_periods.count
      }
    end

    def assignable_staff
      @assignable_staff ||= source_company.organization.users.active.where(role: %w[manager accountant]).order(:name, :email).map do |user|
        { id: user.id, name: user.name, email: user.email, role: user.role }
      end
    end

    def warnings
      [
        "This copies protected employee and payroll data inside the same Cornerstone organization.",
        "The two practice runs contain source inputs, but no source calculation results, check numbers, payment state, filings, messages, documents, or external connections.",
        "Older committed payroll is retained as locked baseline evidence so practice calculations use the correct year-to-date context.",
        "Every training payroll is isolated from live payroll and cannot be committed, paid, filed, printed, or communicated to clients."
      ]
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

    def company_summary(company)
      { id: company.id, name: company.name, status: company.migration_rehearsal_status }
    end
  end
end
