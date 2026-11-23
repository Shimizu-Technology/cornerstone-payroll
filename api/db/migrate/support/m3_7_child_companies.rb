# frozen_string_literal: true

# Frozen inventory for the M3-7 expand migrations. One required owning
# association per child, matching the existing parent foreign key.
module M3_7ChildCompanies
  CHILDREN = {
    employee_wage_rates: %i[employee_id employees],
    employee_deductions: %i[employee_id employees],
    employee_payroll_fields: %i[employee_id employees],
    employee_tipped_occupations: %i[employee_id employees],
    employee_ytd_totals: %i[employee_id employees],
    loan_transactions: %i[employee_loan_id employee_loans],
    payroll_item_earnings: %i[payroll_item_id payroll_items],
    payroll_item_deductions: %i[payroll_item_id payroll_items],
    payroll_item_field_entries: %i[payroll_item_id payroll_items],
    direct_deposit_payment_confirmations: %i[payroll_item_id payroll_items],
    check_events: %i[payroll_item_id payroll_items],
    payroll_intake_rows: %i[payroll_intake_session_id payroll_intake_sessions],
    payroll_imports: %i[pay_period_id pay_periods],
    payroll_intake_documents: %i[payroll_intake_session_id payroll_intake_sessions],
    punch_entries: %i[timecard_id timecards],
    time_tracking_earning_choices: %i[employee_id employees],
    pay_period_excluded_employees: %i[pay_period_id pay_periods],
    payroll_entry_resolutions: %i[pay_period_id pay_periods],
    non_employee_check_line_items: %i[non_employee_check_id non_employee_checks],
    non_employee_check_edits: %i[non_employee_check_id non_employee_checks],
    general_transmittal_items: %i[general_transmittal_id general_transmittals],
    department_ytd_totals: %i[department_id departments],
    aire_payroll_entry_acknowledgements: %i[payroll_item_id payroll_items],
    payroll_submission_imports: %i[payroll_submission_id payroll_submissions],
    time_tracking_imports: %i[pay_period_id pay_periods],
    time_tracking_financial_correction_links: %i[payroll_item_id payroll_items]
  }.transform_values(&:freeze).freeze

  PARENTS = CHILDREN.values.map(&:last).uniq.freeze
  FILL_FUNCTION = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION fill_child_company_from_parent() RETURNS trigger AS $$
    BEGIN
      IF NEW.company_id IS NULL THEN
        EXECUTE format('SELECT company_id FROM %I.%I WHERE id = ($1).%I',
                       TG_TABLE_SCHEMA, TG_ARGV[0], TG_ARGV[1])
          INTO NEW.company_id USING NEW;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
  SQL

  def self.trigger_name(table)
    "fill_#{table}_company_id"
  end

  def self.trigger_sql(table, parent_key, parent)
    <<~SQL
      DROP TRIGGER IF EXISTS #{trigger_name(table)} ON #{table};
      CREATE TRIGGER #{trigger_name(table)} BEFORE INSERT ON #{table}
      FOR EACH ROW EXECUTE FUNCTION fill_child_company_from_parent('#{parent}', '#{parent_key}');
    SQL
  end

  def self.schema_sql
    FILL_FUNCTION + CHILDREN.map { |table, (key, parent)| trigger_sql(table, key, parent) }.join
  end

  def self.foreign_key_name(table)
    "fk_#{table}_company_parent"
  end

  def with_short_ddl_transaction
    transaction do
      execute "SET LOCAL lock_timeout = '5s'"
      yield
    end
  end
end
