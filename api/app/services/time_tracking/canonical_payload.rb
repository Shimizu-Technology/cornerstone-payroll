# frozen_string_literal: true

require "digest"

module TimeTracking
  module CanonicalPayload
    module_function

    def checksum(payload)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(payload)))
    end

    def canonicalize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key.to_s] = canonicalize(child)
        end.sort.to_h
      when Array
        value.map { |child| canonicalize(child) }
      else
        value
      end
    end
  end
end
