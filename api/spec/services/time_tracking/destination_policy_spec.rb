# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::DestinationPolicy do
  def uri(value)
    URI.parse(value)
  end

  it "requires an exact production allowlist match over standard-port HTTPS" do
    policy = described_class.new(
      environment: "production",
      env: { "TIME_TRACKING_ALLOWED_HOSTS" => "time.example.com" }
    )

    expect(policy.validate_configuration!(uri("https://time.example.com/client-a"))).to be_a(URI::HTTPS)
    expect { policy.validate_configuration!(uri("http://time.example.com")) }
      .to raise_error(described_class::Error, /HTTPS/)
    expect { policy.validate_configuration!(uri("https://sub.time.example.com")) }
      .to raise_error(described_class::Error, /not in TIME_TRACKING_ALLOWED_HOSTS/)
    expect { policy.validate_configuration!(uri("https://time.example.com:8443")) }
      .to raise_error(described_class::Error, /standard HTTPS port/)
  end

  it "fails production configuration closed when no allowlist exists" do
    policy = described_class.new(environment: "production", env: {})

    expect { policy.validate_configuration!(uri("https://time.example.com")) }
      .to raise_error(described_class::Error, /TIME_TRACKING_ALLOWED_HOSTS is set/)
  end

  it "validates every active source against the effective production policy" do
    valid_source = instance_double(TimeTrackingSource, base_url: "https://time.example.com/client")
    invalid_source = instance_double(TimeTrackingSource, base_url: "http://other.example.com")
    env = { "TIME_TRACKING_ALLOWED_HOSTS" => "time.example.com" }

    expect(described_class.production_configuration_valid?(sources: [ valid_source ], env: env)).to be(true)
    expect(described_class.production_configuration_valid?(sources: [ valid_source, invalid_source ], env: env)).to be(false)
    expect(described_class.production_configuration_valid?(sources: [], env: {})).to be(true)
  end

  it "rejects query strings and fragments in a configured base URL" do
    policy = described_class.new(environment: "test")

    expect { policy.validate_configuration!(uri("https://time.example.com?redirect=internal")) }
      .to raise_error(described_class::Error, /query or fragment/)
    expect { policy.validate_configuration!(uri("https://time.example.com#secret")) }
      .to raise_error(described_class::Error, /query or fragment/)
  end

  it "rejects private, loopback, link-local, documentation, and mixed DNS answers" do
    blocked_sets = [
      [ "10.0.0.1" ],
      [ "127.0.0.1" ],
      [ "169.254.169.254" ],
      [ "192.0.2.10" ],
      [ "::1" ],
      [ "fc00::1" ],
      [ "8.8.8.8", "10.0.0.1" ]
    ]

    blocked_sets.each do |addresses|
      policy = described_class.new(environment: "test", resolver: ->(_host) { addresses })
      expect { policy.resolve_public_addresses!(uri("https://time.example.com/summary?date=2026-01-01")) }
        .to raise_error(described_class::Error, /non-public address/), "expected #{addresses.inspect} to be rejected"
    end
  end

  it "returns only inspected public addresses in deterministic order" do
    policy = described_class.new(
      environment: "production",
      env: { "TIME_TRACKING_ALLOWED_HOSTS" => "time.example.com" },
      resolver: ->(_host) { [ "2001:4860:4860::8888", "8.8.8.8" ] }
    )

    expect(policy.resolve_public_addresses!(uri("https://time.example.com/summary?date=2026-01-01"))).to eq(
      [ "2001:4860:4860::8888", "8.8.8.8" ].sort
    )
  end

  it "permits localhost only outside production for deliberate local integration testing" do
    policy = described_class.new(environment: "development", resolver: ->(_host) { [ "127.0.0.1" ] })

    expect(policy.resolve_public_addresses!(uri("http://localhost:3001/api"))).to eq([ "127.0.0.1" ])
  end
end
