# frozen_string_literal: true

class AddEvidenceSnapshotToPayrollIntakeSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_intake_sessions, :evidence_snapshot, :jsonb, null: false, default: {}
  end
end
