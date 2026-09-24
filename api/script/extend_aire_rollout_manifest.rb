#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "tempfile"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(root, "app", "services"))
require File.join(root, "app", "services", "time_tracking", "verified_history_manifest_extension")

source, destination = ARGV
abort "Usage: extend_aire_rollout_manifest.rb ENCRYPTED_MANIFEST OUTPUT_ENCRYPTED_MANIFEST" unless source && destination

key_hex = ENV.fetch("AIRE_ROLLOUT_MANIFEST_KEY")
abort "AIRE_ROLLOUT_MANIFEST_KEY must be 32 random bytes in hex" unless key_hex.match?(/\A[0-9a-f]{64}\z/i)

envelope = JSON.parse(File.binread(source))
abort "Unsupported encrypted manifest" unless envelope["version"] == 1 && envelope["algorithm"] == "aes-256-gcm"

decryptor = OpenSSL::Cipher.new("aes-256-gcm")
decryptor.decrypt
decryptor.key = [ key_hex ].pack("H*")
decryptor.iv = Base64.strict_decode64(envelope.fetch("nonce"))
decryptor.auth_tag = Base64.strict_decode64(envelope.fetch("tag"))
decryptor.auth_data = "cornerstone-aire-history-rollout-v1"
plaintext = decryptor.update(Base64.strict_decode64(envelope.fetch("ciphertext"))) + decryptor.final

expected_sha = ENV["AIRE_ROLLOUT_MANIFEST_SHA256"].to_s.downcase
actual_sha = Digest::SHA256.hexdigest(plaintext)
abort "Existing AIRE rollout manifest checksum differs" if !expected_sha.empty? && expected_sha != actual_sha

manifest = JSON.parse(plaintext)
extension = JSON.parse($stdin.read)
extended = TimeTracking::VerifiedHistoryManifestExtension.new(manifest:, extension:).call
bytes = JSON.generate(extended)

encryptor = OpenSSL::Cipher.new("aes-256-gcm")
encryptor.encrypt
encryptor.key = [ key_hex ].pack("H*")
nonce = OpenSSL::Random.random_bytes(12)
encryptor.iv = nonce
encryptor.auth_data = "cornerstone-aire-history-rollout-v1"
ciphertext = encryptor.update(bytes) + encryptor.final
next_envelope = {
  version: 1,
  algorithm: "aes-256-gcm",
  nonce: Base64.strict_encode64(nonce),
  tag: Base64.strict_encode64(encryptor.auth_tag),
  ciphertext: Base64.strict_encode64(ciphertext)
}

directory = File.dirname(File.expand_path(destination))
Tempfile.create([ ".aire-rollout", ".json" ], directory) do |file|
  file.chmod(0o600)
  file.write(JSON.generate(next_envelope) + "\n")
  file.flush
  file.fsync
  File.rename(file.path, destination)
end

paid_count = extended.fetch("issued_entries").length +
  extended.fetch("classification_cases").sum { |row| row.fetch("source_time_entry_ids").length } +
  extended.fetch("finalized_batch_entries").length
warn "Extended encrypted AIRE rollout manifest"
warn "AIRE_ROLLOUT_MANIFEST_SHA256=#{Digest::SHA256.hexdigest(bytes)}"
warn "delivered_checks=#{extended.fetch('delivered_checks').length} paid_source_entries=#{paid_count}"
