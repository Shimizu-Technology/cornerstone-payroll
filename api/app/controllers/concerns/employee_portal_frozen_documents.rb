# frozen_string_literal: true

# Serving a frozen employee document (M4-4 stubs, M4-5 W-2GU copies): the
# exact bytes that were posted, or nothing. Responses are never cached.
module EmployeePortalFrozenDocuments
  extend ActiveSupport::Concern

  private

  def no_store
    response.headers["Cache-Control"] = "no-store"
  end

  # Storage can be slow. Recheck access, the company's switch, and the
  # document before auditing or sending any bytes.
  def still_servable?(document, feature:)
    ActiveRecord::Base.uncached do
      context = refreshed_document_access_context
      next false unless context && CompanyFeatures.for(context.company).employee_portal_feature?(feature)

      current = EmployeeDocument.find_by(id: document.id, company_id: context.company_id)
      current.present? && current.storage_key == document.storage_key && current.sha256 == document.sha256 &&
        yield(context, current)
    end
  end

  def refreshed_document_access_context
    if Current.view_as_grant
      grant = ViewAsGrant.find_by(id: Current.view_as_grant.id)
      return unless grant&.open? && ViewAsGrant.allowed_staff?(grant.staff_user) &&
        ViewAsGrant.allowed_company?(grant.staff_user, grant.company)

      context = grant.employee_context
      original = employee_access_context
      context if context && context.employee_id == original.employee_id &&
        context.id == original.id && context.user&.id == original.user&.id
    else
      link = EmployeeAccountLink.portal_eligible.includes(company: :organization)
        .find_by(id: @employee_link.id, company_id: @employee_link.company_id, user_id: @employee_link.user_id,
          employee_id: @employee_link.employee_id)
      link if link&.portal_enabled?
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
