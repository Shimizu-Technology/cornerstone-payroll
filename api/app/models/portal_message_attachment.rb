# frozen_string_literal: true

# One file attached to a portal message. Membership is fixed once the message
# is sent; an archived file stays linked so the message shows a named record.
class PortalMessageAttachment < ApplicationRecord
  belongs_to :company
  belongs_to :client_portal_message, inverse_of: :attachments
  belongs_to :client_document

  validate :same_company
  before_update { raise ActiveRecord::ReadOnlyRecord, "Message attachments cannot be changed" }

  private

  def same_company
    errors.add(:client_document, "must belong to the same company") if client_document && client_document.company_id != company_id
    errors.add(:client_portal_message, "must belong to the same company") if client_portal_message && client_portal_message.company_id != company_id
  end
end
