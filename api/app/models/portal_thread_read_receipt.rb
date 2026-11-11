# frozen_string_literal: true

class PortalThreadReadReceipt < ApplicationRecord
  belongs_to :client_portal_thread
  belongs_to :user
  validates :last_displayed_message_id, :opened_at, presence: true
end
