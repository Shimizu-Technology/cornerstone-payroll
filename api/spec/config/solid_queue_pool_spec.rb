# frozen_string_literal: true

require "rails_helper"

RSpec.describe SolidQueue::Configuration do
  subject(:configuration) { described_class.new(skip_recurring: true) }

  let(:worker_options) { configuration.configured_processes.select { |process| process.kind == :worker }.map(&:attributes) }

  it "keeps the employee queue behind the existing queues and preserves OCR's worker" do
    expect(worker_options).to match([
      a_hash_including(queues: %w[default solid_queue_recurring employee], threads: 3),
      a_hash_including(queues: "ocr", threads: 1)
    ])
  end

  it "honors a comma-separated override for the main worker only" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("SOLID_QUEUE_QUEUES", "default,solid_queue_recurring,employee")
      .and_return("employee, kiosk")
    expect(worker_options.pluck(:queues)).to eq([ %w[employee kiosk], "ocr" ])
  end

  it "rejects an effective application pool below the worker's three threads plus two" do
    allow(SolidQueue::Record).to receive(:connection_pool).and_return(double(size: 5))
    allow(ActiveRecord::Base.connection_pool).to receive(:size).and_return(4)
    expect(configuration).not_to be_valid
    expect(configuration.errors.full_messages).to include(/primary database pool of at least 5/)
  end

  it "rejects a queue pool below the worker's three threads plus two" do
    allow(SolidQueue::Record).to receive(:connection_pool).and_return(double(size: 4))
    expect(configuration).not_to be_valid
    expect(configuration.errors.full_messages).to include(/database connection pool is 4/)
  end

  it "accepts a pool of five for both databases" do
    allow(SolidQueue::Record).to receive(:connection_pool).and_return(double(size: 5))
    allow(ActiveRecord::Base.connection_pool).to receive(:size).and_return(5)
    expect(configuration).to be_valid
  end

  it "applies DB_POOL_MAX independently of the web thread setting to all production pools" do
    allow(ENV).to receive(:key?).and_call_original
    allow(ENV).to receive(:key?).with("DB_POOL_MAX").and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("DB_POOL_MAX").and_return("7")
    allow(ENV).to receive(:fetch).with("RAILS_MAX_THREADS", 5).and_return("3")

    env_config = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/database.yml"))
    expect(env_config.fetch("production").transform_values { |db| db.fetch("pool") })
      .to eq("primary" => 7, "queue" => 7, "cache" => 7, "cable" => 7)
  end
end
