# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceChatMessage, type: :model do
  describe "preview normalization" do
    it "marks only invoice previews as preview-bearing messages" do
      preview_message = build(
        :invoice_chat_message,
        role: "assistant",
        preview: { "status" => "preview" },
        has_preview: false
      )
      clarification_message = build(
        :invoice_chat_message,
        role: "assistant",
        preview: { "status" => "clarification_needed" },
        has_preview: true
      )

      preview_message.valid?
      clarification_message.valid?

      expect(preview_message.has_preview).to be(true)
      expect(clarification_message.has_preview).to be(false)
    end
  end
end
