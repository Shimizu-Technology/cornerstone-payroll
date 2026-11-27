# frozen_string_literal: true

module PayrollIntake
  # Central registry of descriptor-backed payroll intake adapters.
  #
  # Built-in adapters are registered in a deterministic order. Future Track C
  # steps (B8 universal workbook, additional client adapters) register here so
  # validation, preview/apply orchestration, and the intake_profile endpoints
  # discover them without static source-type maps.
  class Registry
    class UnknownAdapterError < ArgumentError; end

    BUILT_IN_ADAPTER_NAMES = %w[
      PayrollIntake::Adapters::SpikeEmail
      PayrollIntake::Adapters::MosaRevel
    ].freeze

    class << self
      def all
        descriptors_by_key.values
      end

      def keys
        descriptors_by_key.keys
      end

      def find(key)
        return nil if key.blank?

        descriptors_by_key[key.to_s]
      end

      def fetch(key)
        find(key) || raise(UnknownAdapterError, "Unknown payroll intake adapter: #{key}")
      end

      def adapter_for(key)
        find(key)&.adapter_class
      end

      def registered?(key)
        find(key).present?
      end

      def portal_roles
        all.select(&:portal_submittable?).flat_map(&:portal_roles).uniq
      end

      def tracks_reviewed_hours_keys
        all.select(&:tracks_reviewed_hours?).map(&:key)
      end

      def for_company(company)
        return [] unless company

        Array(company.payroll_intake_source_types).filter_map { |key| find(key) }
      end

      def portal_submittable_for_company(company)
        for_company(company).select(&:portal_submittable?)
      end

      def register(adapter_or_descriptor)
        descriptor = extract_descriptor(adapter_or_descriptor)
        @descriptors_by_key = descriptors_by_key.merge(descriptor.key => descriptor).freeze
        descriptor
      end

      def reset!
        @descriptors_by_key = nil
        descriptors_by_key
      end

      private

      def descriptors_by_key
        @descriptors_by_key ||= build_default_registry
      end

      def build_default_registry
        BUILT_IN_ADAPTER_NAMES.each_with_object({}) do |class_name, registry|
          descriptor = extract_descriptor(class_name.constantize)
          registry[descriptor.key] = descriptor
        end.freeze
      end

      def extract_descriptor(adapter_or_descriptor)
        return adapter_or_descriptor if adapter_or_descriptor.is_a?(PayrollIntake::Descriptor)
        if adapter_or_descriptor.respond_to?(:descriptor) && adapter_or_descriptor.descriptor.is_a?(PayrollIntake::Descriptor)
          return adapter_or_descriptor.descriptor
        end

        raise ArgumentError, "Adapter #{adapter_or_descriptor.inspect} must provide a PayrollIntake::Descriptor"
      end
    end
  end
end
