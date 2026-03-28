class AddInvitationFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :invitation_status, :string, default: "accepted", null: false
    add_column :users, :invited_at, :datetime
    add_column :users, :invited_by_id, :bigint
    add_column :users, :clerk_invitation_id, :string

    add_foreign_key :users, :users, column: :invited_by_id, on_delete: :nullify
  end
end
