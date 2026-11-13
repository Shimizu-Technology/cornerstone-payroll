# frozen_string_literal: true

require "rails_helper"

RSpec.describe TestWorkspaceSafetyPolicy do
  %w[aire_payroll_cockpits aire_manual_allocations time_tracking_calendars time_tracking_sources].each do |controller|
    it "allows local read views and blocks writes for #{controller}" do
      %w[GET HEAD POST PATCH DELETE].each do |method|
        expect(described_class.blocked?(controller_path: "api/v1/admin/#{controller}",
          action_name: "review", request_method: method)).to eq(!method.in?(%w[GET HEAD]))
      end
    end
  end
end
