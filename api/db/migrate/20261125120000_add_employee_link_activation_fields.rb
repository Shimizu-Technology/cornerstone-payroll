# frozen_string_literal: true

# M4-2: what an employee link needs between invite and an active link. The
# table is empty in production and already covered by row-level security.
class AddEmployeeLinkActivationFields < ActiveRecord::Migration[8.1]
  def change
    change_table :employee_account_links, bulk: true do |t|
      # One-time sign-up code (HMAC digest only), the alternative to the emailed token.
      t.string :invite_code_digest
      t.string :invite_delivery
      # The address an emailed token went to, so sign-up with that same
      # address counts as a confirmed email.
      t.string :invite_email
      # An existing login already confirmed as this employee (M4-3); the link
      # can then only be claimed by that login, never by a new sign-up.
      t.references :claim_user, foreign_key: { to_table: :users }
      t.integer :failed_activation_attempts, null: false, default: 0
      t.datetime :activation_locked_at
      t.datetime :activation_locked_until
      t.boolean :sign_up_email_for_notices, null: false, default: false
      t.datetime :last_invited_at
      # Bumped by every invite and resend. A Clerk sign-up carries the
      # generation it was started for and binds only while it is current.
      t.integer :invite_generation, null: false, default: 0
    end

    add_index :employee_account_links, :invite_code_digest, unique: true, where: "invite_code_digest IS NOT NULL"
    add_check_constraint :employee_account_links, "invite_delivery IS NULL OR invite_delivery IN ('email', 'code')",
      name: "employee_account_links_invite_delivery_check"
    add_check_constraint :employee_account_links, "failed_activation_attempts >= 0",
      name: "employee_account_links_failed_attempts_check"
    add_check_constraint :employee_account_links, "invite_generation >= 0",
      name: "employee_account_links_invite_generation_check"
  end
end
