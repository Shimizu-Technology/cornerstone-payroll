# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :user, :organization_id, :company_id, :request_id, :ip_address, :user_agent
end
