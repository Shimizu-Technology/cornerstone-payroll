# frozen_string_literal: true

# Safety net on boot: remove any legacy plaintext bulk_import_ssn:<uuid>
# entries left in Solid Cache before the v2 encrypted namespace deployed.
# Idempotent and scoped to exclude v2 encrypted entries.
Rails.application.config.after_initialize do
  next unless defined?(SolidCache::Store) && Rails.cache.is_a?(SolidCache::Store)
  next if defined?(Rails::Console) || File.basename($PROGRAM_NAME) == "rake"

  deleted = EmployeeBulkImport::SsnPreviewCache.purge_legacy_entries!
  if deleted.positive?
    Rails.logger.info("[EmployeeBulkImport::SsnPreviewCache] Purged #{deleted} legacy plaintext cache #{deleted == 1 ? 'entry' : 'entries'} on boot")
  end
rescue StandardError => e
  Rails.logger.warn("[EmployeeBulkImport::SsnPreviewCache] Legacy cache boot purge skipped: #{e.class}")
end
