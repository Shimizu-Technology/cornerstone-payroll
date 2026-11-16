# frozen_string_literal: true

class AddEntryResolutionProvenance < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_entry_resolutions, :source_evidence, :jsonb, null: false, default: {}
    remove_check_constraint :payroll_submissions,
      "NOT no_changes OR jsonb_array_length(jsonb_path_query_array(change_rows, '$[*] ? (@.skipped == true)')) = jsonb_array_length(change_rows)",
      name: "payroll_submissions_no_changes_is_empty"
    add_check_constraint :payroll_submissions,
      "NOT no_changes OR jsonb_array_length(jsonb_path_query_array(change_rows, '$[*] ? (@.skipped == true || exists(@.standing_change_id))')) = jsonb_array_length(change_rows)",
      name: "payroll_submissions_no_changes_is_empty"
  end
end
