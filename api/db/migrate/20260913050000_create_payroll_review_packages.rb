class CreatePayrollReviewPackages < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :client_payroll_approval_required, :boolean, null: false, default: false

    create_table :payroll_review_packages do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: false, foreign_key: { on_delete: :restrict }
      t.integer :revision, null: false
      t.string :schema_version, null: false, default: "v1"
      t.string :calculation_checksum, null: false
      t.jsonb :source_manifest, null: false, default: {}
      t.jsonb :calculation_snapshot, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.references :generated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :generated_at, null: false
      t.references :approved_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :approval_recorded_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :approved_at
      t.string :approval_method
      t.text :approval_acknowledgement
      t.text :approval_notes
      t.string :approval_evidence_reference
      t.datetime :superseded_at
      t.text :supersession_reason
      t.timestamps
    end

    add_index :payroll_review_packages, [ :pay_period_id, :revision ], unique: true,
              name: "idx_payroll_review_packages_period_revision"
    add_index :payroll_review_packages, :calculation_checksum,
              name: "idx_payroll_review_packages_checksum"
    add_index :payroll_review_packages, :pay_period_id, unique: true,
              where: "superseded_at IS NULL",
              name: "idx_payroll_review_packages_current"
    add_check_constraint :payroll_review_packages,
                         "revision > 0",
                         name: "payroll_review_packages_revision_positive"
    add_check_constraint :payroll_review_packages,
                         "status IN ('pending', 'approved', 'superseded')",
                         name: "payroll_review_packages_status_check"
    add_check_constraint :payroll_review_packages,
                         "approval_method IS NULL OR approval_method IN ('client_portal', 'email_attestation')",
                         name: "payroll_review_packages_approval_method_check"
    add_check_constraint :payroll_review_packages,
                         "(status = 'approved' AND approved_at IS NOT NULL AND approved_by_id IS NOT NULL AND approval_recorded_by_id IS NOT NULL AND approval_method IS NOT NULL AND approval_acknowledgement = 'I approve this exact payroll review revision for processing.' AND (approval_method <> 'email_attestation' OR NULLIF(BTRIM(approval_evidence_reference), '') IS NOT NULL) AND (approval_method <> 'client_portal' OR approved_by_id = approval_recorded_by_id)) OR (status = 'pending' AND approved_at IS NULL AND approved_by_id IS NULL AND approval_recorded_by_id IS NULL AND approval_method IS NULL AND approval_acknowledgement IS NULL) OR status = 'superseded'",
                         name: "payroll_review_packages_approval_shape"
    add_check_constraint :payroll_review_packages,
                         "(status = 'superseded' AND superseded_at IS NOT NULL AND NULLIF(BTRIM(supersession_reason), '') IS NOT NULL) OR (status <> 'superseded' AND superseded_at IS NULL AND supersession_reason IS NULL)",
                         name: "payroll_review_packages_supersession_shape"
  end
end
