# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendarPublication do
  it "reserves due publications once across repeated dispatcher sweeps" do
    publication = create(:aire_payroll_calendar_publication, next_delivery_attempt_at: 1.minute.ago)
    queued = []

    first = described_class.dispatch_due!(enqueue: ->(id) { queued << id })
    second = described_class.dispatch_due!(enqueue: ->(id) { queued << id })

    expect(first).to eq([ publication.id ])
    expect(second).to be_empty
    expect(queued).to eq([ publication.id ])
  end

  it "releases a failed reservation and continues queueing the batch" do
    first = create(:aire_payroll_calendar_publication, next_delivery_attempt_at: 1.minute.ago)
    second = create(:aire_payroll_calendar_publication, next_delivery_attempt_at: 1.minute.ago)
    queued = []

    dispatched = described_class.dispatch_due!(enqueue: lambda { |id|
      raise "queue unavailable" if id == first.id

      queued << id
    })

    expect(dispatched).to eq([ second.id ])
    expect(queued).to eq([ second.id ])
    expect(first.reload.delivery_enqueued_until).to be_nil
  end

  it "dispatches a requested publication even when more than one batch of older work is due" do
    create_list(:aire_payroll_calendar_publication, described_class::BATCH_SIZE + 1, next_delivery_attempt_at: 1.minute.ago)
    publication = create(:aire_payroll_calendar_publication, next_delivery_attempt_at: Time.current)
    queued = []

    dispatched = described_class.dispatch_one!(publication.id, enqueue: ->(id) { queued << id })

    expect(dispatched).to be(true)
    expect(queued).to eq([ publication.id ])
  end

  it "enforces immutable publication evidence" do
    publication = create(:aire_payroll_calendar_publication)

    expect do
      publication.update!(payload: { "changed" => true })
    end.to raise_error(ActiveRecord::RecordInvalid, /immutable/)
  end

  it "makes a delivered publication final and append-only" do
    publication = create(
      :aire_payroll_calendar_publication,
      delivery_status: "delivered",
      delivered_at: Time.current,
      next_delivery_attempt_at: nil
    )

    expect do
      publication.update!(source_state: { "changed" => true })
    end.to raise_error(ActiveRecord::RecordInvalid, /final/)
    expect { publication.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(publication.errors[:base]).to include("AIRE calendar publication evidence is append-only")
  end
end
