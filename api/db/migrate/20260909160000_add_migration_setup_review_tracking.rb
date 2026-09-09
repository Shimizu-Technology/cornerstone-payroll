# frozen_string_literal: true

class AddMigrationSetupReviewTracking < ActiveRecord::Migration[8.0]
  def change
    change_table :payroll_go_live_reviews, bulk: true do |t|
      t.string :company_setup_digest
      t.text :company_setup_review_notes
      t.datetime :company_setup_reviewed_at
      t.references :company_setup_reviewed_by,
                   foreign_key: { to_table: :users, on_delete: :nullify },
                   index: { name: "idx_go_live_reviews_company_setup_reviewer" }
    end

    create_table :employee_configuration_review_resolutions do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :employee, null: false, foreign_key: { on_delete: :restrict }
      t.string :item_code, null: false
      t.text :item_message, null: false
      t.jsonb :item_fields, null: false, default: []
      t.text :resolution_note, null: false
      t.references :reviewed_by,
                   foreign_key: { to_table: :users, on_delete: :nullify },
                   index: { name: "idx_employee_config_reviews_reviewer" }
      t.string :reviewed_by_name, null: false
      t.string :reviewed_by_email, null: false
      t.string :reviewed_by_role, null: false
      t.datetime :reviewed_at, null: false
      t.timestamps
    end

    add_index :employee_configuration_review_resolutions,
              %i[employee_id item_code],
              unique: true,
              name: "idx_employee_configuration_review_resolutions_unique"
    add_index :employee_configuration_review_resolutions,
              %i[company_id reviewed_at],
              name: "idx_employee_configuration_review_resolutions_company_time"
    add_check_constraint :employee_configuration_review_resolutions,
                         "jsonb_typeof(item_fields) = 'array'",
                         name: "employee_configuration_review_resolutions_fields_array"
  end
end
