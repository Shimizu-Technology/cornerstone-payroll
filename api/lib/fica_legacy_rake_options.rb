# frozen_string_literal: true

# Rake parses options before loading tasks. Translate only this release task's
# explicit flags; preserve Rake's normal --dry-run semantics for every other task.
module FicaLegacyRakeOptions
  TASKS = %w[payroll:fica_legacy:recover payroll:fica_legacy:reconcile_imports].freeze

  def self.configure!(arguments)
    selected = TASKS & arguments
    return if selected.empty?
    flags = arguments & %w[--apply --dry-run]
    raise ArgumentError, "Choose --dry-run or --apply, not both" if flags.size > 1
    arguments.reject! { |argument| flags.include?(argument) }
    mode = flags.include?("--apply") ? "apply" : "dry-run"
    selected.each { |task| arguments[arguments.index(task)] = "#{task}[#{mode}]" }
  end
end
