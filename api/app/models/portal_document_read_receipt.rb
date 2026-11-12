# frozen_string_literal: true

class PortalDocumentReadReceipt < ApplicationRecord
  belongs_to :client_document
  belongs_to :user
end
