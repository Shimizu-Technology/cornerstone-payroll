# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe AirePayrollCalendar::SourceState do
  let(:source) { create(:time_tracking_source, source_type: "aire_services") }
  let(:calendar) { create(:aire_payroll_calendar_period, company: source.company, time_tracking_source: source) }
  let!(:publication) do
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, delivery_status: "delivered", delivered_at: Time.current,
      source_state: { "next_scheduled_cutoff_at" => "2026-11-07T17:00:00+10:00" })
  end
  let(:client) { instance_double(TimeTracking::Client) }
  let(:service) { described_class.new(source, client_factory: ->(*) { client }) }
  let(:cutoff) { "2026-11-22T17:00:00+10:00" }
  let(:remote) do
    { "external_pay_period_id" => calendar.external_pay_period_id, "publication_id" => publication.publication_id,
      "schedule_version" => publication.schedule_version, "next_scheduled_cutoff_at" => cutoff, "revisions" => [] }
  end

  before { allow(client).to receive(:payroll_calendar_period).and_return(remote) }

  def present
    AirePayrollCalendar::Presenter.call(calendar.pay_period)
  end

  it "refreshes an old page from source-wide state without modifying its delivery evidence" do
    original = publication.attributes.slice("payload", "payload_checksum", "source_state")
    expect(service.refresh).to include("status" => "available", "next_scheduled_cutoff_at" => cutoff)
    expect(present).to include(next_scheduled_cutoff_at: cutoff, next_scheduled_cutoff_status: "available")
    expect(publication.reload.attributes.slice(*original.keys)).to eq(original)
    expect(present[:next_scheduled_cutoff_refreshed_at]).to be_present
  end

  it "distinguishes an authoritative null from an unavailable response without a local fallback" do
    remote["next_scheduled_cutoff_at"] = nil
    expect(service.refresh).to include("status" => "available", "next_scheduled_cutoff_at" => nil)
    expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "available")
    allow(client).to receive(:payroll_calendar_period).and_raise(TimeTracking::Client::Error, "Offline")
    expect(service.refresh).to include("status" => "unavailable", "next_scheduled_cutoff_at" => nil)
    expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "unavailable")
  end

  it "does not interpret a missing field as authoritative null" do
    remote.delete("next_scheduled_cutoff_at")
    expect(service.refresh).to include("status" => "unavailable")
  end

  it "rejects a source response for a different publication" do
    remote["publication_id"] = SecureRandom.uuid
    expect(service.refresh).to include("status" => "unavailable")
  end

  it "rejects an unwrapped response for a different external period" do
    remote["external_pay_period_id"] = SecureRandom.uuid
    expect(service.refresh).to include("status" => "unavailable")
  end

  it "rejects an unwrapped response for a different schedule revision" do
    remote["schedule_version"] += 1
    expect(service.refresh).to include("status" => "unavailable")
  end

  it "uses the real authenticated client's unwrapped GET contract" do
    policy = TimeTracking::DestinationPolicy.new(environment: "test", resolver: ->(*) { [ "8.8.8.8" ] })
    real_client = TimeTracking::Client.new(source, destination_policy: policy)
    request = stub_request(:get, "#{source.base_url}/api/v1/payroll/calendar_periods/#{calendar.external_pay_period_id}")
      .with(headers: { "X-Shared-Secret" => source.shared_secret, "X-Payroll-Shared-Secret" => source.shared_secret })
      .to_return(status: 200, body: remote.to_json, headers: { "Content-Type" => "application/json" })

    expect(described_class.new(source, client_factory: ->(*) { real_client }).refresh).to include(
      "status" => "available", "next_scheduled_cutoff_at" => cutoff)
    expect(request).to have_been_requested.once
    expect(present[:next_scheduled_cutoff_at]).to eq(cutoff)
  end

  it "clears a stale source observation when the staging outbound policy rejects refresh" do
    source.update_columns(payroll_calendar_source_state: { "status" => "available", "next_scheduled_cutoff_at" => cutoff })
    original = publication.attributes.slice("payload", "payload_checksum", "source_state")
    previous = ENV.to_h
    ENV["DEPLOYMENT_ENV"] = "staging"
    ENV["CONNECTED_PAYROLL_MODE"] = "enabled"
    ENV["STAGING_INTEGRATION_HOSTS"] = "other-staging.example.test"
    expect(Net::HTTP).not_to receive(:new)

    result = described_class.new(source).refresh
    expect(result).to include("status" => "unavailable", "next_scheduled_cutoff_at" => nil)
    expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "unavailable")
    expect(publication.reload.attributes.slice(*original.keys)).to eq(original)
  ensure
    ENV.replace(previous) if previous
  end

  it "rejects malformed cutoff values" do
    remote["next_scheduled_cutoff_at"] = false
    expect(service.refresh).to include("status" => "unavailable")
  end

  it "uses the latest delivered period while updating every older page on the source" do
    newer = create(:aire_payroll_calendar_period, company: source.company, time_tracking_source: source)
    second = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: newer, delivery_status: "delivered", delivered_at: Time.current)
    remote.merge!("external_pay_period_id" => newer.external_pay_period_id, "publication_id" => second.publication_id,
      "schedule_version" => second.schedule_version)
    service.refresh
    expect(client).to have_received(:payroll_calendar_period).with(external_pay_period_id: newer.external_pay_period_id)
    expect(present[:next_scheduled_cutoff_at]).to eq(cutoff)
    expect(publication.reload.source_state["next_scheduled_cutoff_at"]).not_to eq(cutoff)
  end

  it "refreshes the highest delivered revision even when an older revision arrived later" do
    newer_revision = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar,
      schedule_version: 2, delivery_status: "delivered", delivered_at: 1.hour.ago)
    remote.merge!("publication_id" => newer_revision.publication_id, "schedule_version" => 2)

    expect(service.refresh).to include("status" => "available", "next_scheduled_cutoff_at" => cutoff)
  end

  it "prefers the latest chronological period even when an older period was delivered later" do
    newer_pay_period = create(:pay_period, company: source.company, start_date: "2026-11-01",
      end_date: "2026-11-15", pay_date: "2026-11-25")
    newer_calendar = create(:aire_payroll_calendar_period, company: source.company,
      time_tracking_source: source, pay_period: newer_pay_period)
    newer_publication = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: newer_calendar,
      delivery_status: "delivered", delivered_at: 1.hour.ago)
    remote.merge!("external_pay_period_id" => newer_calendar.external_pay_period_id,
      "publication_id" => newer_publication.publication_id, "schedule_version" => newer_publication.schedule_version)

    expect(service.refresh).to include("status" => "available", "next_scheduled_cutoff_at" => cutoff)
    expect(client).to have_received(:payroll_calendar_period).with(external_pay_period_id: newer_calendar.external_pay_period_id)
  end

  context "when an active production source host is removed from the allowlist" do
    before do
      source.update!(base_url: "https://removed.example.com")
      source.update!(payroll_calendar_source_state: { "status" => "available", "next_scheduled_cutoff_at" => cutoff })
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("TIME_TRACKING_ALLOWED_HOSTS", "").and_return("other.example.com")
      expect(source).not_to be_valid
      expect(source.errors[:base_url]).to include("host is not in TIME_TRACKING_ALLOWED_HOSTS")
    end

    it "persists an unavailable refresh without raising unrelated source validations" do
      real_client = TimeTracking::Client.new(source)
      result = described_class.new(source, client_factory: ->(*) { real_client }).refresh
      expect(result).to include("status" => "unavailable", "next_scheduled_cutoff_at" => nil)
      expect(source.reload.payroll_calendar_source_state).to eq(result)
    end

    it "invalidates stale state after finalization despite unrelated source validation failures" do
      expect(service.invalidate).to include("status" => "unavailable", "next_scheduled_cutoff_at" => nil)
      expect(source.reload.payroll_calendar_source_state["next_scheduled_cutoff_at"]).to be_nil
    end
  end

  context "after a finalization callback" do
    before do
      allow(AirePayrollEvent).to receive(:dispatch_one!)
      source.update!(payroll_calendar_source_state: { "status" => "available", "next_scheduled_cutoff_at" => publication.payload["cutoff_at"] })
      batch = build_aire_batch_payload(cutoff_at: publication.payload["cutoff_at"])
      payload = build_aire_finalized_event(calendar_period: calendar, publication: publication, batch_payload: batch)
      AirePayrollEvents::Receiver.new(payload: payload, shared_secret: source.shared_secret, idempotency_key: payload["event_id"]).call
    end

    it "immediately clears the finalized cutoff even when the follow-up GET fails" do
      expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "unavailable")
      allow(client).to receive(:payroll_calendar_period).and_raise(TimeTracking::Client::Error, "Offline")
      service.refresh
      expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "unavailable")
      expect(AirePayrollCalendarSourceRefreshJob).to have_been_enqueued.with(source.id)
    end

    it "clears the only scheduled cutoff to authoritative null" do
      remote["next_scheduled_cutoff_at"] = nil
      service.refresh
      expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "available")
    end

    it "advances to the source's scheduled successor" do
      service.refresh
      expect(present).to include(next_scheduled_cutoff_at: cutoff, next_scheduled_cutoff_status: "available")
    end

    it "does not resurrect a finalized cutoff from a stale remote observation" do
      remote["next_scheduled_cutoff_at"] = publication.payload["cutoff_at"]
      expect(service.refresh).to include("status" => "unavailable", "next_scheduled_cutoff_at" => nil)
    end
  end
end
