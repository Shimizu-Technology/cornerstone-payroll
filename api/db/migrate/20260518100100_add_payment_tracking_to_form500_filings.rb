class AddPaymentTrackingToForm500Filings < ActiveRecord::Migration[8.1]
  def change
    add_column :form500_filings, :status, :string, null: false, default: "prepared"
    add_column :form500_filings, :payment_date, :date
    add_column :form500_filings, :payment_amount, :decimal, precision: 12, scale: 2
    add_column :form500_filings, :confirmation_number, :string
    add_column :form500_filings, :receipt_attached, :boolean, null: false, default: false
    add_column :form500_filings, :notes, :text
    add_index :form500_filings, [ :company_id, :status ]
  end
end
