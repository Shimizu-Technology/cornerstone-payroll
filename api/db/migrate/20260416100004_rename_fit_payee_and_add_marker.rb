# frozen_string_literal: true

# Adds a stable `auto_generated_type` marker to non_employee_checks so we can
# identify the auto-generated FIT tax-deposit check independent of the
# `payable_to` string (which is user-editable).
#
# Also:
#  - Renames the existing FIT auto-deposit payee from "EFTPS - Federal Income Tax"
#    to "Treasurer of Guam" (Guam DRT remits via Form 500, not federal EFTPS).
#  - Replaces the brittle string-based unique index with one keyed on the new
#    marker so subsequent edits to `payable_to` don't break uniqueness.
class RenameFitPayeeAndAddMarker < ActiveRecord::Migration[8.0]
  GUAM_FIT_PAYEE = "Treasurer of Guam"
  LEGACY_FIT_PAYEE = "EFTPS - Federal Income Tax"
  FIT_MARKER = "fit_deposit"
  OLD_INDEX_NAME = "idx_unique_non_voided_fit_check_per_period"
  NEW_INDEX_NAME = "idx_unique_non_voided_auto_generated_per_period"

  def up
    add_column :non_employee_checks, :auto_generated_type, :string

    # Backfill: any existing FIT check (identified by the legacy payee string)
    # gets the new marker AND the new payee. Memo is left intact unless it
    # references EFTPS so we don't blow away custom user notes.
    execute <<~SQL.squish
      UPDATE non_employee_checks
         SET auto_generated_type = #{quote(FIT_MARKER)},
             payable_to = #{quote(GUAM_FIT_PAYEE)},
             updated_at = NOW()
       WHERE check_type = 'tax_deposit'
         AND payable_to = #{quote(LEGACY_FIT_PAYEE)}
    SQL

    add_index :non_employee_checks, :auto_generated_type,
              name: "index_non_employee_checks_on_auto_generated_type",
              where: "auto_generated_type IS NOT NULL"

    # Drop old payee-string-based unique index (it would now be empty anyway
    # because the backfill renamed all matching rows).
    if index_exists?(:non_employee_checks, [:pay_period_id, :company_id], name: OLD_INDEX_NAME)
      remove_index :non_employee_checks, name: OLD_INDEX_NAME
    end

    # New unique index keyed on the stable marker. Survives any `payable_to`
    # rename the user makes in the edit UI.
    add_index :non_employee_checks,
              [:pay_period_id, :company_id, :auto_generated_type],
              unique: true,
              where: "auto_generated_type IS NOT NULL AND voided = false",
              name: NEW_INDEX_NAME
  end

  def down
    if index_exists?(:non_employee_checks, [:pay_period_id, :company_id, :auto_generated_type], name: NEW_INDEX_NAME)
      remove_index :non_employee_checks, name: NEW_INDEX_NAME
    end

    if index_exists?(:non_employee_checks, :auto_generated_type, name: "index_non_employee_checks_on_auto_generated_type")
      remove_index :non_employee_checks, name: "index_non_employee_checks_on_auto_generated_type"
    end

    # Roll the payee string back so the old index would still match.
    execute <<~SQL.squish
      UPDATE non_employee_checks
         SET payable_to = #{quote(LEGACY_FIT_PAYEE)},
             updated_at = NOW()
       WHERE check_type = 'tax_deposit'
         AND auto_generated_type = #{quote(FIT_MARKER)}
    SQL

    add_index :non_employee_checks,
              [:pay_period_id, :company_id],
              unique: true,
              where: "check_type = 'tax_deposit' AND payable_to = '#{LEGACY_FIT_PAYEE}' AND voided = false",
              name: OLD_INDEX_NAME

    remove_column :non_employee_checks, :auto_generated_type
  end
end
