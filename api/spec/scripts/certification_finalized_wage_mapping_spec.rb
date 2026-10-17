# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Finalized certification wage mapping contract" do
  it "executes the driver contract's independent negative cases under the pinned Ruby" do
    path = File.expand_path("../../../scripts/local_certification/test_finalized_wage_mapping.rb", __dir__)
    output, error, status = Open3.capture3(RbConfig.ruby, path)
    expect(status.success?).to be(true), "#{output}\n#{error}"
    expect(output).to include("8 runs", "0 failures", "0 errors")
  end
end
