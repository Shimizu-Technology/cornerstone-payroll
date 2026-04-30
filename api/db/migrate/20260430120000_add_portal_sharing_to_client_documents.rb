# frozen_string_literal: true

class AddPortalSharingToClientDocuments < ActiveRecord::Migration[8.0]
  def change
    add_column :client_documents, :visible_to_client, :boolean, default: true, null: false
    add_column :client_documents, :shared_by_staff, :boolean, default: false, null: false

    add_index :client_documents, [ :company_id, :visible_to_client ], name: "index_client_documents_on_company_and_client_visibility"
  end
end
