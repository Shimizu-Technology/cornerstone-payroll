# frozen_string_literal: true

# M4-5 follow-up.
#
# email_provider_events: every verified email provider webhook event (Resend
# through Svix), kept before the endpoint answers 2xx so a bounce that
# arrives before its notice records the provider id isn't lost. Unique on
# the Svix event id, so a replay is a no-op. It names no company (the event
# is matched to a notice afterwards) and holds no address: only the
# provider's message id, the event type, the mapped delivery status, the
# bounce type and when the provider says it happened.
#
# employee_account_links.former_profile_access_until: the former-access
# cutoff as first set when the link became former. Posting a W-2GU copy can
# lengthen former_access_until for the copy and pay stubs; profile reads
# (contacts, emergency contacts, address requests) keep this original date.
class CreateEmailProviderEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :email_provider_events do |t|
      t.string :provider, null: false, default: "resend"
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.string :provider_message_id
      t.string :delivery_status
      t.string :bounce_type
      t.datetime :occurred_at, null: false
      t.datetime :applied_at
      t.timestamps

      t.index %i[provider event_id], unique: true, name: "idx_email_provider_events_once"
      t.index %i[provider_message_id occurred_at], name: "idx_email_provider_events_message"
      t.index :created_at, where: "applied_at IS NULL AND delivery_status IS NOT NULL",
        name: "idx_email_provider_events_unapplied"
      t.check_constraint "delivery_status IS NULL OR delivery_status IN ('delivered', 'delayed', 'bounced', 'complained')",
        name: "email_provider_events_delivery_status"
    end

    add_column :employee_account_links, :former_profile_access_until, :datetime
    execute <<~SQL.squish
      UPDATE employee_account_links SET former_profile_access_until = former_access_until
      WHERE status = 'former' AND former_access_until IS NOT NULL
    SQL
  end

  def down
    remove_column :employee_account_links, :former_profile_access_until
    drop_table :email_provider_events
  end
end
