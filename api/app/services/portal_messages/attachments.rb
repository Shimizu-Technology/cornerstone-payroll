# frozen_string_literal: true

module PortalMessages
  # Resolves the files a person asked to attach, in their order, within the
  # selected company. Clients only ever see shared files, so a staff-only or
  # other-company file is simply "not found" to them. Visibility, archive and
  # safety are rechecked under lock when the message is saved.
  module Attachments
    module_function

    def requested_ids(params)
      ids = Array(params[:document_ids]).compact_blank.presence || Array(params[:document_id].presence)
      ids.map { |id| Integer(id.to_s, 10) }.uniq
    rescue ArgumentError
      raise invalid("not found")
    end

    def resolve!(company_id:, user:, ids:)
      raise invalid("Attach no more than #{ClientPortalMessage::MAX_ATTACHMENTS} files to one message") if ids.size > ClientPortalMessage::MAX_ATTACHMENTS
      return [] if ids.empty?

      scope = ClientDocument.where(company_id: company_id, id: ids)
      scope = scope.client_visible unless user&.staff_member?
      found = scope.index_by(&:id)
      raise invalid("not found") unless ids.all? { |id| found.key?(id) }

      ids.map { |id| found.fetch(id) }
    end

    def invalid(message)
      ActiveRecord::RecordInvalid.new(ClientPortalMessage.new.tap { |record| record.errors.add(:client_document, message) })
    end
  end
end
