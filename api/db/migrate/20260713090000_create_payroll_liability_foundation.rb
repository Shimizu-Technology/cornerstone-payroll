# frozen_string_literal: true

class CreatePayrollLiabilityFoundation < ActiveRecord::Migration[8.0]
  def change
    create_table :pay_component_tax_rules do |t|
      t.references :company, foreign_key: { on_delete: :restrict }, null: true
      t.string :component_key, null: false
      t.string :display_name, null: false
      t.string :component_kind, null: false
      t.string :fit_treatment, null: false
      t.string :social_security_treatment, null: false
      t.string :medicare_treatment, null: false
      t.string :additional_medicare_treatment, null: false
      t.string :swica_treatment, null: false
      t.string :retirement_treatment, null: false
      t.string :reimbursement_treatment, null: false
      t.jsonb :w2_gu_mapping, null: false, default: {}
      t.jsonb :form_941_mapping, null: false, default: {}
      t.string :register_presentation, null: false, default: "separate"
      t.string :gl_account_code
      t.date :effective_from, null: false
      t.date :effective_to
      t.string :source_name, null: false
      t.string :source_url
      t.string :version, null: false
      t.boolean :active, null: false, default: true
      t.references :approved_by, foreign_key: { to_table: :users, on_delete: :nullify }, null: true
      t.datetime :approved_at
      t.timestamps
    end

    add_index :pay_component_tax_rules,
              [ :company_id, :component_key, :effective_from ],
              name: "idx_component_rules_company_key_effective"
    add_index :pay_component_tax_rules,
              [ :component_key, :effective_from ],
              name: "idx_component_rules_global_key_effective",
              where: "company_id IS NULL"
    add_check_constraint :pay_component_tax_rules,
                         "effective_to IS NULL OR effective_to >= effective_from",
                         name: "component_rules_effective_date_range"

    create_table :payroll_liability_postings do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: false, foreign_key: { on_delete: :restrict }
      t.string :posting_type, null: false
      t.references :source_posting,
                   foreign_key: { to_table: :payroll_liability_postings, on_delete: :restrict },
                   null: true
      t.date :liability_date, null: false
      t.datetime :posted_at, null: false
      t.references :posted_by, foreign_key: { to_table: :users, on_delete: :nullify }, null: true
      t.text :reason
      t.string :idempotency_key, null: false
      t.jsonb :component_rule_snapshot, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :payroll_liability_postings, :idempotency_key, unique: true,
              name: "idx_liability_postings_idempotency"
    add_index :payroll_liability_postings, :source_posting_id, unique: true,
              where: "source_posting_id IS NOT NULL",
              name: "idx_liability_postings_one_reversal"
    add_index :payroll_liability_postings,
              [ :company_id, :liability_date ],
              name: "idx_liability_postings_company_date"
    add_index :payroll_liability_postings,
              [ :pay_period_id, :posting_type ],
              name: "idx_liability_postings_period_type"

    create_table :payroll_liability_entries do |t|
      t.references :payroll_liability_posting,
                   null: false,
                   foreign_key: { on_delete: :restrict },
                   index: { name: "idx_liability_entries_posting" }
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :payroll_item, null: true, foreign_key: { on_delete: :restrict }
      t.references :pay_component_tax_rule,
                   null: true,
                   foreign_key: { on_delete: :restrict },
                   index: { name: "idx_liability_entries_component_rule" }
      t.string :component_key, null: false
      t.string :category, null: false
      t.string :authority, null: false
      t.decimal :amount, precision: 14, scale: 2, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :payroll_liability_entries,
              [ :company_id, :category ],
              name: "idx_liability_entries_company_category"
    add_index :payroll_liability_entries,
              [ :payroll_liability_posting_id, :payroll_item_id, :component_key ],
              unique: true,
              name: "idx_liability_entries_unique_component"
    add_check_constraint :payroll_liability_entries,
                         "amount <> 0",
                         name: "liability_entries_nonzero_amount"
  end
end
