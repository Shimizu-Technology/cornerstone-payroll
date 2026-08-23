# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::PayloadValidator do
  let(:fetch_start) { Date.new(2026, 5, 18) }
  let(:fetch_end) { Date.new(2026, 5, 24) }
  let(:payload) do
    {
      "schema_version" => "1.0",
      "source" => "aire_services",
      "start_date" => fetch_start.iso8601,
      "end_date" => fetch_end.iso8601,
      "employees" => [
        {
          "source_user_id" => "worker-1",
          "days" => [
            {
              "work_date" => "2026-05-18",
              "hours" => 10,
              "total_hours" => 10,
              "regular_hours" => 8,
              "overtime_hours" => 2,
              "categories" => [
                {
                  "source_category_id" => "flight",
                  "hours" => 6,
                  "total_hours" => 6,
                  "regular_hours" => 5,
                  "overtime_hours" => 1
                },
                {
                  "source_category_id" => "ground",
                  "hours" => 4,
                  "total_hours" => 4,
                  "regular_hours" => 3,
                  "overtime_hours" => 1
                }
              ]
            }
          ],
          "total_hours" => 10,
          "regular_hours" => 8,
          "overtime_hours" => 2
        }
      ],
      "summary" => {
        "countable_hours" => 10,
        "regular_hours" => 8,
        "overtime_hours" => 2
      }
    }
  end

  def validate!(candidate = payload)
    described_class.new(
      payload: candidate,
      fetch_start_date: fetch_start,
      fetch_end_date: fetch_end
    ).validate!
  end

  it "accepts a fully reconciled v1 payload" do
    expect(validate!).to equal(payload)
  end

  it "treats an omitted schema version as legacy v1 compatibility" do
    payload.delete("schema_version")

    expect(validate!).to equal(payload)
  end

  it "rejects unsupported schema versions" do
    payload["schema_version"] = "2.0"

    expect { validate! }.to raise_error(described_class::Error, /Unsupported time-summary schema_version/)
  end

  it "rejects duplicate source users" do
    payload["employees"] << Marshal.load(Marshal.dump(payload["employees"].first))

    expect { validate! }.to raise_error(described_class::Error, /duplicate source_user_id worker-1/)
  end

  it "rejects duplicate work dates for one source user" do
    payload["employees"].first["days"] << Marshal.load(Marshal.dump(payload["employees"].first["days"].first))

    expect { validate! }.to raise_error(described_class::Error, /duplicate work_date 2026-05-18/)
  end

  it "rejects duplicate normalized category identities on one day" do
    duplicate = Marshal.load(Marshal.dump(payload.dig("employees", 0, "days", 0, "categories", 0)))
    duplicate["source_category_id"] = "FLIGHT!"
    payload.dig("employees", 0, "days", 0, "categories") << duplicate

    expect { validate! }.to raise_error(described_class::Error, /duplicate category flight/)
  end

  it "rejects categories without a stable identity" do
    category = payload.dig("employees", 0, "days", 0, "categories", 0)
    category.delete("source_category_id")

    expect { validate! }.to raise_error(described_class::Error, /category identity is required/)
  end

  it "rejects work dates outside the requested export range" do
    payload.dig("employees", 0, "days", 0)["work_date"] = "2026-05-25"

    expect { validate! }.to raise_error(described_class::Error, /outside the requested export range/)
  end

  it "rejects day and category totals that do not reconcile" do
    payload.dig("employees", 0, "days", 0, "categories", 1)["total_hours"] = 5
    payload.dig("employees", 0, "days", 0, "categories", 1)["hours"] = 5
    payload.dig("employees", 0, "days", 0, "categories", 1)["regular_hours"] = 4

    expect { validate! }.to raise_error(described_class::Error, /category totals do not equal day hours/)
  end

  it "rejects category totals that do not equal regular plus overtime" do
    payload.dig("employees", 0, "days", 0, "categories", 0)["overtime_hours"] = 2

    expect { validate! }.to raise_error(described_class::Error, /regular_hours plus overtime_hours does not equal total hours/)
  end

  it "requires regular and overtime values to be supplied together" do
    payload.dig("employees", 0, "days", 0, "categories", 0).delete("overtime_hours")

    expect { validate! }.to raise_error(described_class::Error, /must provide regular_hours and overtime_hours together/)
  end

  it "rejects partial category split evidence when the day supplies a split" do
    payload.dig("employees", 0, "days", 0, "categories", 1).except!("regular_hours", "overtime_hours")

    expect { validate! }.to raise_error(described_class::Error, /categories must all provide regular\/overtime splits/)
  end

  it "rejects partial day split evidence when the employee supplies a split" do
    second_day = {
      "work_date" => "2026-05-19",
      "hours" => 2,
      "categories" => [ { "source_category_id" => "flight", "hours" => 2 } ]
    }
    payload.dig("employees", 0, "days") << second_day
    payload.dig("employees", 0)["total_hours"] = 12
    payload.dig("employees", 0)["regular_hours"] = 10

    expect { validate! }.to raise_error(described_class::Error, /days must all provide regular\/overtime splits/)
  end

  it "does not treat a false categories value as an omitted list" do
    payload.dig("employees", 0, "days", 0)["categories"] = false

    expect { validate! }.to raise_error(described_class::Error, /categories must be an array/)
  end

  it "rejects employee totals that do not equal day totals" do
    payload.dig("employees", 0)["total_hours"] = 11

    expect { validate! }.to raise_error(described_class::Error, /total_hours does not equal the sum of day hours/)
  end

  it "rejects negative, nonnumeric, and non-finite hour values" do
    [ -1, "not-a-number", "NaN", "Infinity" ].each do |invalid|
      candidate = Marshal.load(Marshal.dump(payload))
      candidate.dig("employees", 0, "days", 0)["hours"] = invalid

      expect { validate!(candidate) }.to raise_error(described_class::Error, /finite non-negative number/)
    end
  end

  it "rejects more than 24 hours on one work date" do
    day = payload.dig("employees", 0, "days", 0)
    day["hours"] = day["total_hours"] = 25

    expect { validate! }.to raise_error(described_class::Error, /cannot exceed 24/)
  end

  it "accepts the simpler Cornerstone Tax category shape" do
    tax_payload = {
      "source" => "cornerstone_tax",
      "start_date" => fetch_start.iso8601,
      "end_date" => fetch_end.iso8601,
      "employees" => [
        {
          "source_user_id" => "tax-1",
          "days" => [
            {
              "work_date" => "2026-05-18",
              "hours" => 5,
              "categories" => [ { "source_category_id" => "tax", "name" => "Tax", "hours" => 5 } ]
            }
          ],
          "total_hours" => 5
        }
      ],
      "summary" => { "countable_hours" => 5 }
    }

    expect(validate!(tax_payload)).to equal(tax_payload)
  end
end
