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
      :hint,
      :accept,
      :content_type,
      :max,
      :required_by_default,
      :waivable,
      :portal_role,
      :portal_label,
      :portal_hint,
      :supports_link,
      :template_formats,
      :provides
    ) do
      def matches?(filename:, content_type: nil)
        return true if self.content_type.present? && content_type.to_s == self.content_type

        extension = File.extname(filename.to_s).downcase
        extension.present? && accept.include?(extension)
      end

      def to_source_role_definition
        definition = { label: label, accept: accept }
        definition[:waiver_label] = waivable if waivable.present?
        definition.freeze
      end

      def serialize(required: required_by_default)
        {
          "role" => role,
          "label" => label,
          "hint" => hint,
          "accept" => accept,
          "content_type" => content_type,
          "max" => max,
          "required" => required,
          "required_by_default" => required_by_default,
          "waivable" => waivable,
          "portal_role" => portal_role,
          "portal_label" => portal_label || label,
          "portal_hint" => portal_hint || hint,
          "supports_link" => supports_link == true,
          "template_formats" => Array(template_formats),
          "provides" => provides
        }
      end
    end

    attr_reader :key, :label, :source_label, :parser_version, :adapter_class,
                :extraction, :employee_match, :idempotency, :files, :portal,
                :tips_default, :overtime_mode, :workweek_alignment,
                :config_path, :raw_config

    def self.from_yaml(path, adapter_class:)
      resolved_path = Pathname.new(path)
      raw = YAML.safe_load_file(resolved_path)
      raise ArgumentError, "Intake descriptor #{resolved_path} must be a YAML mapping" unless raw.is_a?(Hash)

      files = (raw["files"] || {}).map do |role, definition|
        definition = definition.to_h
        FileSlot.new(
          role: role.to_s.freeze,
          label: definition.fetch("label", role.to_s.humanize).to_s.freeze,
          hint: definition["hint"]&.to_s&.freeze,
          accept: Array(definition["extensions"]).map { |ext| ext.to_s.downcase.freeze }.freeze,
          content_type: definition["content_type"]&.to_s&.freeze,
          max: definition["max"]&.to_i,
          required_by_default: definition.fetch("required_by_default", false) == true,
          waivable: definition["waiver_label"]&.to_s&.freeze,
          portal_role: definition["portal_role"]&.to_s&.freeze,
          portal_label: definition["portal_label"]&.to_s&.freeze,
          portal_hint: definition["portal_hint"]&.to_s&.freeze,
          supports_link: definition.fetch("supports_link", false) == true,
          template_formats: Array(definition["template_formats"]).map { |fmt| fmt.to_s.downcase.freeze }.freeze,
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

      reports_ot = raw.dig("pay_period", "source_reports_overtime") == true
      new(
        key: raw.fetch("key"),
        label: raw.fetch("label", raw.fetch("key").to_s.humanize),
        source_label: raw["source_label"] || raw.fetch("label", raw.fetch("key").to_s.humanize),
        parser_version: raw.fetch("parser_version"),
        adapter_class: adapter_class,
        extraction: raw.fetch("extraction"),
        accepts_pasted_text: raw.fetch("accepts_pasted_text", false) == true,
        tracks_reviewed_hours: raw.fetch("tracks_reviewed_hours", false) == true,
        employee_match: raw["employee_match"] || raw.dig("revel_hours", "employee_match") || "name_fuzzy",
        idempotency: raw.fetch("idempotency"),
        reports_overtime: reports_ot,
        tips_default: raw["tips_default"] || "paid_in_check",
        overtime_mode: raw["overtime_mode"] || (reports_ot ? "source_reports" : "weekly_split"),
        workweek_alignment: raw["workweek_alignment"] || (reports_ot ? "warn_if_offset" : "aligned"),
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
                   source_label: label, accepts_pasted_text: false, tracks_reviewed_hours: false,
                   employee_match: "name_fuzzy", reports_overtime: false,
                   tips_default: "paid_in_check", overtime_mode: "weekly_split",
                   workweek_alignment: nil, files: [], portal: {}, config_path: nil, raw_config: nil)
      @key = key.to_s.freeze
      @label = label.to_s.freeze
      @source_label = source_label.to_s.freeze
      @parser_version = parser_version.to_s.freeze
      @adapter_class = adapter_class
      @extraction = extraction.to_s.freeze
      @accepts_pasted_text = accepts_pasted_text == true
      @tracks_reviewed_hours = tracks_reviewed_hours == true
      @employee_match = employee_match.to_s.freeze
      @idempotency = idempotency.to_s.freeze
      @reports_overtime = reports_overtime == true
      @tips_default = tips_default.to_s.freeze
      @overtime_mode = overtime_mode.to_s.freeze
      @workweek_alignment = (workweek_alignment.presence || (@reports_overtime ? "warn_if_offset" : "aligned")).to_s.freeze
      @files = Array(files).map { |slot| coerce_file_slot(slot) }.freeze
      if @files.count(&:supports_link) > 1
        raise ArgumentError, "Payroll intake descriptor '#{@key}' cannot define more than one supports_link file slot"
      end
      portal_hash = portal.to_h.stringify_keys
      role_map = portal_hash.fetch("role_map", {}).to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
      if role_map.empty?
        derived = @files.each_with_object({}) { |slot, acc| acc[slot.portal_role] = slot.role if slot.portal_role.present? }
        role_map = derived.freeze
      end
      portal_roles_to_check = (role_map.keys + @files.filter_map(&:portal_role)).uniq
      invalid_portal_roles = portal_roles_to_check.reject { |role| role.match?(/\A[a-z][a-z0-9_]{0,63}\z/) }
      if invalid_portal_roles.any?
        raise ArgumentError, "Payroll intake descriptor '#{@key}' has invalid portal roles: #{invalid_portal_roles.join(', ')}"
      end
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

    def file_slot(role)
      files.find { |slot| slot.role == role.to_s }
    end

    def file_slot_for_portal_role(portal_role)
      source_role = portal_role_map[portal_role.to_s]
      return file_slot(source_role) if source_role.present?

      files.find { |slot| slot.portal_role == portal_role.to_s }
    end

    def portal_role_for(source_role)
      portal_role_map.key(source_role.to_s) || file_slot(source_role)&.portal_role
    end

    def portal_roles
      portal_role_map.keys
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

    def tracks_reviewed_hours?
      @tracks_reviewed_hours
    end

    def portal_submittable?
      portal.fetch("submittable")
    end

    def portal_role_map
      portal.fetch("role_map")
    end

    CLIENT_OMITTED_KEYS = %w[parser_version idempotency].freeze

    def serialize(required_sources: nil, tips_default: nil, overtime_mode: nil, workweek_alignment: nil, audience: :staff)
      effective_required = required_sources.nil? ? default_required_source_roles : Array(required_sources).map(&:to_s)
      payload = {
        "key" => key,
        "label" => label,
        "source_label" => source_label,
        "parser_version" => parser_version,
        "extraction" => extraction,
        "accepts_pasted_text" => accepts_pasted_text?,
        "tracks_reviewed_hours" => tracks_reviewed_hours?,
        "employee_match" => employee_match,
        "idempotency" => idempotency,
        "reports_overtime" => reports_overtime?,
        "tips_default" => (tips_default || self.tips_default).to_s,
        "overtime_mode" => (overtime_mode || self.overtime_mode).to_s,
        "workweek_alignment" => (workweek_alignment || self.workweek_alignment).to_s,
        "required_sources" => effective_required,
        "files" => files.map { |slot| slot.serialize(required: effective_required.include?(slot.role)) },
        "portal" => {
          "submittable" => portal_submittable?,
          "role_map" => portal_role_map
        }
      }
      audience.to_sym == :client ? payload.except(*CLIENT_OMITTED_KEYS) : payload
    end

    private

    def coerce_file_slot(slot)
      return slot if slot.is_a?(FileSlot)

      hash = slot.to_h.symbolize_keys
      FileSlot.new(
        role: hash.fetch(:role).to_s.freeze,
        label: hash.fetch(:label, hash.fetch(:role).to_s.humanize).to_s.freeze,
        hint: hash[:hint]&.to_s&.freeze,
        accept: Array(hash[:accept] || hash[:extensions]).map { |ext| ext.to_s.downcase.freeze }.freeze,
        content_type: hash[:content_type]&.to_s&.freeze,
        max: hash[:max]&.to_i,
        required_by_default: hash.fetch(:required_by_default, false) == true,
        waivable: (hash[:waivable] || hash[:waiver_label])&.to_s&.freeze,
        portal_role: hash[:portal_role]&.to_s&.freeze,
        portal_label: hash[:portal_label]&.to_s&.freeze,
        portal_hint: hash[:portal_hint]&.to_s&.freeze,
        supports_link: hash.fetch(:supports_link, false) == true,
        template_formats: Array(hash[:template_formats]).map { |fmt| fmt.to_s.downcase.freeze }.freeze,
        provides: Array(hash[:provides]).map { |field| field.to_s.freeze }.freeze
      )
    end
  end
end
