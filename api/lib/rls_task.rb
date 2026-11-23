# frozen_string_literal: true

module RlsTask
  def self.system(*definition, &action)
    Rake::Task.define_task(*definition) do |task, arguments|
      TenantScope.as_system(reason: task.name) { action.call(task, arguments) }
    end
  end
end
