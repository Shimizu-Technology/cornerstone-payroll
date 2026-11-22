# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261122060003_expand_audit_log_actors")

RSpec.describe ExpandAuditLogActors do
  let(:migration) { described_class.new }

  before do
    # PostgreSQL prohibits concurrent index builds inside RSpec's fixture transaction.
    %i[add_index remove_index].each do |operation|
      allow(migration).to receive(operation).and_wrap_original do |method, *args, **options|
        method.call(*args, **options.except(:algorithm))
      end
    end
  end

  it "backfills established actor classes and keeps accepting writes from the old release" do
    staff = create(:user, role: :admin)
    client = create(:user, role: :client)
    employee = create(:user, role: :employee)

    legacy_rows = {
      "users#staff" => { user_id: staff.id, actor_name: staff.name },
      "users#client" => { user_id: client.id },
      "users#employee" => { user_id: employee.id },
      "users#historical_employee" => { user_id: staff.id, actor_role: "employee" },
      "rollout#configure" => { actor_role: "operator", actor_name: "Release operator" },
      "worker_statement#viewed" => { metadata: { source_user_uuid: "worker-1" } },
      "aire_payroll_event#received" => {},
      "aire_payroll_calendar#cutoff_changed" => { metadata: { requested_via: "aire_services" } },
      "aire_payroll_calendar#published" => {},
      "practice_access#swept" => {}
    }
    legacy_ids = legacy_rows.map do |action, attributes|
      AuditLog.insert!({ action: action, created_at: Time.current }.merge(attributes)).rows.first.first
    end

    ActiveRecord::Migration.suppress_messages { migration.up }

    expect(AuditLog.where(id: legacy_ids).pluck(:action, :actor_type, :actor_id, :actor_name)).to match_array([
      [ "users#staff", "staff_user", staff.id.to_s, staff.name ],
      [ "users#client", "client_user", client.id.to_s, nil ],
      [ "users#employee", "employee", employee.id.to_s, nil ],
      [ "users#historical_employee", "employee", staff.id.to_s, nil ],
      [ "rollout#configure", "operator", nil, "Release operator" ],
      [ "worker_statement#viewed", "source_worker", "worker-1", nil ],
      [ "aire_payroll_event#received", "source_system", nil, nil ],
      [ "aire_payroll_calendar#cutoff_changed", "source_system", nil, nil ],
      [ "aire_payroll_calendar#published", "source_system", nil, nil ],
      [ "practice_access#swept", "system_job", nil, nil ]
    ])
    expect(AuditLog.connection_pool.with_connection { |connection|
      connection.index_exists?(:audit_logs, %i[company_id actor_type created_at], valid: true)
    }).to be(true)

    legacy_insert = AuditLog.insert!({ action: "users#old_writer", user_id: staff.id, created_at: Time.current })
    expect(AuditLog.find(legacy_insert.rows.first.first)).to have_attributes(actor_type: nil, actor_id: nil)
  end

  it "restores legacy trigger writes on down and keeps up safe to run twice" do
    company = create(:company)
    action = "time_tracking_source#lock_rollout_configured"

    AuditLog.connection_pool.with_connection do |connection|
      ActiveRecord::Migration.suppress_messages { migration.down }
      expect(connection.column_exists?(:audit_logs, :actor_id)).to be(false)
      expect(connection.column_exists?(:audit_logs, :actor_type)).to be(false)
      expect(connection.index_exists?(:audit_logs, name: described_class::INDEX_NAME)).to be(false)

      create(:time_tracking_source, company: company, source_type: "aire_services")
      logs = AuditLog.where(company: company, action: action)
      expect(logs.pluck(:actor_name)).to eq([ "Approved lock rollout" ])

      ActiveRecord::Migration.suppress_messages { migration.up }
      expect(logs.pluck(:actor_type)).to eq([ "system_job" ])

      source = create(:time_tracking_source, source_type: "aire_services")
      expect(AuditLog.where(action: action, record_id: source.id).pluck(:actor_type)).to eq([ "system_job" ])

      expect { ActiveRecord::Migration.suppress_messages { migration.up } }
        .not_to change { AuditLog.where(action: action).order(:id).pluck(:id, :actor_type, :actor_id) }
    end
  end
end
