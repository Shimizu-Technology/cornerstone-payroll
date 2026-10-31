# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe PayrollFilingResponsibilityRecorder, :postgres_concurrency, type: :model do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "History filing concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization) }
  let!(:actor) { create(:user, company: company, organization: organization, role: "admin") }
  let!(:responsibility) { record_decision(company, actor, "cornerstone", "Before onboarding reversal").first }

  after do
    PayrollFilingResponsibility.where(company_id: company.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    actor.destroy!
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "keeps ownership rows unchanged and available to onboarding while a competing writer waits for the company lock" do
    writer_pid, result = Queue.new, Queue.new
    writer = nil
    Company.transaction do
      company.lock!
      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          writer_pid << connection.raw_connection.backend_pid
          record_decision(Company.find(company.id), User.find(actor.id), "external_provider", "Reviewed after onboarding")
          result << :saved
        rescue StandardError => error
          result << error
        end
      end
      pid = Timeout.timeout(10) { writer_pid.pop }
      Timeout.timeout(10) do
        loop do
          ActiveRecord::Base.connection.execute("SELECT pg_stat_clear_snapshot()")
          waiting = ActiveRecord::Base.uncached do
            ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
          end
          break if waiting == "Lock"
          sleep 0.01
        end
      end
      # A reversal must be able to inspect and restore these rows while it
      # owns Company. Without shared ordering, the writer locks this row and
      # then waits on Company's audit FK, creating a reversal deadlock/race.
      locked = PayrollFilingResponsibility.lock("FOR UPDATE NOWAIT").find(responsibility.id)
      expect(locked.responsible_party).to eq("cornerstone")
      expect(locked.notes).to eq("Before onboarding reversal")
      expect(result).to be_empty
    end
    Timeout.timeout(10) { writer.join }
    expect(result.pop).to eq(:saved)
    expect(responsibility.reload.responsible_party).to eq("external_provider")
    expect(AuditLog.where(company_id: company.id, action: "payroll_filing_responsibilities#recorded").count).to eq(2)
  ensure
    Timeout.timeout(10) { writer&.join }
  end

  def record_decision(client, user, party, note)
    described_class.new(company: client, actor: user, tax_year: 2026, quarter: 1,
      filing_types: [ "form_941" ], responsible_party: party,
      imported_payroll_inclusion: "included", notes: note).call
  end
end
