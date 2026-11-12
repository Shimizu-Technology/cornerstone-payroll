# frozen_string_literal: true

namespace :employees do
  desc "Encrypt any business-contractor EIN still stored as plaintext. Run once web and worker are on the new revision (safe to rerun)"
  task encrypt_contractor_eins: :environment do
    encrypted = ContractorEinEncryption.backfill!
    remaining = ContractorEinEncryption.plaintext_ids.size
    puts JSON.generate(encrypted: encrypted, plaintext_remaining: remaining)
    abort "Plaintext contractor EINs remain" if remaining.positive?
  end

  desc "Rewrite encrypted business-contractor EINs as plaintext. Run on the new revision before rolling the code back (safe to rerun)"
  task decrypt_contractor_eins: :environment do
    decrypted = ContractorEinEncryption.restore_plaintext!
    remaining = ContractorEinEncryption.encrypted_ids.size
    puts JSON.generate(decrypted: decrypted, ciphertext_remaining: remaining)
    abort "Encrypted contractor EINs remain" if remaining.positive?
  end
end
