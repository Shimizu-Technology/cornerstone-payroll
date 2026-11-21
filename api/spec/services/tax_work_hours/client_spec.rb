# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe TaxWorkHours::Client do
  let(:secret) { "example-work-hours-secret" }
  let(:configuration) { TaxWorkHours::Configuration.new(base_url: "https://tax.example.test", secret: secret) }
  let(:now) { Time.at(1_795_000_000) }
  let(:sleeps) { [] }
  let(:client) { described_class.new(configuration: configuration, sleeper: ->(seconds) { sleeps << seconds }, clock: -> { now }) }
  let(:url) { "https://tax.example.test/api/v1/payroll/work_hours?end=2026-11-29&start=2026-11-16" }
  let(:payload) do
    {
      schema_version: "1.0", source: "cornerstone_tax", start_date: "2026-11-16", end_date: "2026-11-29",
      generated_at: "2026-11-30T01:00:00Z",
      rows: [ { tax_user_id: 12, email: "staff@example.com", work_date: "2026-11-16", client_id: 345, client_name: "Example Co",
                system_kind: nil, unassigned: false, category_id: 3, category: "Bookkeeping", task_id: 9, task: "Bank reconciliation",
                period_type: "month", period_start: "2026-10-01", period_label: "October 2026", hours: 2.5, minutes: 150,
                entry_ids: [ 1001 ], approval_state: "approved", future_field: "ignored" } ],
      counts: { pending_entries: 1, denied_entries: 0, open_clock_entries: 0 }
    }.to_json
  end

  def fetch
    client.fetch(start_date: Date.new(2026, 11, 16), end_date: Date.new(2026, 11, 29))
  end

  it "sends exactly the contract's signed request and returns the payload" do
    stub = stub_request(:get, url).with(headers: {
      "X-Work-Hours-Timestamp" => "1795000000",
      "X-Work-Hours-Signature" => "250fc497fc6345e0f7ad2fec54d5b4ca3122d1845b527a80c0535c69b04e67b1"
    }).to_return(status: 200, body: payload)

    expect(fetch.fetch("rows").first).to include("client_name" => "Example Co", "hours" => 2.5)
    expect(stub).to have_been_requested.once
  end

  it "signs the full path when Tax is served under a path prefix" do
    prefixed = TaxWorkHours::Configuration.new(base_url: "https://tax.example.test/backend/", secret: secret)
    path = "/backend/api/v1/payroll/work_hours"
    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, [ "GET", path, "end=2026-11-29&start=2026-11-16", "1795000000",
                                                           OpenSSL::Digest::SHA256.hexdigest("") ].join("\n"))
    stub_request(:get, "https://tax.example.test#{path}?end=2026-11-29&start=2026-11-16")
      .with(headers: { "X-Work-Hours-Timestamp" => "1795000000", "X-Work-Hours-Signature" => expected })
      .to_return(status: 200, body: payload)
    result = described_class.new(configuration: prefixed, clock: -> { now })
                            .fetch(start_date: Date.new(2026, 11, 16), end_date: Date.new(2026, 11, 29))
    expect(result.fetch("rows").length).to eq(1)
  end

  it "reports a rejected signature as unauthorized without retrying" do
    stub = stub_request(:get, url).to_return(status: 401, body: { error: "Unauthorized: signature does not match" }.to_json)
    expect { fetch }.to raise_error(TaxWorkHours::Error) { |error| expect(error.code).to eq("unauthorized") }
    expect(stub).to have_been_requested.once
  end

  it "reports Tax's missing secret (503) without retrying" do
    stub = stub_request(:get, url).to_return(status: 503, body: { error: "Service unavailable" }.to_json)
    expect { fetch }.to raise_error(TaxWorkHours::Error) { |error| expect(error.code).to eq("tax_not_configured") }
    expect(stub).to have_been_requested.once
  end

  it "retries timeouts with backoff, then reports a network error" do
    stub = stub_request(:get, url).to_timeout
    expect { fetch }.to raise_error(TaxWorkHours::Error) { |error| expect(error.code).to eq("network") }
    expect(stub).to have_been_requested.times(3)
    expect(sleeps).to eq([ 0.5, 1.0 ])
  end

  it "recovers when a retry succeeds after a gateway error" do
    stub_request(:get, url).to_return({ status: 502, body: "" }, { status: 200, body: payload })
    expect(fetch.fetch("schema_version")).to eq("1.0")
    expect(sleeps).to eq([ 0.5 ])
  end

  it "rejects a payload from another schema version or with incomplete rows" do
    stub_request(:get, url).to_return(status: 200, body: { schema_version: "2.0", rows: [] }.to_json)
    expect { fetch }.to raise_error(TaxWorkHours::Error) { |error| expect(error.code).to eq("bad_response") }

    stub_request(:get, url).to_return(status: 200, body: { schema_version: "1.0", rows: [ { tax_user_id: 1 } ] }.to_json)
    expect { fetch }.to raise_error(TaxWorkHours::Error, /row 1/)

    stub_request(:get, url).to_return(status: 200, body: "<html>")
    expect { fetch }.to raise_error(TaxWorkHours::Error) { |error| expect(error.code).to eq("bad_response") }
  end

  it "does not call Tax when the connection isn't configured" do
    missing = described_class.new(configuration: TaxWorkHours::Configuration.new(base_url: nil, secret: secret))
    expect { missing.fetch(start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 2)) }
      .to raise_error(TaxWorkHours::Error) { |error| expect(error.code).to eq("not_connected") }
  end

  it "never puts the secret in an error message" do
    stub_request(:get, url).to_return(status: 401, body: "")
    expect { fetch }.to raise_error(TaxWorkHours::Error) { |error| expect(error.message).not_to include(secret) }
  end
end

RSpec.describe TaxWorkHours::Configuration do
  it "is not connected until both the address and the secret are set, and never exposes the secret" do
    expect(described_class.new(base_url: nil, secret: nil).status_json).to include(connected: false,
      missing: %w[CORNERSTONE_TAX_API_URL PAYROLL_WORK_HOURS_SECRET])
    connected = described_class.new(base_url: "https://tax.example.test", secret: "s3cret-value")
    expect(connected.status_json).to eq(connected: true, missing: [], problem: nil, tax_host: "tax.example.test")
    expect(connected.status_json.to_json).not_to include("s3cret-value")
  end

  it "requires https except for a local stub outside production" do
    expect(described_class.new(base_url: "http://tax.example.test", secret: "x")).not_to be_connected
    expect(described_class.new(base_url: "http://127.0.0.1:4010", secret: "x")).to be_connected
    expect(described_class.new(base_url: "not a url", secret: "x").url_problem).to match(/valid web address/)
  end
end
