# frozen_string_literal: true

require "json"
require "bigdecimal"
require "date"

module LocalCertification
  # These two drills intentionally contain one worker/category and only current
  # source lines. Reject a changed fixture instead of silently mapping every kind.
  module FinalizedWageMapping
    module_function

    def build(import:, source_user_id:, source_user_uuid:, employee_id:, wage_rate_id:,
              category_id:, category_key:, category_name:, regular_hours:, overtime_hours:)
      raise ArgumentError, "Expected the verified schema2 preview" unless import.fetch("status") == "previewed" &&
        import.fetch("contract_version") == "2.0" && import.fetch("external_batch_checksum").match?(/\A[0-9a-f]{64}\z/)

      processed = import.fetch("processed_payload")
      raise ArgumentError, "Expected finalized batch validation" unless processed.fetch("validation_version") == "payroll_batch_v2"

      rows = processed.fetch("rows")
      raise ArgumentError, "Certification fixture must retain exactly one source worker" unless rows.one?

      row = rows.first
      raise ArgumentError, "Retained worker identity differs from the fixture" unless row.fetch("source_user_id").to_s == source_user_id.to_s &&
        row.fetch("source_user_uuid") == source_user_uuid && row.fetch("employee_id") == employee_id

      categories = row.fetch("categories")
      raise ArgumentError, "Certification fixture must retain exactly one earning category" unless categories.one?

      category = categories.first
      raise ArgumentError, "Retained earning category differs from the fixture" unless category.fetch("source_category_id").to_s == category_id.to_s &&
        category.fetch("key") == category_key && category.fetch("name") == category_name
      kinds = category.fetch("source_kinds")
      raise ArgumentError, "Certification fixture must retain only current source work" unless kinds == [ "current" ]
      raise ArgumentError, "Retained wage-rate mapping differs from the fixture" unless category.fetch("employee_wage_rate_id") == wage_rate_id &&
        category.fetch("payroll_rate_cents") == 2500

      lines = category.fetch("source_lines")
      raise ArgumentError, "Retained source-line proof is missing" if lines.empty?

      identities = lines.map do |line|
        raise ArgumentError, "Retained source-line kind differs from its bucket" unless line.fetch("source_kind") == kinds.first
        raise ArgumentError, "Retained source-line identity is missing" if line.fetch("source_time_entry_id").to_s.empty? || line.fetch("line_key").empty?

        Date.iso8601(line.fetch("original_work_date"))
        # Versions are optional in the schema2 contract; never fabricate one for
        # the independent producer or overwrite a version supplied by AIRE.
        if line["source_time_entry_version"] && !line["source_time_entry_version"].to_s.match?(/\A(?:0|[1-9][0-9]*)\z/)
          raise ArgumentError, "Retained source-line version is invalid"
        end
        [ line.fetch("source_time_entry_id").to_s, line.fetch("line_key") ]
      end
      raise ArgumentError, "Duplicate retained source-line identity" unless identities.uniq == identities

      { "regular_hours" => regular_hours, "overtime_hours" => overtime_hours,
        "total_hours" => decimal(regular_hours) + decimal(overtime_hours) }.each do |field, expected|
        actual = lines.sum { |line| decimal(line.fetch(field)) }
        raise ArgumentError, "Retained #{field} differs from the independent fixture oracle" unless actual == decimal(expected) &&
          decimal(row.fetch(field)) == actual && decimal(category.fetch(field)) == actual
      end
      raise ArgumentError, "Unexpected signed source work in the current-only fixture" if lines.any? do |line|
        %w[regular_hours overtime_hours total_hours].any? { |field| decimal(line.fetch(field)).negative? }
      end

      {
        source_user_id: row.fetch("source_user_id"), employee_id: row.fetch("employee_id"), include: true,
        wage_rate_mappings: [ {
          source_category_id: category.fetch("source_category_id"), source_category_key: category.fetch("key"),
          source_category_name: category.fetch("name"), source_kind: kinds.first,
          employee_wage_rate_id: category.fetch("employee_wage_rate_id")
        } ]
      }
    end

    def decimal(value)
      number = BigDecimal(value.to_s)
      raise ArgumentError, "Nonfinite fixture hours" unless number.finite?

      number
    end
    private_class_method :decimal
  end
end

if $PROGRAM_NAME == __FILE__
  preview, aire, payroll, output, regular, overtime = ARGV
  raise ArgumentError, "Expected preview, two fixtures, output and independent REG/OT hours" unless ARGV.length == 6

  import = JSON.parse(File.read(preview)).fetch("import")
  source = JSON.parse(File.read(aire))
  target = JSON.parse(File.read(payroll))
  mapping = LocalCertification::FinalizedWageMapping.build(import: import,
    source_user_id: source.fetch("employee_id"), source_user_uuid: source.fetch("employee_uuid"),
    employee_id: target.fetch("employee_id"), wage_rate_id: target.fetch("employee_wage_rate_id"),
    category_id: source.fetch("category_id"), category_key: source.fetch("category_key"), category_name: source.fetch("category_name"),
    regular_hours: regular, overtime_hours: overtime)
  File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(import_id: import.fetch("id"), mappings: [ mapping ]))
  end
end
