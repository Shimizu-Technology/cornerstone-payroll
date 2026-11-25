# frozen_string_literal: true

# Serving a frozen employee document (M4-4 stubs, M4-5 W-2GU copies): the
# exact bytes that were posted, or nothing. Responses are never cached.
module EmployeePortalFrozenDocuments
  extend ActiveSupport::Concern

  private

  def no_store
    response.headers["Cache-Control"] = "no-store"
  end

  # Storage can be slow, so after the bytes come back the link, the
  # company's switch and the document are read again, uncached, before
  # anything is audited or sent: a withdrawal, a revoked or ended link, or a
  # switch turned off during the fetch is honored. The block re-checks the
  # document from the fresh link.
  def still_servable?(document, feature:)
    ActiveRecord::Base.uncached do
      link = EmployeeAccountLink.portal_eligible.includes(company: :organization)
        .find_by(id: @employee_link.id, company_id: @employee_link.company_id, user_id: @employee_link.user_id,
          employee_id: @employee_link.employee_id)
      next false unless link&.portal_enabled? && CompanyFeatures.for(link.company).employee_portal_feature?(feature)

      current = EmployeeDocument.find_by(id: document.id, company_id: link.company_id)
      current.present? && current.storage_key == document.storage_key && current.sha256 == document.sha256 &&
        yield(link, current)
    end
  end

  # The frozen bytes, or nil (reported) when storage can't return the exact
  # file that was posted.
  def stored_bytes(document)
    bytes = R2StorageService.new.download(document.storage_key)
    return bytes if bytes && Digest::SHA256.hexdigest(bytes) == document.sha256

    Rails.error.report(StandardError.new("Employee document #{document.id} is missing or changed in storage"), handled: true)
    nil
  rescue R2StorageService::DownloadError => e
    Rails.error.report(e, handled: true)
    nil
  end
end
