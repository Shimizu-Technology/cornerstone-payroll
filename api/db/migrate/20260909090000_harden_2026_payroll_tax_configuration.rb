class Harden2026PayrollTaxConfiguration < ActiveRecord::Migration[8.1]
  # FICA: https://www.irs.gov/publications/p15
  # Withholding: https://www.irs.gov/publications/p15t
  WITHHOLDING = {
    "single" => {
      adjustment: 8_600,
      brackets: [
        [ 0, 7_500, 0.00 ], [ 7_500, 19_900, 0.10 ], [ 19_900, 57_900, 0.12 ],
        [ 57_900, 113_200, 0.22 ], [ 113_200, 209_275, 0.24 ], [ 209_275, 263_725, 0.32 ],
        [ 263_725, 648_100, 0.35 ], [ 648_100, nil, 0.37 ]
      ]
    },
    "married" => {
      adjustment: 12_900,
      brackets: [
        [ 0, 19_300, 0.00 ], [ 19_300, 44_100, 0.10 ], [ 44_100, 120_100, 0.12 ],
        [ 120_100, 230_700, 0.22 ], [ 230_700, 422_850, 0.24 ], [ 422_850, 531_750, 0.32 ],
        [ 531_750, 788_000, 0.35 ], [ 788_000, nil, 0.37 ]
      ]
    },
    "head_of_household" => {
      adjustment: 8_600,
      brackets: [
        [ 0, 15_550, 0.00 ], [ 15_550, 33_250, 0.10 ], [ 33_250, 83_000, 0.12 ],
        [ 83_000, 121_250, 0.22 ], [ 121_250, 217_300, 0.24 ], [ 217_300, 271_750, 0.32 ],
        [ 271_750, 656_150, 0.35 ], [ 656_150, nil, 0.37 ]
      ]
    }
  }.freeze

  def up
    execute <<~SQL.squish
      INSERT INTO annual_tax_configs
        (tax_year, ss_wage_base, ss_rate, medicare_rate, additional_medicare_rate,
         additional_medicare_threshold, is_active, created_at, updated_at)
      VALUES (2026, 184500.00, 0.062, 0.0145, 0.009, 200000.00, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (tax_year) DO UPDATE SET
        ss_wage_base = EXCLUDED.ss_wage_base,
        ss_rate = EXCLUDED.ss_rate,
        medicare_rate = EXCLUDED.medicare_rate,
        additional_medicare_rate = EXCLUDED.additional_medicare_rate,
        additional_medicare_threshold = EXCLUDED.additional_medicare_threshold,
        updated_at = CURRENT_TIMESTAMP
    SQL

    WITHHOLDING.each do |filing_status, data|
      quoted_status = connection.quote(filing_status)
      execute <<~SQL.squish
        INSERT INTO filing_status_configs
          (annual_tax_config_id, filing_status, standard_deduction, created_at, updated_at)
        SELECT id, #{quoted_status}, #{data.fetch(:adjustment)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM annual_tax_configs WHERE tax_year = 2026
        ON CONFLICT (annual_tax_config_id, filing_status) DO UPDATE SET
          standard_deduction = EXCLUDED.standard_deduction,
          updated_at = CURRENT_TIMESTAMP
      SQL

      data.fetch(:brackets).each_with_index do |(minimum, maximum, rate), index|
        quoted_maximum = maximum.nil? ? "NULL" : maximum.to_s
        execute <<~SQL.squish
          INSERT INTO tax_brackets
            (filing_status_config_id, bracket_order, min_income, max_income, rate, created_at, updated_at)
          SELECT fsc.id, #{index + 1}, #{minimum}, #{quoted_maximum}, #{rate}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
          FROM filing_status_configs fsc
          INNER JOIN annual_tax_configs atc ON atc.id = fsc.annual_tax_config_id
          WHERE atc.tax_year = 2026 AND fsc.filing_status = #{quoted_status}
          ON CONFLICT (filing_status_config_id, bracket_order) DO UPDATE SET
            min_income = EXCLUDED.min_income,
            max_income = EXCLUDED.max_income,
            rate = EXCLUDED.rate,
            updated_at = CURRENT_TIMESTAMP
        SQL
      end

      execute <<~SQL.squish
        DELETE FROM tax_brackets
        WHERE filing_status_config_id IN (
          SELECT fsc.id FROM filing_status_configs fsc
          INNER JOIN annual_tax_configs atc ON atc.id = fsc.annual_tax_config_id
          WHERE atc.tax_year = 2026 AND fsc.filing_status = #{quoted_status}
        ) AND bracket_order > #{data.fetch(:brackets).size}
      SQL
    end

    execute <<~SQL.squish
      UPDATE tax_tables
      SET additional_medicare_threshold = 200000.00,
          updated_at = CURRENT_TIMESTAMP
      WHERE tax_year = 2026
        AND filing_status = 'married'
        AND additional_medicare_threshold = 250000.00
    SQL
  end

  def down
    # These values correct regulatory configuration. Reverting the migration
    # must not restore known-bad withholding data.
  end
end
