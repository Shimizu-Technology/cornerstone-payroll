# frozen_string_literal: true

require "rails_helper"
require "base64"
require "digest"

RSpec.describe ClerkTokenVerifier do
  let(:rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwk) { JWT::JWK.new(rsa_key) }
  let(:jwk_hash) { jwk.export.deep_stringify_keys }
  let(:live_host) { "clerk.shimizu-technology.com" }
  let(:dev_host) { "smiling-fox-12.clerk.accounts.dev" }
  let(:pk_live) { "pk_live_#{Base64.strict_encode64("#{live_host}$").delete('=')}" }
  let(:pk_test) { "pk_test_#{Base64.strict_encode64("#{dev_host}$")}" }

  def encode_token(payload = nil, signing_key: rsa_key, kid: jwk.kid, **claims)
    JWT.encode(payload || claims, signing_key, "RS256", { kid: kid })
  end

  describe "issuer and API base resolution" do
    it "derives a custom-domain HTTPS issuer from pk_live_ when CLERK_ISSUER and CLERK_API_BASE are unset" do
      verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => pk_live })

      expect(verifier.clerk_issuer).to eq("https://#{live_host}")
      expect(verifier.clerk_api_base).to eq("https://#{live_host}")
    end

    it "derives a dev HTTPS issuer from pk_test_ when CLERK_ISSUER and CLERK_API_BASE are unset" do
      verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => pk_test })

      expect(verifier.clerk_issuer).to eq("https://#{dev_host}")
      expect(verifier.clerk_api_base).to eq("https://#{dev_host}")
    end

    it "prefers explicit CLERK_ISSUER and derives CLERK_API_BASE from it when CLERK_API_BASE is unset" do
      verifier = described_class.new(
        env: {
          "CLERK_PUBLISHABLE_KEY" => pk_test,
          "CLERK_ISSUER" => "https://clerk.custom.example.com/"
        }
      )

      expect(verifier.clerk_issuer).to eq("https://clerk.custom.example.com")
      expect(verifier.clerk_api_base).to eq("https://clerk.custom.example.com")
    end

    it "falls back to CLERK_INSTANCE_ID when CLERK_ISSUER and CLERK_PUBLISHABLE_KEY are unset" do
      verifier = described_class.new(env: { "CLERK_INSTANCE_ID" => "gentle-duck-42" })

      expect(verifier.clerk_issuer).to eq("https://gentle-duck-42.clerk.accounts.dev")
    end

    it "fails closed when publishable key is malformed and no explicit issuer is configured" do
      verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => "pk_live_not-valid-base64!!!" })

      expect(verifier.clerk_issuer).to be_nil
      expect(verifier.verify("any.jwt.token")).to be_nil
    end
  end

  describe "per-issuer JWKS caching and cache clearing" do
    it "reads JWKS from RequestPathCache under an issuer-scoped SHA-256 cache key instead of Rails.cache" do
      issuer = "https://#{live_host}"
      expected_key = "clerk_jwks:#{Digest::SHA256.hexdigest(issuer)}"
      request_store = instance_double(ActiveSupport::Cache::Store)
      allow(RequestPathCache).to receive(:store).and_return(request_store)
      allow(request_store).to receive(:fetch)
        .with(expected_key, expires_in: 1.hour, skip_nil: true)
        .and_return([])
      expect(Rails).not_to receive(:cache)

      verifier = described_class.new(env: { "CLERK_ISSUER" => issuer })
      expect(verifier.send(:fetch_jwks)).to eq([])
    end

    it "isolates JWKS cache entries per issuer so switching issuers never serves stale keys" do
      cache = ActiveSupport::Cache::MemoryStore.new
      key_a = OpenSSL::PKey::RSA.generate(2048)
      key_b = OpenSSL::PKey::RSA.generate(2048)
      jwk_a = JWT::JWK.new(key_a)
      jwk_b = JWT::JWK.new(key_b)

      http_get = lambda do |uri|
        case uri.host
        when dev_host
          [ 200, { "keys" => [ jwk_a.export.deep_stringify_keys ] } ]
        when live_host
          [ 200, { "keys" => [ jwk_b.export.deep_stringify_keys ] } ]
        else
          [ 404, {} ]
        end
      end

      dev_verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => pk_test }, cache: cache, http_get: http_get)
      live_verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => pk_live }, cache: cache, http_get: http_get)

      expect(dev_verifier.jwks_cache_key).not_to eq(live_verifier.jwks_cache_key)

      dev_token = encode_token({ sub: "user_dev", iss: "https://#{dev_host}", exp: 10.minutes.from_now.to_i }, signing_key: key_a, kid: jwk_a.kid)
      live_token = encode_token({ sub: "user_live", iss: "https://#{live_host}", exp: 10.minutes.from_now.to_i }, signing_key: key_b, kid: jwk_b.kid)

      expect(dev_verifier.verify(dev_token)["sub"]).to eq("user_dev")
      expect(live_verifier.verify(live_token)["sub"]).to eq("user_live")
      expect(live_verifier.verify(dev_token)).to be_nil
      expect(dev_verifier.verify(live_token)).to be_nil
    end

    it "refreshes JWKS once on an unknown kid rotation miss and respects cooldown for repeated misses" do
      cache = ActiveSupport::Cache::MemoryStore.new
      rotated_key = OpenSSL::PKey::RSA.generate(2048)
      rotated_jwk = JWT::JWK.new(rotated_key)
      fetch_count = 0

      http_get = lambda do |_uri|
        fetch_count += 1
        keys = fetch_count == 1 ? [ jwk_hash ] : [ jwk_hash, rotated_jwk.export.deep_stringify_keys ]
        [ 200, { "keys" => keys } ]
      end

      verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => pk_live }, cache: cache, http_get: http_get)

      initial_token = encode_token({ sub: "user_1", iss: "https://#{live_host}", exp: 10.minutes.from_now.to_i })
      expect(verifier.verify(initial_token)["sub"]).to eq("user_1")
      expect(fetch_count).to eq(1)

      rotated_token = encode_token(
        { sub: "user_2", iss: "https://#{live_host}", exp: 10.minutes.from_now.to_i },
        signing_key: rotated_key,
        kid: rotated_jwk.kid
      )
      expect(verifier.verify(rotated_token)["sub"]).to eq("user_2")
      expect(fetch_count).to eq(2)

      # Subsequent bogus kid within cooldown window does not hammer JWKS endpoint.
      bogus_token = encode_token(
        { sub: "user_3", iss: "https://#{live_host}", exp: 10.minutes.from_now.to_i },
        signing_key: rotated_key,
        kid: "kid_does_not_exist"
      )
      expect(verifier.verify(bogus_token)).to be_nil
      expect(fetch_count).to eq(2)
    end

    it "clears issuer-scoped and legacy JWKS cache entries" do
      cache = ActiveSupport::Cache::MemoryStore.new
      verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => pk_live }, cache: cache)
      cache.write(verifier.jwks_cache_key, [ jwk_hash ])
      cache.write("clerk_jwks", [ jwk_hash ])
      cache.write(described_class.jwks_cache_key("https://#{dev_host}"), [ jwk_hash ])

      result = verifier.clear_jwks_cache!(extra_issuers: [ "https://#{dev_host}" ])

      expect(result[:issuer]).to eq("https://#{live_host}")
      expect(cache.read(verifier.jwks_cache_key)).to be_nil
      expect(cache.read("clerk_jwks")).to be_nil
      expect(cache.read(described_class.jwks_cache_key("https://#{dev_host}"))).to be_nil
    end
  end

  describe "RS256 verification, nbf, exp, and azp enforcement" do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }
    let(:http_get) { ->(_uri) { [ 200, { "keys" => [ jwk_hash ] } ] } }

    it "verifies a valid RS256 token signed for a pk_live_ custom-domain issuer with an allowed azp" do
      verifier = described_class.new(
        env: {
          "CLERK_PUBLISHABLE_KEY" => pk_live,
          "CLERK_AUTHORIZED_PARTIES" => "https://payroll.shimizu-technology.com"
        },
        cache: cache,
        http_get: http_get
      )
      token = encode_token(
        sub: "user_live_1",
        iss: "https://#{live_host}",
        azp: "https://payroll.shimizu-technology.com",
        nbf: 1.minute.ago.to_i,
        exp: 10.minutes.from_now.to_i,
        fva: [ 2, -1 ]
      )

      payload = verifier.verify(token)

      expect(payload).to include(
        "sub" => "user_live_1",
        "azp" => "https://payroll.shimizu-technology.com",
        "fva" => [ 2, -1 ]
      )
    end

    it "verifies a valid RS256 token when CLERK_ISSUER is set explicitly for a pk_live_ instance" do
      verifier = described_class.new(
        env: {
          "CLERK_PUBLISHABLE_KEY" => pk_live,
          "CLERK_ISSUER" => "https://#{live_host}",
          "CLERK_AUTHORIZED_PARTIES" => "https://payroll.shimizu-technology.com, https://mosa.shimizu-technology.com"
        },
        cache: cache,
        http_get: http_get
      )
      token = encode_token(
        sub: "user_live_2",
        iss: "https://#{live_host}",
        azp: "https://mosa.shimizu-technology.com",
        exp: 10.minutes.from_now.to_i
      )

      expect(verifier.verify(token)).to include("sub" => "user_live_2")
    end

    it "normalizes mixed-case hosts and default :443 ports across CLERK_AUTHORIZED_PARTIES and azp claims" do
      verifier = described_class.new(
        env: {
          "CLERK_PUBLISHABLE_KEY" => pk_live,
          "CLERK_AUTHORIZED_PARTIES" => "HTTPS://Payroll.Shimizu-Technology.COM:443/"
        },
        cache: cache,
        http_get: http_get
      )
      lowercase_azp_token = encode_token(
        sub: "user_live_norm_1",
        iss: "https://#{live_host}",
        azp: "https://payroll.shimizu-technology.com",
        exp: 10.minutes.from_now.to_i
      )
      mixed_port_azp_token = encode_token(
        sub: "user_live_norm_2",
        iss: "https://#{live_host}",
        azp: "https://Payroll.Shimizu-Technology.com:443",
        exp: 10.minutes.from_now.to_i
      )

      expect(verifier.verify(lowercase_azp_token)).to include("sub" => "user_live_norm_1")
      expect(verifier.verify(mixed_port_azp_token)).to include("sub" => "user_live_norm_2")
    end

    it "fails closed and rejects tokens with a missing azp claim when CLERK_AUTHORIZED_PARTIES is configured" do
      verifier = described_class.new(
        env: {
          "CLERK_PUBLISHABLE_KEY" => pk_live,
          "CLERK_AUTHORIZED_PARTIES" => "https://payroll.shimizu-technology.com"
        },
        cache: cache,
        http_get: http_get
      )
      token = encode_token(
        sub: "user_no_azp",
        iss: "https://#{live_host}",
        exp: 10.minutes.from_now.to_i
      )

      expect(verifier.verify(token)).to be_nil
    end

    it "rejects tokens with a blank or non-string azp claim when CLERK_AUTHORIZED_PARTIES is configured" do
      verifier = described_class.new(
        env: {
          "CLERK_PUBLISHABLE_KEY" => pk_live,
          "CLERK_AUTHORIZED_PARTIES" => "https://payroll.shimizu-technology.com"
        },
        cache: cache,
        http_get: http_get
      )

      [ "", "   ", [ "https://payroll.shimizu-technology.com" ] ].each do |bad_azp|
        token = encode_token(
          sub: "user_bad_azp",
          iss: "https://#{live_host}",
          azp: bad_azp,
          exp: 10.minutes.from_now.to_i
        )
        expect(verifier.verify(token)).to be_nil
      end
    end

    it "rejects tokens whose azp claim is not in CLERK_AUTHORIZED_PARTIES" do
      verifier = described_class.new(
        env: {
          "CLERK_PUBLISHABLE_KEY" => pk_live,
          "CLERK_AUTHORIZED_PARTIES" => "https://payroll.shimizu-technology.com"
        },
        cache: cache,
        http_get: http_get
      )
      token = encode_token(
        sub: "user_wrong_azp",
        iss: "https://#{live_host}",
        azp: "https://evil.shimizu-technology.com",
        exp: 10.minutes.from_now.to_i
      )

      expect(verifier.verify(token)).to be_nil
    end

    it "fails closed when CLERK_AUTHORIZED_PARTIES is set to whitespace or commas without valid origins" do
      verifier = described_class.new(
        env: {
          "CLERK_PUBLISHABLE_KEY" => pk_live,
          "CLERK_AUTHORIZED_PARTIES" => " , "
        },
        cache: cache,
        http_get: http_get
      )
      token = encode_token(
        sub: "user_empty_allowlist",
        iss: "https://#{live_host}",
        azp: "https://payroll.shimizu-technology.com",
        exp: 10.minutes.from_now.to_i
      )

      expect(verifier.verify(token)).to be_nil
    end

    it "accepts tokens without azp when CLERK_AUTHORIZED_PARTIES is unset (backward-compatible dev/pre-cutover mode)" do
      verifier = described_class.new(
        env: { "CLERK_PUBLISHABLE_KEY" => pk_test },
        cache: cache,
        http_get: http_get
      )
      token = encode_token(
        sub: "user_dev_no_azp",
        iss: "https://#{dev_host}",
        exp: 10.minutes.from_now.to_i
      )

      expect(verifier.verify(token)).to include("sub" => "user_dev_no_azp")
    end

    it "rejects expired tokens" do
      verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => pk_live }, cache: cache, http_get: http_get)
      token = encode_token(
        sub: "user_expired",
        iss: "https://#{live_host}",
        exp: 1.minute.ago.to_i
      )

      expect(verifier.verify(token)).to be_nil
    end

    it "rejects tokens with a future nbf (not before) claim" do
      verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => pk_live }, cache: cache, http_get: http_get)
      token = encode_token(
        sub: "user_future_nbf",
        iss: "https://#{live_host}",
        nbf: 2.minutes.from_now.to_i,
        exp: 10.minutes.from_now.to_i
      )

      expect(verifier.verify(token)).to be_nil
    end

    it "rejects tokens signed for a mismatched issuer" do
      verifier = described_class.new(env: { "CLERK_PUBLISHABLE_KEY" => pk_live }, cache: cache, http_get: http_get)
      token = encode_token(
        sub: "user_wrong_iss",
        iss: "https://#{dev_host}",
        exp: 10.minutes.from_now.to_i
      )

      expect(verifier.verify(token)).to be_nil
    end
  end
end
