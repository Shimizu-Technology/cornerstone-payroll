# frozen_string_literal: true

FactoryBot.define do
  factory :invoice_chat_message do
    invoice_chat_session
    role { "user" }
    content { "Create an invoice for payroll services." }
    preview { {} }
    has_preview { false }
  end
end
