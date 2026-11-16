# frozen_string_literal: true

class AddPayrollIntakeSettingsToCompanies < ActiveRecord::Migration[8.1]
  def change
    # Per-source intake options, keyed by source type. An empty object keeps
    # each source's own defaults (for example, which files make a complete package).
    add_column :companies, :payroll_intake_settings, :jsonb, default: {}, null: false
  end
end
