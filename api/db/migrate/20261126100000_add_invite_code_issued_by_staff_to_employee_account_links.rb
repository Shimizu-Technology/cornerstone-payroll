# frozen_string_literal: true

# Records, for each printed sign-up code generation, whether Cornerstone staff
# issued it. Only a staff-issued code skips the email-on-file check at
# activation; a code with no recorded issuer counts as retired. No backfill:
# production had no employee account links when this shipped.
class AddInviteCodeIssuedByStaffToEmployeeAccountLinks < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    add_column :employee_account_links, :invite_code_issued_by_staff, :boolean
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    remove_column :employee_account_links, :invite_code_issued_by_staff
  end
end
