# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe PortalNotifications::Preferences, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Preference Concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization) }
  let!(:user) { create(:user, company: company, role: "manager") }

  after do
    PortalNotificationPreference.where(user_id: user.id).delete_all
    User.where(id: user.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "serializes two first saves of the same category instead of failing one" do
    ready, release, results, second_pid = Queue.new, Queue.new, Queue.new, Queue.new
    paused = false
    allow_any_instance_of(PortalNotificationPreference).to receive(:update!).and_wrap_original do |original, *args, **kwargs|
      unless paused
        paused = true
        ready << true
        Timeout.timeout(10) { release.pop }
      end
      original.call(*args, **kwargs)
    end

    save = lambda do |mode, pid_queue = nil|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          pid_queue&.push(connection.select_value("SELECT pg_backend_pid()"))
          described_class.update!(User.find(user.id), { "employee_changes" => mode })
          results << :ok
        rescue StandardError => e
          results << e.class
        end
      end
    end

    first = save.call("off")
    Timeout.timeout(10) { ready.pop }
    second = save.call("immediate", second_pid)
    pid = Timeout.timeout(10) { second_pid.pop }
    Timeout.timeout(10) do
      loop do
        state = ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        break if state == "Lock" || !second.alive?
        sleep 0.01
      end
    end
    expect(second).to be_alive # waiting on the first save, not racing it
    release << true
    [ first, second ].each { |thread| Timeout.timeout(10) { thread.join } }

    expect(2.times.map { results.pop }).to eq([ :ok, :ok ])
    expect(PortalNotificationPreference.where(user_id: user.id, category: "employee_changes").pluck(:delivery_mode)).to eq([ "immediate" ])
  ensure
    release << true if release
  end
end
