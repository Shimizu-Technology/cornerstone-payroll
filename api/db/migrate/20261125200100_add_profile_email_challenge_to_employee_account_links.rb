# frozen_string_literal: true

class AddProfileEmailChallengeToEmployeeAccountLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_account_links, :profile_email_challenge, :text
    add_column :employee_account_links, :profile_email_sent_at, :datetime
  end
end
