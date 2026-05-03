# frozen_string_literal: true

FactoryBot.define do
  factory :invoice_chat_session do
    company
    title { "Invoice Assistant" }
    status { "active" }
    current_preview { {} }
    current_preview_version { 0 }
    archived { false }
    created_by { association(:user, company: company) }
    updated_by { created_by }
  end
end
