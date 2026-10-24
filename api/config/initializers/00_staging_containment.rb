# frozen_string_literal: true

require Rails.root.join("lib/staging_outbound_policy")
StagingOutboundPolicy.validate!
StagingDatabasePolicy.validate_rails!

require "active_record/connection_adapters/postgresql_adapter"
module StagingDatabaseConnectionGuard
  def new_client(parameters)
    StagingDatabasePolicy.validate_parameters!(parameters)
    raw = super
    begin
      StagingDatabasePolicy.validate_live!(raw)
    rescue StagingOutboundPolicy::ConfigurationError
      raw.close
      raise
    end
    raw
  end
end
ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.singleton_class.prepend(StagingDatabaseConnectionGuard)

module StagingHttpGuard
  def request(request, *args, &block)
    StagingOutboundPolicy.http_request!(self, request)
    super
  end

  private

  def connect
    StagingOutboundPolicy.http_host!(address, port, use_ssl?)
    super
  end
end
Net::HTTP.prepend(StagingHttpGuard)
