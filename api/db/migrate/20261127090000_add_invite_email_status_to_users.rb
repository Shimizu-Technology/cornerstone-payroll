# frozen_string_literal: true

# What happened to a login's invite email: queued, sent, captured (a local or
# staging copy kept it), refused (a demo address not on the allow-list),
# skipped (email delivery isn't configured) or failed. The send runs in a
# job after the staff response, so without this a skip or failure there was
# only in the logs. Nullable: older invites have no recorded outcome.
#
# users is a hot table: the short lock timeout makes the deploy fail fast
# instead of queueing behind a long query, and the constraint is added
# unvalidated, then validated without blocking writes.
class AddInviteEmailStatusToUsers < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    add_column :users, :invite_email_status, :string
    add_column :users, :invite_email_status_at, :datetime
    add_check_constraint :users,
      "invite_email_status IS NULL OR invite_email_status IN ('queued', 'sent', 'captured', 'refused', 'skipped', 'failed')",
      name: "users_invite_email_status_check", validate: false
    validate_check_constraint :users, name: "users_invite_email_status_check"
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    remove_check_constraint :users, name: "users_invite_email_status_check"
    remove_column :users, :invite_email_status_at
    remove_column :users, :invite_email_status
  end
end
