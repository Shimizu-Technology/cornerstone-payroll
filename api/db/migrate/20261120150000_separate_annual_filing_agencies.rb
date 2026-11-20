# frozen_string_literal: true

class SeparateAnnualFilingAgencies < ActiveRecord::Migration[8.0]
  def up
    add_column :payroll_filing_records, :agency, :string, null: false, default: ""
    # An old W-2 receipt does not prove which portal received it. Preserve it
    # verbatim as unassigned history rather than inventing two acceptances.
    execute "UPDATE payroll_filing_records SET agency = 'legacy' WHERE filing_type = 'w2_gu_w3_ss'"
    execute "UPDATE payroll_filing_records SET agency = 'drt' WHERE filing_type = 'form_1099_nec'"
    remove_index :payroll_filing_records, name: "idx_payroll_filings_annual_identity"
    add_index :payroll_filing_records, %i[company_id filing_type tax_year agency], unique: true,
              where: "quarter IS NULL", name: "idx_payroll_filings_annual_identity"
    add_check_constraint :payroll_filing_records,
      "(filing_type = 'w2_gu_w3_ss' AND agency IN ('ssa', 'drt', 'legacy')) OR " \
      "(filing_type = 'form_1099_nec' AND agency = 'drt') OR (quarter IS NOT NULL AND agency = '')",
      name: "payroll_filing_records_agency"
    add_reference :payroll_filing_events, :download_audit, foreign_key: { to_table: :audit_logs }
    add_column :payroll_filing_events, :file_sha256, :string
    change_column_null :payroll_filing_events, :evidence_document_id, true
  end

  def down
    count = select_value("SELECT COUNT(*) FROM payroll_filing_records WHERE agency IN ('ssa', 'drt')").to_i
    bound = select_value("SELECT COUNT(*) FROM payroll_filing_events WHERE download_audit_id IS NOT NULL OR evidence_document_id IS NULL").to_i
    if count.positive? || bound.positive?
      raise ActiveRecord::IrreversibleMigration, "#{count} agency filing record(s) and #{bound} file-bound/receipt-free event(s) require this schema. Roll back the application only; preserve filing history."
    end
    change_column_null :payroll_filing_events, :evidence_document_id, false
    remove_column :payroll_filing_events, :file_sha256
    remove_reference :payroll_filing_events, :download_audit, foreign_key: { to_table: :audit_logs }
    remove_check_constraint :payroll_filing_records, name: "payroll_filing_records_agency"
    remove_index :payroll_filing_records, name: "idx_payroll_filings_annual_identity"
    remove_column :payroll_filing_records, :agency
    add_index :payroll_filing_records, %i[company_id filing_type tax_year], unique: true,
              where: "quarter IS NULL", name: "idx_payroll_filings_annual_identity"
  end
end
