# frozen_string_literal: true

class SeedProductionPayScheduleFoundation < ActiveRecord::Migration[8.0]
  class MigrationCompany < ActiveRecord::Base
    self.table_name = "companies"
  end

  class MigrationPayPeriod < ActiveRecord::Base
    self.table_name = "pay_periods"
  end

  class MigrationPaySchedule < ActiveRecord::Base
    self.table_name = "company_pay_schedules"
  end

  class MigrationWorkweek < ActiveRecord::Base
    self.table_name = "company_workweeks"
  end

  CLIENT_RULES = [
    {
      matcher: /aire/i,
      frequency: "semimonthly",
      period_rule: "semimonthly",
      period_start_weekday: nil,
      pay_date_rule: "manual",
      pay_date_offset_days: nil,
      source: "production_inferred",
      notes: "Semimonthly 1st–15th and 16th–month-end pattern observed in production. Future pay dates remain manual pending employer review."
    },
    {
      matcher: /spike coffee/i,
      frequency: "biweekly",
      period_rule: "biweekly",
      period_start_weekday: 0,
      pay_date_rule: "days_after_period_end",
      pay_date_offset_days: 6,
      source: "production_inferred",
      notes: "Biweekly Sunday–Saturday periods with ordinary Friday pay dates observed in production."
    },
    {
      matcher: /mosa/i,
      frequency: "biweekly",
      period_rule: "biweekly",
      period_start_weekday: 1,
      pay_date_rule: "days_after_period_end",
      pay_date_offset_days: 4,
      source: "production_inferred",
      notes: "Recent test-ledger pattern is Monday–Sunday with Thursday pay dates. Reconfirm before live cutover."
    },
    {
      matcher: /cornerstone/i,
      frequency: "biweekly",
      period_rule: "manual",
      period_start_weekday: nil,
      pay_date_rule: "manual",
      pay_date_offset_days: nil,
      source: "legacy_system_default",
      notes: "Biweekly frequency retained; period and pay dates remain manual because production history is inconsistent."
    },
    {
      matcher: /shimizu technology/i,
      frequency: "biweekly",
      period_rule: "manual",
      period_start_weekday: nil,
      pay_date_rule: "manual",
      pay_date_offset_days: nil,
      source: "legacy_system_default",
      notes: "Biweekly frequency retained; period and pay dates remain manual pending confirmation."
    }
  ].freeze

  def up
    MigrationCompany.find_each do |company|
      rule = CLIENT_RULES.find { |candidate| company.name.to_s.match?(candidate.fetch(:matcher)) }
      rule ||= manual_rule(company)
      schedule_attributes, schedule_effective_on = schedule_configuration(company, rule)
      workweek_effective_on = company_periods(company).minimum(:start_date) || Date.new(2026, 8, 3)

      schedule = MigrationPaySchedule.find_or_initialize_by(company_id: company.id, effective_on: schedule_effective_on)
      schedule.assign_attributes(schedule_attributes)
      schedule.timezone = "Pacific/Guam"
      schedule.confirmation_status = "needs_confirmation"
      schedule.save!

      workweek = MigrationWorkweek.find_or_initialize_by(company_id: company.id, effective_on: workweek_effective_on)
      workweek.assign_attributes(
        starts_on_weekday: 0,
        starts_at_minutes: 0,
        timezone: "Pacific/Guam",
        source: "legacy_system_default",
        confirmation_status: "needs_confirmation",
        notes: "Sunday midnight preserves the legacy overtime calculator assumption. Employer confirmation is still required."
      )
      workweek.save!

      MigrationPayPeriod.where(company_id: company.id)
                        .where("start_date >= ?", schedule_effective_on)
                        .update_all(company_pay_schedule_id: schedule.id)
      MigrationPayPeriod.where(company_id: company.id)
                        .where("start_date >= ?", workweek_effective_on)
                        .update_all(company_workweek_id: workweek.id)
    end

    MigrationPayPeriod.where(correction_status: "correction").update_all(
      run_purpose: "correction",
      run_purpose_source: "system_correction"
    )
    MigrationPayPeriod.where(cycle: "supplemental").update_all(
      run_purpose: "correction",
      includes_base_salary: false,
      run_purpose_source: "system_correction"
    )

    spike = MigrationCompany.find { |company| company.name.to_s.match?(/spike coffee/i) }
    MigrationPayPeriod.where(id: 43, company_id: spike.id).update_all(
      run_purpose: "off_cycle_tips",
      includes_base_salary: false,
      run_purpose_source: "production_migration"
    ) if spike
  end

  def down
    MigrationPayPeriod.where(run_purpose_source: %w[system_correction production_migration]).update_all(
      run_purpose: "regular",
      includes_base_salary: true,
      run_purpose_source: "legacy_system_default"
    )
    MigrationPayPeriod.update_all(
      company_pay_schedule_id: nil,
      company_workweek_id: nil
    )
    MigrationPaySchedule.delete_all
    MigrationWorkweek.delete_all
  end

  private

  def schedule_configuration(company, rule)
    periods = company_periods(company).order(:start_date).to_a
    attributes = rule.except(:matcher).dup
    effective_on = periods.first&.start_date || Date.new(2026, 8, 3)

    case rule.fetch(:period_rule)
    when "semimonthly"
      matching_periods = periods.select { |period| semimonthly_period?(period) }
      effective_on = matching_periods.first&.start_date || effective_on
    when "biweekly"
      matching_periods = periods.select do |period|
        biweekly_period?(period, rule.fetch(:period_start_weekday))
      end
      # MoSa's older records are test/history data with inconsistent boundaries.
      # Seed only the recent three-period pattern that production showed us.
      matching_periods = matching_periods.last(3) if company.name.to_s.match?(/mosa/i)
      if matching_periods.any?
        effective_on = matching_periods.first.start_date
        attributes[:period_anchor_date] = effective_on
      else
        attributes[:period_rule] = "manual"
        attributes[:period_start_weekday] = nil
        attributes[:notes] = "#{attributes.fetch(:notes)} No consistent biweekly anchor was found, so period dates remain manual."
      end
    end

    [ attributes, effective_on ]
  end

  def company_periods(company)
    MigrationPayPeriod.where(company_id: company.id)
  end

  def biweekly_period?(period, start_weekday)
    period.start_date.present? && period.end_date.present? &&
      period.start_date.wday == start_weekday && (period.end_date - period.start_date).to_i == 13
  end

  def semimonthly_period?(period)
    return false if period.start_date.blank? || period.end_date.blank?

    first_half = period.start_date.day == 1 && period.end_date.day == 15 &&
      period.start_date.month == period.end_date.month
    second_half = period.start_date.day == 16 && period.end_date == period.end_date.end_of_month &&
      period.start_date.month == period.end_date.month
    first_half || second_half
  end

  def manual_rule(company)
    frequency = company.pay_frequency.presence_in(%w[weekly biweekly semimonthly monthly]) || "biweekly"
    {
      frequency: frequency,
      period_rule: "manual",
      period_start_weekday: nil,
      pay_date_rule: "manual",
      pay_date_offset_days: nil,
      source: "legacy_system_default",
      notes: "Existing company frequency retained. Dates remain manual until the employer confirms a schedule."
    }
  end
end
