# frozen_string_literal: true

# Rake parses options before loading tasks. Translate only this release task's
# explicit flags; preserve Rake's normal --dry-run semantics for every other task.
module FicaLegacyRakeOptions
  TASK = "payroll:fica_legacy:recover"

  def self.configure!(arguments)
    return unless arguments.include?(TASK)
    flags = arguments & %w[--apply --dry-run]
    raise ArgumentError, "Choose --dry-run or --apply, not both" if flags.size > 1
    arguments.reject! { |argument| flags.include?(argument) }
    mode = flags.include?("--apply") ? "apply" : "dry-run"
    arguments[arguments.index(TASK)] = "#{TASK}[#{mode}]"
  end
end
