class CreateTimecards < ActiveRecord::Migration[8.1]
  def change
    create_table :timecards do |t|
      t.string :employee_name
      t.references :company, null: false, foreign_key: true
      t.references :pay_period, foreign_key: true
      t.text :image_url
      t.text :preprocessed_image_url
      t.string :image_hash
      t.integer :ocr_status, default: 0, null: false
      t.float :overall_confidence
      t.date :period_start
      t.date :period_end
      t.jsonb :raw_ocr_response
      t.string :reviewed_by_name
      t.datetime :reviewed_at

      t.timestamps
    end
    add_index :timecards, [:company_id, :image_hash], unique: true, where: "image_hash IS NOT NULL"

    create_table :punch_entries do |t|
      t.references :timecard, null: false, foreign_key: true
      t.integer :card_day
      t.date :date
      t.string :day_of_week, limit: 3
      t.time :clock_in
      t.time :lunch_out
      t.time :lunch_in
      t.time :clock_out
      t.time :in3
      t.time :out3
      t.float :hours_worked
      t.float :confidence
      t.text :notes
      t.boolean :manually_edited, default: false
      t.integer :review_state, default: 0, null: false
      t.string :reviewed_by_name
      t.datetime :reviewed_at

      t.timestamps
    end
  end
end
