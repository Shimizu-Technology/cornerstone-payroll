# frozen_string_literal: true

class AddProfileEmailDailyLimitsToEmployeeAccountLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_account_links, :profile_email_usage_date, :date
    add_column :employee_account_links, :profile_email_daily_codes, :integer, default: 0, null: false
    add_column :employee_account_links, :profile_email_daily_failures, :integer, default: 0, null: false
  end
end
