# frozen_string_literal: true

# Serving a frozen employee document (M4-4 stubs, M4-5 W-2GU copies): the
# exact bytes that were posted, or nothing. Responses are never cached.
module EmployeePortalFrozenDocuments
  extend ActiveSupport::Concern

  private

  def no_store
    response.headers["Cache-Control"] = "no-store"
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
