# frozen_string_literal: true

# What happened to a login's invite email: queued, sent, captured (a local or
# staging copy kept it), refused (a demo address not on the allow-list),
# skipped (email delivery isn't configured) or failed. The send runs in a
# job after the staff response, so without this a skip or failure there was
# only in the logs. Nullable: older invites have no recorded outcome.
class AddInviteEmailStatusToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :invite_email_status, :string
    add_column :users, :invite_email_status_at, :datetime
    add_check_constraint :users,
      "invite_email_status IS NULL OR invite_email_status IN ('queued', 'sent', 'captured', 'refused', 'skipped', 'failed')",
      name: "users_invite_email_status_check"
  end
end
