# frozen_string_literal: true

require "rails_helper"

RSpec.describe DependencyHealth do
  let(:now) { Time.zone.parse("2026-09-21 12:00:00") }
  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter) }
  let(:primary_record) { class_double(ActiveRecord::Base, connection: connection) }
  let(:queue_relation) { instance_double(ActiveRecord::Relation, exists?: true) }
  let(:queue_process) { class_double(SolidQueue::Process, where: queue_relation) }

  subject(:health) do
    described_class.new(primary_record: primary_record, queue_process: queue_process, clock: -> { now })
  end

  before do
    allow(connection).to receive(:select_value) do |sql|
      case sql
      when "SELECT 1" then 1
      when "SHOW transaction_read_only" then "off"
      when "SELECT pg_is_in_recovery()" then false
      else raise "unexpected query: #{sql}"
      end
    end
  end

  it "reports a writable primary and recent queue worker as ready" do
    report = health.run

    expect(report).to be_ready
    expect(report.as_json.fetch(:checks)).to eq(
      "primary_database" => true,
      "primary_writable" => true,
      "primary_role" => true,
      "queue_worker" => true
    )
    expect(queue_process).to have_received(:where).with(
      kind: "Worker",
      last_heartbeat_at: (now - 5.minutes)..
    )
  end

  it "fails readiness when PostgreSQL reports a read-only transaction" do
    allow(connection).to receive(:select_value).with("SHOW transaction_read_only").and_return("on")

    report = health.run

    expect(report).not_to be_ready
    expect(report.as_json.dig(:checks, "primary_writable")).to eq(false)
  end

  it "fails readiness when the connection raises the production read-only error" do
    allow(connection).to receive(:select_value).with("SHOW transaction_read_only")
      .and_raise(PG::ReadOnlySqlTransaction, "cannot execute INSERT in a read-only transaction")

    report = health.run

    expect(report).not_to be_ready
    expect(report.as_json.dig(:checks, "primary_writable")).to eq(false)
  end

  it "fails readiness when the database is a recovery replica" do
    allow(connection).to receive(:select_value).with("SELECT pg_is_in_recovery()").and_return(true)

    report = health.run

    expect(report).not_to be_ready
    expect(report.as_json.dig(:checks, "primary_role")).to eq(false)
  end

  it "fails readiness when no queue worker has a recent heartbeat" do
    allow(queue_relation).to receive(:exists?).and_return(false)

    report = health.run

    expect(report).not_to be_ready
    expect(report.as_json.dig(:checks, "queue_worker")).to eq(false)
  end
end
