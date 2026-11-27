# frozen_string_literal: true

module PayrollIntake
  # Resolves effective per-company intake settings (tips default, overtime mode,
  # workweek alignment, and required source roles) for a given company, date or
  # pay period, and adapter source_type.
  #
  # Resolution order (reproducing existing MoSa and Spike behavior by default):
  # 1. Effective persisted ClientOperatingProfile (on pay_period.end_date or `on`)
  #    when its intake_adapter explicitly matches source_type.
  # 2. Explicit per-source overrides in companies.payroll_intake_settings[source_type].
  # 3. Registered adapter descriptor defaults (mosa_revel: paid_in_check /
  #    source_reports / warn_if_offset; spike_email: already_paid_out /
  #    weekly_split / aligned).
  # 4. OperatingProfileCatalog defaults.
  class EffectiveSettings
    UNLOADED = Object.new.freeze

    Result = Data.define(
      :source_type,
      :tips_default,
      :overtime_mode,
      :workweek_alignment,
      :required_sources,
      :source
    ) do
      def tips_already_paid_default?
        tips_default == "already_paid_out"
      end

      def source_reports_overtime?
        overtime_mode == "source_reports"
      end

      # Per 29 CFR 778.104, misaligned pay periods are only permissible when
      # the source itself reports overtime. Computed overtime modes always
      # require complete, aligned 7-day legal workweeks.
      def allow_misaligned_workweek?
        source_reports_overtime?
      end

      def to_evidence
        {
          "source_type" => source_type,
          "tips_default" => tips_default,
          "overtime_mode" => overtime_mode,
          "workweek_alignment" => workweek_alignment,
          "required_sources" => required_sources,
          "source" => source
        }
      end
    end

    def self.preload_profiles(company_ids, on: nil)
      ids = Array(company_ids).compact.uniq
      return {} if ids.empty?

      as_of = (on || PayrollBusinessClock.today).to_date
      ClientOperatingProfile
        .active_on(as_of)
        .where(company_id: ids)
        .each_with_object({}) do |profile, acc|
          acc[profile.company_id] ||= profile
        end
    end

    def self.for(company:, source_type:, pay_period: nil, on: nil, preloaded_profile: UNLOADED)
      new(
        company: company,
        source_type: source_type,
        pay_period: pay_period,
        on: on,
        preloaded_profile: preloaded_profile
      ).resolve
    end

    def initialize(company:, source_type:, pay_period: nil, on: nil, preloaded_profile: UNLOADED)
      @company = company
      @source_type = source_type.to_s
      @as_of = (on || pay_period&.end_date || PayrollBusinessClock.today).to_date
      @preloaded_profile = preloaded_profile
    end

    def resolve
      descriptor = PayrollIntake::Registry.find(@source_type)
      features = resolved_features

      if use_operating_profile?(features)
        configured_required = features.option("intake.required_sources")
        required = configured_required.nil? ? @company.payroll_intake_required_sources(@source_type) : Array(configured_required).map(&:to_s)
        return Result.new(
          source_type: @source_type,
          tips_default: features.tips_default,
          overtime_mode: features.overtime_mode,
          workweek_alignment: features.workweek_alignment,
          required_sources: required,
          source: "operating_profile"
        )
      end

      per_source = @company.payroll_intake_settings.to_h[@source_type].to_h
      tips = per_source["tips_default"].presence ||
        descriptor&.tips_default ||
        OperatingProfileCatalog.default_for("tips.default")
      overtime = per_source["overtime_mode"].presence ||
        descriptor&.overtime_mode ||
        OperatingProfileCatalog.default_for("overtime.mode")
      alignment = per_source["workweek_alignment"].presence ||
        (overtime.to_s == "source_reports" ? (descriptor&.workweek_alignment || "warn_if_offset") : OperatingProfileCatalog.default_for("workweek.alignment"))
      has_company_override = per_source.slice("tips_default", "overtime_mode", "workweek_alignment").values.any?(&:present?)

      Result.new(
        source_type: @source_type,
        tips_default: tips.to_s,
        overtime_mode: overtime.to_s,
        workweek_alignment: alignment.to_s,
        required_sources: @company.payroll_intake_required_sources(@source_type),
        source: has_company_override ? "company_intake_settings" : "adapter_descriptor"
      )
    end

    private

    def resolved_features
      return CompanyFeatures.for(@company, on: @as_of) if @preloaded_profile.equal?(UNLOADED)
      return nil if @preloaded_profile.nil?

      CompanyFeatures.new(company: @company, profile: @preloaded_profile, as_of: @as_of)
    end

    def use_operating_profile?(features)
      return false unless features&.persisted?

      features.intake_adapter == @source_type
    end
  end
end
