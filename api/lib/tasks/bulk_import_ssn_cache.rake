# frozen_string_literal: true

namespace :bulk_import_ssn_cache do
  desc "Purge any legacy plaintext bulk_import_ssn:* entries from Solid Cache (leaves v2 encrypted entries intact)"
  task purge_legacy: :environment do
    deleted = EmployeeBulkImport::SsnPreviewCache.purge_legacy_entries!
    puts "Purged #{deleted} legacy bulk_import_ssn cache #{deleted == 1 ? 'entry' : 'entries'}."
  end
end
