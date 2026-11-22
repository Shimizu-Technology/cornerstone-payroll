# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261122060003_expand_audit_log_actors")

RSpec.describe ExpandAuditLogActors do
  it "backfills established actor classes and keeps accepting writes from the old release" do
    staff = create(:user, role: :admin)
    client = create(:user, role: :client)
    migration = described_class.new
    # PostgreSQL prohibits concurrent index builds inside RSpec's fixture transaction.
    allow(migration).to receive(:add_index).and_wrap_original do |method, *args, **options|
      method.call(*args, **options.except(:algorithm))
    end

    legacy_rows = {
      "users#staff" => { user_id: staff.id, actor_name: staff.name },
      "users#client" => { user_id: client.id },
      "rollout#configure" => { actor_role: "operator", actor_name: "Release operator" },
      "worker_statement#viewed" => { metadata: { source_user_uuid: "worker-1" } },
      "aire_payroll_event#received" => {},
      "practice_access#swept" => {}
    }
    legacy_ids = legacy_rows.map do |action, attributes|
      AuditLog.insert!({ action: action, created_at: Time.current }.merge(attributes)).rows.first.first
    end

    ActiveRecord::Migration.suppress_messages { migration.up }

    expect(AuditLog.where(id: legacy_ids).pluck(:action, :actor_type, :actor_id, :actor_name)).to match_array([
      [ "users#staff", "staff_user", staff.id.to_s, staff.name ],
      [ "users#client", "client_user", client.id.to_s, nil ],
      [ "rollout#configure", "operator", nil, "Release operator" ],
      [ "worker_statement#viewed", "source_worker", "worker-1", nil ],
      [ "aire_payroll_event#received", "source_system", nil, nil ],
      [ "practice_access#swept", "system_job", nil, nil ]
    ])
    expect(AuditLog.connection_pool.with_connection { |connection|
      connection.index_exists?(:audit_logs, %i[company_id actor_type created_at], valid: true)
    }).to be(true)

    legacy_insert = AuditLog.insert!({ action: "users#old_writer", user_id: staff.id, created_at: Time.current })
    expect(AuditLog.find(legacy_insert.rows.first.first)).to have_attributes(actor_type: nil, actor_id: nil)
  end
end
