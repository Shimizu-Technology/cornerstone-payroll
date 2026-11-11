# frozen_string_literal: true

namespace :employees do
  desc "Encrypt any business-contractor EIN still stored as plaintext (safe to rerun)"
  task encrypt_contractor_eins: :environment do
    encrypted = ContractorEinEncryption.backfill!
    remaining = ContractorEinEncryption.plaintext_ids.size
    puts JSON.generate(encrypted: encrypted, plaintext_remaining: remaining)
    abort "Plaintext contractor EINs remain" if remaining.positive?
  end
end
