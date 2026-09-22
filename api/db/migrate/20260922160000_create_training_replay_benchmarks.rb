# frozen_string_literal: true

class CreateTrainingReplayBenchmarks < ActiveRecord::Migration[8.0]
  def change
    create_table :training_replay_benchmarks do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :source_company, null: false, foreign_key: { to_table: :companies, on_delete: :restrict }
      t.references :source_pay_period, null: false, foreign_key: { to_table: :pay_periods, on_delete: :restrict }
      t.references :captured_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :source_status, null: false
      t.jsonb :snapshot, null: false, default: {}
      t.string :sha256, null: false
      t.datetime :captured_at, null: false
      t.timestamps
    end

    add_index :training_replay_benchmarks,
              [ :company_id, :source_pay_period_id ],
              unique: true,
              name: "idx_training_benchmarks_company_source"
    add_check_constraint :training_replay_benchmarks,
                         "source_status IN ('calculated', 'approved', 'committed')",
                         name: "training_replay_benchmarks_source_status_check"
  end
end
