# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeDocumentNotice do
  it "keeps a paper task open through the due date and then marks it overdue" do
    due_on = Date.new(2027, 2, 15)
    notice = described_class.new(paper_due_on: due_on)
    expect(notice.paper_follow_up_state(today: due_on)).to eq("required")
    expect(notice.paper_follow_up_state(today: due_on + 1)).to eq("overdue")
    notice.paper_mailed_on = due_on + 1
    expect(notice.paper_follow_up_state(today: due_on + 2)).to eq("mailed")
  end
end
