# frozen_string_literal: true

class AddTextDigestToEmployeeTermsVersions < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_terms_versions, :text_digest, :string, limit: 64
  end
end
