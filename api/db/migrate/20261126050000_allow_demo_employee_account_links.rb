# frozen_string_literal: true

# A demo company's employees use the employee app like a real client's
# (demo plan D6). A link still matches its company's payroll environment
# (fk_employee_account_links_live_company), and a non-live link may belong
# only to a demo company, never a practice copy, including through direct SQL.
class AllowDemoEmployeeAccountLinks < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :employee_account_links, name: "employee_account_links_live_only"
    add_check_constraint :employee_account_links, "payroll_environment IN ('live', 'migration_rehearsal')",
      name: "employee_account_links_live_or_demo"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION employee_account_links_live_or_demo_company() RETURNS trigger AS $$
      BEGIN
        IF NEW.payroll_environment <> 'live' AND NOT EXISTS (
          SELECT 1 FROM companies
          WHERE id = NEW.company_id AND payroll_environment = 'migration_rehearsal'
            AND COALESCE(test_workspace_purpose, '') = 'demo'
        ) THEN
          RAISE EXCEPTION 'employee_account_links must belong to a live or demo company'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS employee_account_links_live_or_demo_company ON employee_account_links;
      CREATE TRIGGER employee_account_links_live_or_demo_company
      BEFORE INSERT OR UPDATE OF company_id, payroll_environment ON employee_account_links
      FOR EACH ROW
      EXECUTE FUNCTION employee_account_links_live_or_demo_company();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS employee_account_links_live_or_demo_company ON employee_account_links;
      DROP FUNCTION IF EXISTS employee_account_links_live_or_demo_company();
    SQL
    remove_check_constraint :employee_account_links, name: "employee_account_links_live_or_demo"
    add_check_constraint :employee_account_links, "payroll_environment = 'live'", name: "employee_account_links_live_only"
  end
end
