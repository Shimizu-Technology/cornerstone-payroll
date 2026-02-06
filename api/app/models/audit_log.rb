# frozen_string_literal: true

class AuditLog < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :company, optional: true

  validates :action, presence: true

  def self.record!(user:, company_id:, action:, record_type:, record_id:, metadata:, ip_address:, user_agent:)
    create!(
      user: user,
      company_id: company_id,
      action: action,
      record_type: record_type,
      record_id: record_id,
      metadata: metadata,
      ip_address: ip_address,
      user_agent: user_agent
    )
  end
end
