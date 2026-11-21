# frozen_string_literal: true

require "rails_helper"

# Expected values were produced by Cornerstone Tax's own code on the feed
# branch (feat/payroll-work-hours-feed, c868c31): both the doc's Ruby signer
# block in docs/PAYROLL_WORK_HOURS_FEED.md and Payroll::WorkHoursSignature.sign
# give these exact strings for the same inputs.
RSpec.describe TaxWorkHours::Signer do
  let(:secret) { "example-work-hours-secret" }
  let(:now) { Time.at(1_795_000_000) }

  it "signs the doc's example request byte for byte" do
    uri, headers = described_class.signed(secret: secret, query: { start: "2026-11-16", end: "2026-11-29" }, now: now)

    expect(uri).to eq("/api/v1/payroll/work_hours?end=2026-11-29&start=2026-11-16")
    expect(headers).to eq(
      "X-Work-Hours-Timestamp" => "1795000000",
      "X-Work-Hours-Signature" => "250fc497fc6345e0f7ad2fec54d5b4ca3122d1845b527a80c0535c69b04e67b1"
    )
  end

  it "builds the five-line string to sign with the empty-body hash and no trailing newline" do
    text = described_class.string_to_sign(method: "get", path: "/api/v1/payroll/work_hours",
                                          canonical_query: "end=2026-11-29&start=2026-11-16", timestamp: "1795000000")
    expect(text).to eq("GET\n/api/v1/payroll/work_hours\nend=2026-11-29&start=2026-11-16\n1795000000\n" \
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  end

  it "re-encodes per RFC 3986 (space as %20, upper-case hex) and sorts by name" do
    uri, headers = described_class.signed(secret: secret, query: { "b" => "x y", "a" => "ü/+" }, now: now)

    expect(uri).to eq("/api/v1/payroll/work_hours?a=%C3%BC%2F%2B&b=x%20y")
    expect(headers.fetch("X-Work-Hours-Signature")).to eq("dcf97402ef26829609342da83fa83121bf86ba7293f42af1c40d0a1bbe459eb7")
  end

  it "never signs a repeated key" do
    expect { described_class.canonical_query({ start: "2026-11-01", "start" => "2026-11-02" }) }
      .to raise_error(ArgumentError, /unique/)
  end

  it "refuses to sign without a secret" do
    expect { described_class.signed(secret: "", query: {}) }.to raise_error(ArgumentError, /secret/)
  end
end
