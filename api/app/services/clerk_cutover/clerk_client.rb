# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module ClerkCutover
  # Strictly read-only (GET-only) HTTP client for Clerk Backend API and JWKS
  # endpoints used by preflight, manifest building, and dry-run verification.
  class ClerkClient
    class Error < StandardError; end

    API_BASE_URL = "https://api.clerk.com/v1"
    MAX_RESPONSE_BYTES = 10.megabytes
    DEFAULT_PAGE_SIZE = 500
    MAX_PAGES = 200

    def initialize(secret_key: nil, http_get: nil)
      @secret_key = secret_key
      @http_get = http_get || method(:default_http_get)
    end

    def list_users(limit: DEFAULT_PAGE_SIZE)
      raise Error, "Clerk secret key is required to list users" if @secret_key.blank?

      users = []
      offset = 0
      pages = 0

      loop do
        pages += 1
        raise Error, "Clerk user pagination exceeded safety limit (#{MAX_PAGES} pages)" if pages > MAX_PAGES

        uri = URI("#{API_BASE_URL}/users?limit=#{limit}&offset=#{offset}")
        status, body = @http_get.call(uri, @secret_key)
        raise Error, "Clerk Backend API returned HTTP #{status} while listing users" unless status == 200
        raise Error, "Unexpected Clerk users payload" unless body.is_a?(Array)

        users.concat(body)
        break if body.length < limit

        offset += body.length
      end

      users
    end

    def fetch_instance
      raise Error, "Clerk secret key is required to fetch instance metadata" if @secret_key.blank?

      uri = URI("#{API_BASE_URL}/instance")
      status, body = @http_get.call(uri, @secret_key)
      raise Error, "Clerk Backend API returned HTTP #{status} while fetching instance" unless status == 200
      raise Error, "Unexpected Clerk instance payload" unless body.is_a?(Hash)

      body
    end

    def fetch_jwks(issuer)
      normalized_issuer = issuer.to_s.strip.sub(%r{/+\z}, "")
      raise Error, "Clerk issuer is required to fetch JWKS" if normalized_issuer.empty?

      uri = URI("#{normalized_issuer}/.well-known/jwks.json")
      raise Error, "Clerk issuer must be an HTTPS URL" unless uri.is_a?(URI::HTTPS) && uri.host.present?

      status, body = @http_get.call(uri, nil)
      raise Error, "Clerk JWKS endpoint returned HTTP #{status}" unless status == 200
      raise Error, "Unexpected Clerk JWKS payload" unless body.is_a?(Hash) && body["keys"].is_a?(Array)

      body["keys"]
    rescue URI::InvalidURIError
      raise Error, "Clerk issuer URL is invalid"
    end

    private

    def default_http_get(uri, bearer_token)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{bearer_token}" if bearer_token.present?
      request["Accept"] = "application/json"

      response = nil
      body = +""
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: true,
        open_timeout: 5,
        read_timeout: 15
      ) do |http|
        http.request(request) do |provider_response|
          response = provider_response
          provider_response.read_body do |chunk|
            body << chunk
            raise Error, "Clerk response exceeded size limit" if body.bytesize > MAX_RESPONSE_BYTES
          end
        end
      end

      [ response.code.to_i, JSON.parse(body) ]
    rescue Timeout::Error, Errno::ECONNREFUSED, SocketError, OpenSSL::SSL::SSLError, JSON::ParserError => e
      raise Error, "Clerk HTTP request failed (#{e.class.name})"
    end
  end
end
