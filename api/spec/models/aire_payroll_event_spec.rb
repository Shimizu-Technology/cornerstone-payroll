# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollEvent do
  let(:publication) { create(:aire_payroll_calendar_publication) }
  let(:event_payload) do
    {
      "event_id" => SecureRandom.uuid,
      "event_type" => described_class::EVENT_TYPE,
      "occurred_at" => Time.current.iso8601,
      "payroll_batch" => {
        "batch_id" => "batch-123",
        "checksum" => "a" * 64
      }
    }
  end

  def create_event(**attributes)
    described_class.create!({
      aire_payroll_calendar_period: publication.aire_payroll_calendar_period,
      aire_payroll_calendar_publication: publication,
      time_tracking_source: publication.aire_payroll_calendar_period.time_tracking_source,
      event_id: event_payload.fetch("event_id"),
      event_type: described_class::EVENT_TYPE,
      occurred_at: Time.current,
      payload: event_payload,
      payload_checksum: TimeTracking::CanonicalPayload.checksum(event_payload),
      payroll_batch_id: "batch-123",
      payroll_batch_checksum: "a" * 64
    }.merge(attributes))
  end

  it "keeps source event evidence immutable and append-only" do
    event = create_event

    expect { event.update!(payroll_batch_id: "changed") }
      .to raise_error(ActiveRecord::RecordInvalid, /immutable/)
    expect { event.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(event.errors[:base]).to include("AIRE payroll event evidence is append-only")
  end

  it "makes a verified event final" do
    event = create_event(
      verification_status: "verified",
      verified_at: Time.current,
      verified_batch_summary: { "checksum" => "a" * 64 }
    )

    expect { event.update!(verified_batch_summary: { "checksum" => "b" * 64 }) }
      .to raise_error(ActiveRecord::RecordInvalid, /final/)
  end

  it "enforces that the publication belongs to the event calendar period" do
    event = create_event
    other_publication = create(:aire_payroll_calendar_publication)

    expect do
      event.update_columns(aire_payroll_calendar_publication_id: other_publication.id)
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "targets a newly received event once without waiting for a global dispatcher sweep" do
    event = create_event
    queued = []

    first = described_class.dispatch_one!(event.id, enqueue: ->(id) { queued << id })
    second = described_class.dispatch_one!(event.id, enqueue: ->(id) { queued << id })

    expect(first).to be(true)
    expect(second).to be(false)
    expect(queued).to eq([ event.id ])
  end

  it "does not queue an event that became rejected before its row was reserved" do
    event = create_event
    event.update!(verification_status: "rejected", next_verification_attempt_at: nil)
    queued = []

    dispatched = described_class.dispatch_one!(event.id, enqueue: ->(id) { queued << id })

    expect(dispatched).to be(false)
    expect(queued).to be_empty
  end

  it "continues queueing later verification events when one enqueue fails" do
    first = create_event
    second = create_event(
      event_id: SecureRandom.uuid,
      payroll_batch_id: "batch-456",
      occurred_at: first.occurred_at + 1.second
    )
    queued = []

    dispatched = described_class.dispatch_due!(enqueue: lambda { |id|
      raise "queue unavailable" if id == first.id

      queued << id
    })

    expect(dispatched).to eq([ second.id ])
    expect(queued).to eq([ second.id ])
    expect(first.reload.verification_enqueued_until).to be_nil
  end
end
