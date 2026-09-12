class AddRevisionControlToPayrollIntake < ActiveRecord::Migration[8.1]
  def change
    add_reference :payroll_intake_sessions,
                  :supersedes,
                  foreign_key: { to_table: :payroll_intake_sessions, on_delete: :restrict },
                  index: { unique: true, where: "supersedes_id IS NOT NULL", name: "idx_payroll_intake_sessions_one_successor" }
    add_column :payroll_intake_sessions, :superseded_at, :datetime
    add_reference :payroll_intake_sessions,
                  :superseded_by_user,
                  foreign_key: { to_table: :users, on_delete: :nullify },
                  index: { name: "idx_payroll_intake_sessions_superseded_user" }
    add_column :payroll_intake_sessions, :supersession_reason, :text
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          WITH revision_chain AS (
            SELECT id,
                   LAG(id) OVER (PARTITION BY pay_period_id, source_type ORDER BY package_revision, id) AS predecessor_id,
                   LEAD(created_at) OVER (PARTITION BY pay_period_id, source_type ORDER BY package_revision, id) AS successor_created_at,
                   LEAD(id) OVER (PARTITION BY pay_period_id, source_type ORDER BY package_revision, id) AS successor_id
              FROM payroll_intake_sessions
          )
          UPDATE payroll_intake_sessions AS session
             SET supersedes_id = revision_chain.predecessor_id,
                 supersession_reason = CASE
                   WHEN revision_chain.predecessor_id IS NOT NULL
                   THEN 'Existing revision chain established during the source-governance migration.'
                   ELSE NULL
                 END,
                 superseded_at = CASE
                   WHEN revision_chain.successor_id IS NOT NULL
                   THEN COALESCE(revision_chain.successor_created_at, session.updated_at)
                   ELSE NULL
                 END
            FROM revision_chain
           WHERE revision_chain.id = session.id
        SQL
      end
    end
    add_index :payroll_intake_sessions,
              [ :pay_period_id, :source_type ],
              unique: true,
              where: "superseded_at IS NULL",
              name: "idx_payroll_intake_sessions_current_source"
    add_check_constraint :payroll_intake_sessions,
                         "(supersedes_id IS NULL AND supersession_reason IS NULL) OR (supersedes_id IS NOT NULL AND NULLIF(BTRIM(supersession_reason), '') IS NOT NULL)",
                         name: "payroll_intake_sessions_supersession_complete"

    add_column :payroll_intake_rows, :disposition, :string, null: false, default: "pending"
    add_column :payroll_intake_rows, :disposition_reason, :text
    add_reference :payroll_intake_rows,
                  :dispositioned_by,
                  foreign_key: { to_table: :users, on_delete: :nullify },
                  index: { name: "idx_payroll_intake_rows_dispositioned_by" }
    add_column :payroll_intake_rows, :dispositioned_at, :datetime
    add_reference :payroll_intake_rows,
                  :target_pay_period,
                  foreign_key: { to_table: :pay_periods, on_delete: :restrict },
                  index: { name: "idx_payroll_intake_rows_target_period" }
    add_index :payroll_intake_rows,
              [ :payroll_intake_session_id, :disposition ],
              name: "idx_payroll_intake_rows_session_disposition"

    add_check_constraint :payroll_intake_rows,
                         "disposition IN ('pending', 'included', 'excluded', 'deferred', 'informational')",
                         name: "payroll_intake_rows_disposition"
    add_check_constraint :payroll_intake_rows,
                         "disposition = 'pending' OR dispositioned_at IS NOT NULL",
                         name: "payroll_intake_rows_dispositioned_at"
    add_check_constraint :payroll_intake_rows,
                         "disposition IN ('pending', 'included') OR NULLIF(BTRIM(disposition_reason), '') IS NOT NULL",
                         name: "payroll_intake_rows_reason_required"
    add_check_constraint :payroll_intake_rows,
                         "(disposition = 'deferred' AND target_pay_period_id IS NOT NULL) OR (disposition <> 'deferred' AND target_pay_period_id IS NULL)",
                         name: "payroll_intake_rows_deferred_target"

    add_column :pay_periods, :intake_stale_at, :datetime
    add_column :pay_periods, :intake_stale_reason, :text
    add_reference :pay_periods,
                  :intake_stale_session,
                  foreign_key: { to_table: :payroll_intake_sessions, on_delete: :nullify },
                  index: { name: "idx_pay_periods_intake_stale_session" }
    add_check_constraint :pay_periods,
                         "(intake_stale_at IS NULL AND intake_stale_reason IS NULL AND intake_stale_session_id IS NULL) OR (intake_stale_at IS NOT NULL AND NULLIF(BTRIM(intake_stale_reason), '') IS NOT NULL AND intake_stale_session_id IS NOT NULL)",
                         name: "pay_periods_intake_stale_complete"
  end
end
