# frozen_string_literal: true

class PayrollTimeAllocationService
  class Error < StandardError; end

  WEEKLY_OVERTIME_THRESHOLD = 40.to_d

  def self.call!(payroll_item:, ledger_key: "authoritative", generated_source: "schedule")
    new(payroll_item:, ledger_key:, generated_source:).call!
  end

  def initialize(payroll_item:, ledger_key:, generated_source:)
    @payroll_item = payroll_item
    @employee = payroll_item.employee
    @pay_period = payroll_item.pay_period
    @ledger_key = ledger_key
    @generated_source = generated_source
  end

  def call!
    profile = @employee.work_profile_on(@pay_period.end_date)
    return preserve_existing_hours!(profile) unless allocatable_profile?(profile)

    profiles = profiles_for_full_workweeks
    if profiles.many?
      raise Error,
            "More than one salary work profile overlaps the legal workweeks for this payroll; " \
            "review the effective date or split the payroll before calculating"
    end

    ApplicationRecord.transaction do
      @payroll_item.save! if @payroll_item.new_record?
      ensure_scheduled_records!(profile) if profile.timekeeping_mode == "schedule_with_exceptions"
      records = current_records_for_period
      return preserve_existing_hours!(profile) if records.empty?

      allocations = build_allocations(records, profile)
      unresolved_overtime = allocations.sum { |row| row[:overtime_hours] }
      if profile.overtime_status == "needs_review" && unresolved_overtime.positive?
        profile.errors.add(:overtime_status, "must be confirmed before paying salary hours above 40 in a legal workweek")
        raise ActiveRecord::RecordInvalid.new(profile)
      end
      @payroll_item.payroll_time_allocations.where(ledger_key: @ledger_key).delete_all
      allocations.each do |attributes|
        @payroll_item.payroll_time_allocations.create!(
          attributes.except(:salary_covered_overtime_hours, :salary_uncovered_overtime_hours)
        )
      end

      @payroll_item.scheduled_hours = allocations.sum { |row| row[:scheduled_hours] }
      @payroll_item.hours_worked = allocations.sum { |row| row[:regular_hours] }
      @payroll_item.overtime_hours = profile.nonexempt? ? allocations.sum { |row| row[:overtime_hours] } : 0
      @payroll_item.pto_hours = allocations.sum { |row| row[:pto_hours] }
      @payroll_item.holiday_hours = allocations.sum { |row| row[:holiday_hours] }
      @payroll_item.timekeeping_source = source_for(records)
      @payroll_item.timekeeping_context_snapshot = profile_snapshot(profile, allocations: allocations)
      @payroll_item.save!
      @payroll_item
    end
  end

  private

  def allocatable_profile?(profile)
    timekeeping_run = @pay_period.regular_run? || @pay_period.correction_run?
    @employee.salary? && profile&.confirmed? && profile.pay_basis == "salary" &&
      timekeeping_run && @pay_period.includes_base_salary?
  end

  def preserve_existing_hours!(profile)
    if profile
      @payroll_item.timekeeping_context_snapshot = profile_snapshot(profile)
      @payroll_item.timekeeping_source ||= "manual" if @payroll_item.hours_worked.to_d.positive?
    end
    @payroll_item
  end

  def ensure_scheduled_records!(profile)
    full_range.each do |date|
      next unless eligible_work_date?(date)
      next if date < profile.effective_on || (profile.ends_on.present? && date > profile.ends_on)

      DailyTimeRecord.current.find_or_create_by!(employee: @employee, work_date: date, ledger_key: @ledger_key) do |record|
        record.company = @employee.company
        record.employee_work_profile = profile
        record.workweek_started_on = workweek_start(date)
        record.scheduled_hours = profile.scheduled_hours_for(date)
        record.source = @generated_source
      end
    end
  end

  def current_records_for_period
    DailyTimeRecord.current
      .where(employee: @employee, ledger_key: @ledger_key, work_date: @pay_period.start_date..@pay_period.end_date)
      .order(:work_date)
      .to_a
  end

  def profiles_for_full_workweeks
    @employee.employee_work_profiles
      .where("effective_on <= ? AND (ends_on IS NULL OR ends_on >= ?)", full_range.end, full_range.begin)
      .order(:effective_on)
      .to_a
  end

  def build_allocations(period_records, profile)
    week_starts = period_records.map(&:workweek_started_on).uniq
    all_records = DailyTimeRecord.current.where(
      employee: @employee,
      ledger_key: @ledger_key,
      workweek_started_on: week_starts
    ).order(:work_date).group_by(&:workweek_started_on)

    overtime_by_id = {}
    salary_overtime_by_id = {}
    salary_covered_hours = profile.salary_covers_weekly_hours || 0.to_d
    salary_covered_overtime_limit = [ salary_covered_hours - WEEKLY_OVERTIME_THRESHOLD, 0.to_d ].max
    all_records.each_value do |records|
      cumulative = 0.to_d
      cumulative_overtime = 0.to_d
      records.each do |record|
        worked = worked_hours(record)
        regular = [ [ WEEKLY_OVERTIME_THRESHOLD - cumulative, 0.to_d ].max, worked ].min
        overtime = [ worked - regular, 0.to_d ].max
        overtime_by_id[record.id] = overtime
        covered_overtime = if profile.nonexempt?
          [ [ salary_covered_overtime_limit - cumulative_overtime, 0.to_d ].max, overtime ].min
        else
          0.to_d
        end
        salary_overtime_by_id[record.id] = {
          covered: covered_overtime,
          uncovered: overtime - covered_overtime
        }
        cumulative += worked
        cumulative_overtime += overtime
      end
    end

    period_records.map do |record|
      worked = worked_hours(record)
      overtime = overtime_by_id.fetch(record.id, 0.to_d)
      salary_overtime = salary_overtime_by_id.fetch(record.id, { covered: 0.to_d, uncovered: overtime })
      {
        company: @employee.company,
        employee: @employee,
        daily_time_record: record,
        work_date: record.work_date,
        scheduled_hours: record.scheduled_hours,
        regular_hours: worked - overtime,
        overtime_hours: overtime,
        salary_covered_overtime_hours: salary_overtime[:covered],
        salary_uncovered_overtime_hours: salary_overtime[:uncovered],
        pto_hours: record.pto_hours,
        holiday_hours: record.holiday_hours,
        source: record.source,
        ledger_key: @ledger_key
      }
    end
  end

  def worked_hours(record)
    record.worked_hours
  end

  def full_range
    workweek_start(@pay_period.start_date)..(workweek_start(@pay_period.end_date) + 6.days)
  end

  def workweek_start(date)
    start_weekday = @pay_period.resolved_company_workweek&.starts_on_weekday || 0
    date = date.to_date
    date - ((date.wday - start_weekday) % 7).days
  end

  def eligible_work_date?(date)
    @employee.eligible_on?(date)
  end

  def source_for(records)
    sources = records.map(&:source).uniq
    sources.one? ? sources.first : "manual"
  end

  def profile_snapshot(profile, allocations: nil)
    snapshot = {
      "employee_work_profile_id" => profile.id,
      "effective_on" => profile.effective_on.iso8601,
      "pay_basis" => profile.pay_basis,
      "salary_type" => @employee.salary_type,
      "pay_frequency" => @employee.pay_frequency,
      "overtime_status" => profile.overtime_status,
      "exemption_category" => profile.exemption_category,
      "standard_weekly_hours" => profile.standard_weekly_hours&.to_f,
      "salary_covers_weekly_hours" => profile.salary_covers_weekly_hours&.to_f,
      "salary_coverage_reason" => profile.salary_coverage_reason,
      "timekeeping_mode" => profile.timekeeping_mode,
      "daily_schedule" => profile.daily_schedule,
      "company_workweek_id" => @pay_period.resolved_company_workweek&.id,
      "ledger_key" => @ledger_key
    }
    snapshot["salary_covered_overtime_hours"] = (allocations&.sum { |row| row[:salary_covered_overtime_hours] } || 0).to_f
    snapshot["salary_uncovered_overtime_hours"] = (allocations&.sum { |row| row[:salary_uncovered_overtime_hours] } || 0).to_f
    snapshot
  end
end
