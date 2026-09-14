# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "operations:queue_probe" do
  let(:managed_env_keys) { %w[PROBE_ID TTL_HOURS] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("operations:queue_probe:enqueue")
    @previous_env = managed_env_keys.index_with { |key| ENV[key] }
    managed_env_keys.each { |key| ENV.delete(key) }
  end

  after do
    @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  it "rejects line breaks before looking up a probe" do
    ENV["PROBE_ID"] = "#{SecureRandom.uuid}\n"
    task = Rake::Task["operations:queue_probe:status"]
    task.reenable

    expect { task.invoke }.to raise_error(SystemExit)
      .and output(a_string_including("PROBE_ID must not contain line breaks")).to_stderr
  end

  it "rejects an out-of-range lifetime before creating a probe" do
    ENV["PROBE_ID"] = SecureRandom.uuid
    ENV["TTL_HOURS"] = "169"
    task = Rake::Task["operations:queue_probe:enqueue"]
    task.reenable

    expect { task.invoke }.to raise_error(SystemExit)
      .and output(a_string_including("TTL_HOURS must be between 1 and 168")).to_stderr
    expect(OperationalQueueProbe).not_to exist
  end
end
