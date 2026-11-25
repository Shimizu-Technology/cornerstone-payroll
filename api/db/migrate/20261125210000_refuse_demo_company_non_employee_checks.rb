# frozen_string_literal: true

# Non-employee and FIT deposit checks pay real outside parties, so a demo
# company never has one, including through direct SQL.
class RefuseDemoCompanyNonEmployeeChecks < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DROP TRIGGER IF EXISTS non_employee_checks_refuse_demo_company ON non_employee_checks;
      CREATE TRIGGER non_employee_checks_refuse_demo_company
      BEFORE INSERT OR UPDATE OF company_id ON non_employee_checks
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_external_records();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS non_employee_checks_refuse_demo_company ON non_employee_checks;"
  end
end
