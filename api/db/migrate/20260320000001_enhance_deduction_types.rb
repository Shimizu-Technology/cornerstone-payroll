# frozen_string_literal: true

class EnhanceDeductionTypes < ActiveRecord::Migration[8.0]
  def change
    change_table :deduction_types, bulk: true do |t|
      t.string :sub_category          # "retirement", "insurance", "garnishment", "loan", "rent", "phone", "allotment", "reimbursement", "other"
      t.string :payee_name            # Who receives payment (e.g., "Treasurer of Guam")
      t.string :reference_number      # Case number, remittance ID, etc.
      t.boolean :generates_check, default: false, null: false
    end

    add_index :deduction_types, [:company_id, :sub_category]
  end
end
