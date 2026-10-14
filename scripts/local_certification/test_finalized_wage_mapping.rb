# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "finalized_wage_mapping"

class FinalizedWageMappingTest < Minitest::Test
  UUID = "00000000-0000-4000-8000-000000000001"

  def fixture(regular: 14, overtime: 0, version: 0)
    line = { "source_time_entry_id" => "5", "line_key" => "operations:2500", "source_kind" => "current",
      "original_work_date" => "2026-10-05", "regular_hours" => regular, "overtime_hours" => overtime,
      "total_hours" => regular + overtime }
    line["source_time_entry_version"] = version unless version.nil?
    category = { "source_category_id" => "1", "key" => "operations", "name" => "Operations",
      "source_kinds" => [ "current" ], "employee_wage_rate_id" => 7, "payroll_rate_cents" => 2500,
      "regular_hours" => regular, "overtime_hours" => overtime, "total_hours" => regular + overtime,
      "source_lines" => [ line ] }
    { "id" => 8, "status" => "previewed", "contract_version" => "2.0", "external_batch_checksum" => "a" * 64,
      "processed_payload" => { "validation_version" => "payroll_batch_v2", "rows" => [ {
        "source_user_id" => "2", "source_user_uuid" => UUID, "employee_id" => 3,
        "regular_hours" => regular, "overtime_hours" => overtime, "total_hours" => regular + overtime,
        "categories" => [ category ] } ] } }
  end

  def build(import, regular: 14, overtime: 0)
    LocalCertification::FinalizedWageMapping.build(import: import, source_user_id: 2, source_user_uuid: UUID,
      employee_id: 3, wage_rate_id: 7, category_id: 1, category_key: "operations", category_name: "Operations",
      regular_hours: regular, overtime_hours: overtime)
  end

  def category(import)
    import.fetch("processed_payload").fetch("rows").first.fetch("categories").first
  end

  def test_aire_current_schema2_mapping_preserves_recorded_version_zero_without_mutation
    import = fixture
    original = Marshal.dump(import)
    mapping = build(import)
    assert_equal({ source_category_id: "1", source_category_key: "operations", source_category_name: "Operations",
      source_kind: "current", employee_wage_rate_id: 7 }, mapping.fetch(:wage_rate_mappings).first)
    assert_equal original, Marshal.dump(import)
  end

  def test_neutral_weekly_oracle_without_optional_version_is_not_backfilled
    import = fixture(regular: 40, overtime: 5, version: nil)
    mapping = build(import, regular: 40, overtime: 5)
    assert_equal "current", mapping.fetch(:wage_rate_mappings).first.fetch(:source_kind)
    refute category(import).fetch("source_lines").first.key?("source_time_entry_version")
    refute mapping.fetch(:wage_rate_mappings).first.key?(:source_effective_rate_cents)
  end

  def test_missing_kind_is_rejected_instead_of_defaulting_current
    import = fixture
    category(import).delete("source_kinds")
    assert_raises(KeyError) { build(import) }
  end

  def test_mixed_or_changed_kind_fixture_is_rejected
    [ [ "current", "correction" ], [ "carryover" ], [ "correction" ] ].each do |kinds|
      import = fixture
      category(import)["source_kinds"] = kinds
      assert_raises(ArgumentError) { build(import) }
    end
    import = fixture
    category(import).fetch("source_lines").first["source_kind"] = "carryover"
    assert_raises(ArgumentError) { build(import) }
  end

  def test_recorded_worker_uuid_category_and_rate_cannot_be_substituted
    [ ->(x) { x.fetch("processed_payload").fetch("rows").first["source_user_uuid"] = "foreign" },
      ->(x) { category(x)["key"] = "foreign" }, ->(x) { category(x)["employee_wage_rate_id"] = 99 },
      ->(x) { category(x)["payroll_rate_cents"] = 9900 } ].each do |change|
      import = fixture
      change.call(import)
      assert_raises(ArgumentError) { build(import) }
    end
  end

  def test_component_hours_and_duplicate_lines_are_not_hidden_by_net_total
    import = fixture
    line = category(import).fetch("source_lines").first
    line["regular_hours"] = 15
    line["overtime_hours"] = -1
    assert_raises(ArgumentError) { build(import) }
    import = fixture
    category(import).fetch("source_lines") << category(import).fetch("source_lines").first.dup
    assert_raises(ArgumentError) { build(import) }
  end

  def test_changed_contract_or_unverified_checksum_cannot_create_mapping
    [ ->(x) { x["contract_version"] = "1.0" }, ->(x) { x["external_batch_checksum"] = "missing" },
      ->(x) { x.fetch("processed_payload")["validation_version"] = "unverified" } ].each do |change|
      import = fixture
      change.call(import)
      assert_raises(ArgumentError) { build(import) }
    end
  end

  def test_actual_cli_serializes_preview_kind_and_refuses_missing_proof_before_body_write
    Dir.mktmpdir("finalized-source-mapping.") do |directory|
      preview, aire, payroll, output = %w[preview aire payroll apply].map { |name| File.join(directory, "#{name}.json") }
      File.write(preview, JSON.generate(import: fixture))
      File.write(aire, JSON.generate(employee_id: 2, employee_uuid: UUID, category_id: 1, category_key: "operations", category_name: "Operations"))
      File.write(payroll, JSON.generate(employee_id: 3, employee_wage_rate_id: 7))
      command = [ RbConfig.ruby, File.expand_path("finalized_wage_mapping.rb", __dir__), preview, aire, payroll, output, "14", "0" ]
      _, error, status = Open3.capture3(*command)
      assert status.success?, error
      body = JSON.parse(File.read(output))
      assert_equal 8, body.fetch("import_id")
      assert_equal "current", body.fetch("mappings").first.fetch("wage_rate_mappings").first.fetch("source_kind")
      assert_equal 0o600, File.stat(output).mode & 0o777
      File.delete(output)
      invalid = fixture
      category(invalid).delete("source_kinds")
      File.write(preview, JSON.generate(import: invalid))
      _, _, status = Open3.capture3(*command)
      refute status.success?
      refute File.exist?(output)
    end
  end
end
