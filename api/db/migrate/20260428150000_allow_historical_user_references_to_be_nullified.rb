# frozen_string_literal: true

class AllowHistoricalUserReferencesToBeNullified < ActiveRecord::Migration[8.0]
  def change
    change_column_null :client_documents, :uploaded_by_id, true
    change_column_null :employee_change_requests, :requested_by_id, true
    change_column_null :user_invitations, :invited_by_id, true
  end
end
