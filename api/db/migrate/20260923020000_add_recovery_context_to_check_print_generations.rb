# frozen_string_literal: true

class AddRecoveryContextToCheckPrintGenerations < ActiveRecord::Migration[8.1]
  def change
    add_column :check_print_generations, :request_ip, :string
    add_column :check_print_generations, :worker_job_id, :string
  end
end
