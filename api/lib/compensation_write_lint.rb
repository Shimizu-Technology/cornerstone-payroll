# frozen_string_literal: true

# Static check for the M3-4 single write path. Pay rates and wage rates are
# effective-dated, so employees.pay_rate, the employee_wage_rates columns and
# the two history tables change only through EmployeeCompensationChangeService.
# The model guards stop ActiveRecord saves; this check stops the writes that
# skip callbacks (update_columns, update_all, insert/upsert, raw SQL).
#
# Run with `bin/rails compensation:lint_writes`; CI runs it in backend-checks
# and spec/lint/compensation_write_path_spec.rb.
module CompensationWriteLint
  SCANNED_PATHS = %w[app lib config db/seeds.rb db/seeds].freeze
  # Files allowed to write these columns directly, each with its reason.
  ALLOWED_FILES = {
    "app/services/employee_compensation_change_service.rb" => "the write path itself",
    "lib/compensation_write_lint.rb" => "this check's own patterns"
  }.freeze

  BULK_WRITE = /\.(?:update_columns?|update_all|update_attribute|upsert_all|insert_all!?|upsert|insert!?)\b\s*\(?(?<args>[^)]*)/m
  RULES = [
    [
      "bulk or callback-skipping write naming pay_rate",
      ->(source) { source.to_enum(:scan, BULK_WRITE).map { Regexp.last_match }.select { |match| match[:args].match?(/\bpay_rate\b/) } }
    ],
    [
      "bulk or callback-skipping write on employee wage rates",
      ->(source) { source.to_enum(:scan, /\b(?:EmployeeWageRate|employee_wage_rates)\b[^\n]*?\.(?:update_columns?|update_all|upsert_all|insert_all!?|delete_all)\b/).map { Regexp.last_match } }
    ],
    [
      "bulk write on compensation history",
      ->(source) { source.to_enum(:scan, /\b(?:EmployeeCompensationChange|EmployeeWageRateVersion|employee_compensation_changes|employee_wage_rate_versions)\b[^\n]*?\.(?:update_columns?|update_all|upsert_all|insert_all!?|delete_all)\b/).map { Regexp.last_match } }
    ],
    [
      "raw SQL write on pay rates or compensation history",
      ->(source) { source.to_enum(:scan, /\b(?:UPDATE\s+employees\b[^;]*?\bpay_rate\b|UPDATE\s+employee_wage_rates\b|(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(?:employee_compensation_changes|employee_wage_rate_versions)\b)/im).map { Regexp.last_match } }
    ]
  ].freeze

  Offense = Struct.new(:path, :line, :rule, :excerpt, keyword_init: true) do
    def to_s
      "#{path}:#{line}: #{rule}: #{excerpt}"
    end
  end

  def self.offenses(root: Rails.root)
    root = Pathname(root)
    files(root).flat_map do |path|
      relative = path.relative_path_from(root).to_s
      next [] if ALLOWED_FILES.key?(relative)

      scan(path.read, relative)
    end
  end

  def self.scan(source, relative_path)
    code = strip_comments(source)
    RULES.flat_map do |rule, finder|
      finder.call(code).map do |match|
        line = code[0...match.begin(0)].count("\n") + 1
        Offense.new(path: relative_path, line: line, rule: rule, excerpt: source.lines[line - 1].to_s.strip)
      end
    end
  end

  def self.files(root)
    SCANNED_PATHS.flat_map do |entry|
      path = root.join(entry)
      if path.file?
        [ path ]
      elsif path.directory?
        Pathname.glob(path.join("**/*.{rb,rake,erb,yml,sql}"))
      else
        []
      end
    end.sort
  end

  # Blank out Ruby comment lines so documentation can name the columns, while
  # keeping line numbers stable.
  def self.strip_comments(source)
    source.lines.map { |line| line.lstrip.start_with?("#") ? "\n" : line }.join
  end
end
