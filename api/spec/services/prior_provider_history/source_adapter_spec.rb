# frozen_string_literal: true

require "rails_helper"

RSpec.describe PriorProviderHistory::SourceAdapter do
  it "keeps existing native run digests stable when the rollback review flag changes" do
    period = create(:pay_period)
    previous_shape = [ period.attributes.except("rollback_review_required"), [] ]
    previous_digest = Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize(previous_shape)))

    expect(described_class.digest(period)).to eq(previous_digest)
    period.update_columns(rollback_review_required: true)
    expect(described_class.digest(period.reload)).to eq(previous_digest)
  end
end
