class AddCheckMemoTemplateToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :check_memo_template, :string
  end
end
