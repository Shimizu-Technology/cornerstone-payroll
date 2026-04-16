class CreateCheckSignoffSheets < ActiveRecord::Migration[8.0]
  def change
    create_table :check_signoff_sheets do |t|
      t.references :pay_period, null: false, foreign_key: true, index: { unique: true }
      t.references :company, null: false, foreign_key: true
      t.jsonb :entries, default: []
      t.jsonb :notes, default: []
      t.references :updated_by, foreign_key: { to_table: :users }, null: true
      t.datetime :generated_at
      t.timestamps
    end
  end
end
