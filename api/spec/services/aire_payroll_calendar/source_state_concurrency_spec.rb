# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Source calendar response serialization", :postgres_concurrency do
  include CalendarStreamTransport
  self.use_transactional_tests = false

  let!(:organization) { create(:organization) }
  let!(:company) { create(:company, organization: organization) }
  let!(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let!(:period) { create(:pay_period, company: company) }
  let!(:calendar) { create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: period) }
  let!(:publication) { create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, next_delivery_attempt_at: now) }
  let(:now) { Time.zone.local(2026, 10, 10) }
  let(:cutoff) { "2026-11-22T17:00:00+10:00" }

  after do
    AirePayrollCalendarPublication.where(aire_payroll_calendar_period_id: calendar.id).delete_all
    AirePayrollCalendarPeriod.where(id: calendar.id).delete_all
    TimeTrackingSource.where(id: source.id).delete_all
    PayPeriod.where(id: period.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  def wait_for_lock(pid)
    Timeout.timeout(10) do
      until ApplicationRecord.connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = #{Integer(pid)} AND NOT granted)")
        sleep 0.01
      end
    end
  end

  [ :refresh, :delivery ].each do |operation|
    [ false, true ].each do |expires|
      it "serializes a newer invalidation after #{operation} #{expires ? 'times out' : 'records its response'}" do
        publication.update!(delivery_status: "delivered") if operation == :refresh
        stub_const("TimeTracking::Client::TOTAL_RESPONSE_TIMEOUT_SECONDS", expires ? 1.0 : 10.0)
        entered = Queue.new
        release_body = Queue.new
        invalidating_backend = Queue.new
        invalidation_result = Queue.new
        response_state = publication.payload.merge("external_pay_period_id" => calendar.external_pay_period_id,
          "next_scheduled_cutoff_at" => cutoff)
        payload = operation == :delivery ? { "payroll_calendar_period" => response_state } : response_state
        client, http, consumed = streamed_calendar_client(source, payload: payload, chunks: 20,
          delay: expires ? 0.1 : 0, before_body: -> { entered << true; release_body.pop(timeout: 10) || raise("Response not released") })
        workers = []
        begin
          workers << Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              if operation == :refresh
                AirePayrollCalendar::SourceState.new(TimeTrackingSource.find(source.id), client_factory: ->(*) { client }).refresh
              else
                AirePayrollCalendar::Delivery.new(publication_id: publication.id, now: now, client_factory: ->(*) { client }).call
              end
            end
          end
          expect(entered.pop(timeout: 10)).to be(true)
          workers << Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do |connection|
              invalidating_backend << connection.select_value("SELECT pg_backend_pid()")
              # This is the same invalidation used after a finalization callback.
              invalidation_result << AirePayrollCalendar::SourceState.new(TimeTrackingSource.find(source.id)).invalidate
            end
          end
          wait_for_lock(invalidating_backend.pop(timeout: 10) || raise("Invalidation did not start"))
          expect(invalidation_result).to be_empty
          release_body << true
          first_result = Timeout.timeout(10) { workers.first.value }
          Timeout.timeout(10) { workers.last.value }
          if operation == :delivery
            expect(first_result[:status]).to eq(expires ? "failed" : "delivered")
            if expires
              expect(publication.reload.next_delivery_attempt_at).to eq(now + 1.minute)
              expect(publication.last_error).to include("Could not securely reach")
            end
          else
            expect(first_result["status"]).to eq(expires ? "unavailable" : "available")
          end
          expect(consumed.length).to be < 20 if expires
          expect(http.finished).to be(true)
          expect(invalidation_result.pop(timeout: 10)).to include("status" => "unavailable", "next_scheduled_cutoff_at" => nil)
          expect(source.reload.payroll_calendar_source_state).to include("status" => "unavailable", "next_scheduled_cutoff_at" => nil)
        ensure
          release_body << true
          workers.each { |worker| Timeout.timeout(10) { worker.join } }
        end
      end
    end
  end
end
