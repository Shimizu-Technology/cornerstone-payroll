# frozen_string_literal: true

require "yaml"

module PayrollIntake
  # Immutable metadata describing an intake adapter's identity, file slots,
  # extraction/matching mode, idempotency contract, and portal submission map.
  #
  # B2 introduces descriptors and the registry without changing any existing
  # MoSa or Spike behavior. B4-B6 will drive staff/portal gates and UI forms
  # directly from these descriptors.
  class Descriptor
    FileSlot = Data.define(
      :role,
      :label,
      :accept,
      :content_type,
      :max,
      :required_by_default,
      :waivable,
      :portal_role,
      :provides
    ) do
      def matches?(filename:, content_type: nil)
        return true if self.content_type.present? && content_type.to_s == self.content_type

        extension = File.extname(filename.to_s).downcase
        extension.present? && accept.include?(extension)
      end

      def to_source_role_definition
        definition = { label: label }
        definition[:waiver_label] = waivable if waivable.present?
        definition.freeze
      end

      def serialize(required: required_by_default)
        {
          "role" => role,
          "label" => label,
          "accept" => accept,
          "content_type" => content_type,
          "max" => max,
          "required" => required,
          "required_by_default" => required_by_default,
          "waivable" => waivable,
          "portal_role" => portal_role,
          "provides" => provides
        }
      end
    end

    attr_reader :key, :label, :source_label, :parser_version, :adapter_class,
                :extraction, :employee_match, :idempotency, :files, :portal,
                :tips_default, :overtime_mode, :config_path, :raw_config

    def self.from_yaml(path, adapter_class:)
      resolved_path = Pathname.new(path)
      raw = YAML.safe_load_file(resolved_path)
      raise ArgumentError, "Intake descriptor #{resolved_path} must be a YAML mapping" unless raw.is_a?(Hash)

      files = (raw["files"] || {}).map do |role, definition|
        definition = definition.to_h
        FileSlot.new(
          role: role.to_s.freeze,
          label: definition.fetch("label", role.to_s.humanize).to_s.freeze,
          accept: Array(definition["extensions"]).map { |ext| ext.to_s.downcase.freeze }.freeze,
          content_type: definition["content_type"]&.to_s&.freeze,
          max: definition["max"]&.to_i,
          required_by_default: definition.fetch("required_by_default", false) == true,
          waivable: definition["waiver_label"]&.to_s&.freeze,
          portal_role: definition["portal_role"]&.to_s&.freeze,
          provides: Array(definition["provides"]).map { |field| field.to_s.freeze }.freeze
        )
      end

      portal_raw = raw["portal"].to_h
      role_map = portal_raw["role_map"].to_h.transform_keys(&:to_s).transform_values(&:to_s)
      if role_map.empty?
        files.each do |slot|
          role_map[slot.portal_role] = slot.role if slot.portal_role.present?
        end
      end

      new(
        key: raw.fetch("key"),
        label: raw.fetch("label", raw.fetch("key").to_s.humanize),
        source_label: raw["source_label"] || raw.fetch("label", raw.fetch("key").to_s.humanize),
        parser_version: raw.fetch("parser_version"),
        adapter_class: adapter_class,
        extraction: raw.fetch("extraction"),
        accepts_pasted_text: raw.fetch("accepts_pasted_text", false) == true,
        employee_match: raw["employee_match"] || raw.dig("revel_hours", "employee_match") || "name_fuzzy",
        idempotency: raw.fetch("idempotency"),
        reports_overtime: raw.dig("pay_period", "source_reports_overtime") == true,
        tips_default: raw["tips_default"] || "paid_in_check",
        overtime_mode: raw["overtime_mode"] || (raw.dig("pay_period", "source_reports_overtime") ? "source_reports" : "weekly_split"),
        files: files,
        portal: {
          "submittable" => portal_raw.fetch("submittable", role_map.any?) == true,
          "role_map" => role_map.freeze
        }.freeze,
        config_path: resolved_path.to_s,
        raw_config: raw.deep_dup.freeze
      )
    end

    def initialize(key:, label:, parser_version:, adapter_class:, extraction:, idempotency:,
                   source_label: label, accepts_pasted_text: false, employee_match: "name_fuzzy",
                   reports_overtime: false, tips_default: "paid_in_check", overtime_mode: "weekly_split",
                   files: [], portal: {}, config_path: nil, raw_config: nil)
      @key = key.to_s.freeze
      @label = label.to_s.freeze
      @source_label = source_label.to_s.freeze
      @parser_version = parser_version.to_s.freeze
      @adapter_class = adapter_class
      @extraction = extraction.to_s.freeze
      @accepts_pasted_text = accepts_pasted_text == true
      @employee_match = employee_match.to_s.freeze
      @idempotency = idempotency.to_s.freeze
      @reports_overtime = reports_overtime == true
      @tips_default = tips_default.to_s.freeze
      @overtime_mode = overtime_mode.to_s.freeze
      @files = Array(files).map { |slot| coerce_file_slot(slot) }.freeze
      portal_hash = portal.to_h.stringify_keys
      role_map = portal_hash.fetch("role_map", {}).to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
      @portal = {
        "submittable" => portal_hash.fetch("submittable", false) == true,
        "role_map" => role_map
      }.freeze
      @config_path = config_path&.to_s&.freeze
      @raw_config = raw_config
      @source_roles = @files.each_with_object({}) { |slot, acc| acc[slot.role] = slot.to_source_role_definition }.freeze
      @default_required_source_roles = @files.select(&:required_by_default).map(&:role).freeze
      freeze
    end

    def source_roles
      @source_roles
    end

    def default_required_source_roles
      @default_required_source_roles
    end

    def source_role_for(filename:, content_type: nil)
      slot = files.find { |candidate| candidate.matches?(filename: filename, content_type: content_type) }
      slot ? slot.role : "supporting_document"
    end

    def reports_overtime?
      @reports_overtime
    end

    def deterministic?
      extraction == "deterministic"
    end

    def accepts_pasted_text?
      @accepts_pasted_text
    end

    def portal_submittable?
      portal.fetch("submittable")
    end

    def portal_role_map
      portal.fetch("role_map")
    end

    def serialize(required_sources: nil)
      effective_required = required_sources.nil? ? default_required_source_roles : Array(required_sources).map(&:to_s)
      {
        "key" => key,
        "label" => label,
        "source_label" => source_label,
        "parser_version" => parser_version,
        "extraction" => extraction,
        "accepts_pasted_text" => accepts_pasted_text?,
        "employee_match" => employee_match,
        "idempotency" => idempotency,
        "reports_overtime" => reports_overtime?,
        "tips_default" => tips_default,
        "overtime_mode" => overtime_mode,
        "required_sources" => effective_required,
        "files" => files.map { |slot| slot.serialize(required: effective_required.include?(slot.role)) },
        "portal" => {
          "submittable" => portal_submittable?,
          "role_map" => portal_role_map
        }
      }
    end

    private

    def coerce_file_slot(slot)
      return slot if slot.is_a?(FileSlot)

      hash = slot.to_h.symbolize_keys
      FileSlot.new(
        role: hash.fetch(:role).to_s.freeze,
        label: hash.fetch(:label, hash.fetch(:role).to_s.humanize).to_s.freeze,
        accept: Array(hash[:accept] || hash[:extensions]).map { |ext| ext.to_s.downcase.freeze }.freeze,
        content_type: hash[:content_type]&.to_s&.freeze,
        max: hash[:max]&.to_i,
        required_by_default: hash.fetch(:required_by_default, false) == true,
        waivable: (hash[:waivable] || hash[:waiver_label])&.to_s&.freeze,
        portal_role: hash[:portal_role]&.to_s&.freeze,
        provides: Array(hash[:provides]).map { |field| field.to_s.freeze }.freeze
      )
    end
  end
end
