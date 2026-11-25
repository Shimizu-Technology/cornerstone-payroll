# frozen_string_literal: true

class AddActivationNoticeToEmployeeAccountLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_account_links, :activation_notice_email, :string
    add_column :employee_account_links, :activation_notice_status, :string
    add_column :employee_account_links, :activation_notice_attempts, :integer, default: 0, null: false
    add_column :employee_account_links, :activation_notice_sent_at, :datetime
    add_index :employee_account_links, :activation_notice_status,
      where: "activation_notice_status IN ('pending', 'failed')",
      name: "idx_employee_account_links_unsent_activation_notice"
  end
end
