# frozen_string_literal: true

require "ipaddr"
require "resolv"
require "uri"

module TimeTracking
  class DestinationPolicy
    class Error < StandardError; end

    BLOCKED_NETWORKS = %w[
      0.0.0.0/8
      10.0.0.0/8
      100.64.0.0/10
      127.0.0.0/8
      169.254.0.0/16
      172.16.0.0/12
      192.0.0.0/24
      192.0.2.0/24
      192.168.0.0/16
      198.18.0.0/15
      198.51.100.0/24
      203.0.113.0/24
      224.0.0.0/4
      240.0.0.0/4
      ::/128
      ::1/128
      ::ffff:0:0/96
      64:ff9b::/96
      100::/64
      2001:db8::/32
      fc00::/7
      fe80::/10
      ff00::/8
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    def self.allowed_hosts(env: ENV)
      env.fetch("TIME_TRACKING_ALLOWED_HOSTS", "")
        .split(",")
        .map { |host| normalize_host(host) }
        .compact_blank
        .uniq
    end

    def self.normalize_host(host)
      host.to_s.strip.downcase.chomp(".")
    end

    def self.production_configuration_valid?(sources:, env: ENV)
      policy = new(environment: "production", env: env)
      Array(sources).all? do |source|
        policy.validate_configuration!(URI.parse(source.base_url.to_s))
        true
      rescue Error, URI::InvalidURIError
        false
      end
    end

    def initialize(environment: Rails.env, env: ENV, resolver: nil)
      @environment = environment.to_s
      @env = env
      @resolver = resolver || ->(host) { Resolv.getaddresses(host) }
    end

    def validate_configuration!(uri, allow_query: false)
      unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank?
        raise Error, "must be an HTTP or HTTPS URL with a host and no embedded credentials"
      end
      raise Error, "must not include a query or fragment" if (!allow_query && uri.query.present?) || uri.fragment.present?

      return uri unless production?

      raise Error, "must use HTTPS in production" unless uri.scheme == "https"
      raise Error, "must use the standard HTTPS port in production" unless uri.port == 443

      allowed_hosts = self.class.allowed_hosts(env: @env)
      raise Error, "cannot be configured until TIME_TRACKING_ALLOWED_HOSTS is set" if allowed_hosts.empty?
      raise Error, "host is not in TIME_TRACKING_ALLOWED_HOSTS" unless allowed_hosts.include?(normalized_host(uri))

      uri
    end

    def resolve_public_addresses!(uri)
      validate_configuration!(uri, allow_query: true)
      addresses = Array(@resolver.call(normalized_host(uri))).compact_blank.uniq
      raise Error, "host did not resolve to an address" if addresses.empty?

      return addresses if local_destination_allowed?(uri)

      parsed_addresses = addresses.map do |address|
        IPAddr.new(address).tap do |ip|
          raise Error, "host resolved to a non-public address" if BLOCKED_NETWORKS.any? { |network| network.include?(ip) }
        end
      rescue IPAddr::InvalidAddressError
        raise Error, "host resolved to an invalid address"
      end

      parsed_addresses.map(&:to_s).sort
    rescue Resolv::ResolvError, SocketError
      raise Error, "host could not be resolved"
    end

    private

    def production?
      @environment == "production"
    end

    def normalized_host(uri)
      self.class.normalize_host(uri.host)
    end

    def local_destination_allowed?(uri)
      return false if production?

      host = normalized_host(uri)
      host == "localhost" || host.end_with?(".localhost")
    end
  end
end
