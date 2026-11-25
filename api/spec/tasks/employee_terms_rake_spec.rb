# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "employee_terms:publish" do
  let(:task) { Rake::Task["employee_terms:publish"] }
  let(:settings) do
    { "VERSION" => "2026-12-01-draft", "STATUS" => "draft", "TERMS_URL" => "https://example.com/terms",
      "PRIVACY_URL" => "/legal/privacy", "TERMS_FILE" => __FILE__ }
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("employee_terms:publish")
    task.reenable
  end

  around do |example|
    saved = settings.keys.index_with { |key| ENV[key] }
    settings.each { |key, value| ENV[key] = value }
    example.run
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  it "records an immutable terms version that becomes current" do
    expect { task.invoke }.to output(/Recorded Employee App Terms 2026-12-01-draft \(draft\)/).to_stdout
    version = EmployeeTermsVersion.current
    expect(version).to have_attributes(version: "2026-12-01-draft", status: "draft", privacy_url: "/legal/privacy")
    expect(version).to be_readonly

    ENV["VERSION"] = "2026-12-01"
    ENV["STATUS"] = "approved"
    task.reenable
    expect { task.invoke }.to output(/approved/).to_stdout
    expect(EmployeeTermsVersion.current.version).to eq("2026-12-01")
  end

  it "refuses an address that isn't https or a site path" do
    ENV["TERMS_URL"] = "http://example.com/terms"
    expect { task.invoke }.to raise_error(ActiveRecord::RecordInvalid, /must be an https/)
  end
end
