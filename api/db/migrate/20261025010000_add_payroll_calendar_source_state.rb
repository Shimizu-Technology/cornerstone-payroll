# frozen_string_literal: true

class AddPayrollCalendarSourceState < ActiveRecord::Migration[8.1]
  def change
    add_column :time_tracking_sources, :payroll_calendar_source_state, :jsonb, null: false, default: {}
  end
end
