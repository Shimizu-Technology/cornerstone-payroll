#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"

source, destination = ARGV
abort "Usage: encrypt_aire_rollout_manifest.rb PRIVATE_JSON OUTPUT_ENVELOPE" unless source && destination
key_hex = ENV.fetch("AIRE_ROLLOUT_MANIFEST_KEY")
abort "AIRE_ROLLOUT_MANIFEST_KEY must be 32 random bytes in hex" unless key_hex.match?(/\A[0-9a-f]{64}\z/i)
abort "Source manifest must be owner-only" unless (File.stat(source).mode & 0o077).zero?

bytes = File.binread(source)
JSON.parse(bytes)
cipher = OpenSSL::Cipher.new("aes-256-gcm")
cipher.encrypt
cipher.key = [ key_hex ].pack("H*")
nonce = OpenSSL::Random.random_bytes(12)
cipher.iv = nonce
cipher.auth_data = "cornerstone-aire-history-rollout-v1"
ciphertext = cipher.update(bytes) + cipher.final
envelope = {
  version: 1,
  algorithm: "aes-256-gcm",
  nonce: Base64.strict_encode64(nonce),
  tag: Base64.strict_encode64(cipher.auth_tag),
  ciphertext: Base64.strict_encode64(ciphertext)
}
File.write(destination, JSON.generate(envelope) + "\n")
warn "Wrote #{destination}"
warn "AIRE_ROLLOUT_MANIFEST_SHA256=#{Digest::SHA256.hexdigest(bytes)}"
