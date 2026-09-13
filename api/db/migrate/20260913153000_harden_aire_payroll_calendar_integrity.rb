# frozen_string_literal: true

class HardenAirePayrollCalendarIntegrity < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :company_pay_schedules,
                            name: "company_pay_schedules_cutoff_days_check"
    add_check_constraint :company_pay_schedules,
                         "payroll_cutoff_days_before = 7",
                         name: "company_pay_schedules_cutoff_days_check"

    add_index :time_tracking_sources,
              [ :id, :company_id ],
              unique: true,
              name: "idx_time_tracking_sources_tenant_key"
    add_index :pay_periods,
              [ :id, :company_id ],
              unique: true,
              name: "idx_pay_periods_aire_calendar_tenant_key"
    add_index :aire_payroll_calendar_publications,
              [ :id, :aire_payroll_calendar_period_id ],
              unique: true,
              name: "idx_aire_calendar_publications_period_key"

    add_foreign_key :aire_payroll_calendar_periods,
                    :time_tracking_sources,
                    column: [ :time_tracking_source_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_aire_calendar_periods_source_tenant"
    add_foreign_key :aire_payroll_calendar_periods,
                    :pay_periods,
                    column: [ :pay_period_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_aire_calendar_periods_pay_period_tenant"
    add_foreign_key :aire_payroll_events,
                    :aire_payroll_calendar_publications,
                    column: [ :aire_payroll_calendar_publication_id, :aire_payroll_calendar_period_id ],
                    primary_key: [ :id, :aire_payroll_calendar_period_id ],
                    name: "fk_aire_payroll_events_publication_period"
  end

  def down
    remove_foreign_key :aire_payroll_events,
                       name: "fk_aire_payroll_events_publication_period"
    remove_foreign_key :aire_payroll_calendar_periods,
                       name: "fk_aire_calendar_periods_pay_period_tenant"
    remove_foreign_key :aire_payroll_calendar_periods,
                       name: "fk_aire_calendar_periods_source_tenant"

    remove_index :aire_payroll_calendar_publications,
                 name: "idx_aire_calendar_publications_period_key"
    remove_index :pay_periods,
                 name: "idx_pay_periods_aire_calendar_tenant_key"
    remove_index :time_tracking_sources,
                 name: "idx_time_tracking_sources_tenant_key"

    remove_check_constraint :company_pay_schedules,
                            name: "company_pay_schedules_cutoff_days_check"
    add_check_constraint :company_pay_schedules,
                         "payroll_cutoff_days_before BETWEEN 0 AND 31",
                         name: "company_pay_schedules_cutoff_days_check"
  end
end
