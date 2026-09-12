# frozen_string_literal: true

class PayrollHistoryQuery
  DEFAULT_PER_PAGE = 50
  MAX_PER_PAGE = 100
  SORT_COLUMNS = {
    "pay_period" => "start_date",
    "pay_date" => "pay_date",
    "processed" => "processed_at",
    "employees" => "employee_count",
    "gross" => "total_gross",
    "net" => "total_net",
    "status" => "status",
    "source" => "source_system"
  }.freeze
  SOURCES = %w[all cornerstone quickbooks].freeze
  STATUSES = %w[draft calculated approved committed locked].freeze

  Result = Data.define(:data, :meta)

  def initialize(company_id:, params:, audience: :staff)
    @company_id = Integer(company_id)
    @audience = audience.to_sym
    raise ArgumentError, "Unknown payroll history audience" unless @audience.in?(%i[staff client])
    @page = [ params.fetch(:page, 1).to_i, 1 ].max
    @per_page = params.fetch(:per_page, DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
    @status = params[:status].to_s.presence
    @year = params[:year].to_s.match?(/\A\d{4}\z/) ? params[:year].to_i : nil
    @search = params[:search].to_s.strip.presence
    @sort = SORT_COLUMNS.key?(params[:sort].to_s) ? params[:sort].to_s : "pay_period"
    @direction = params[:direction].to_s == "asc" ? "ASC" : "DESC"
    @source = SOURCES.include?(params[:source].to_s) ? params[:source].to_s : "all"
  end

  def call
    result = connection.select_one(result_sql)
    raw_rows = decoded_json(result.fetch("data"), fallback: [])
    native_periods = PayPeriod
      .where(company_id: @company_id, id: raw_rows.filter_map { |row| row["id"] if row["record_type"] == "native" })
      .index_by(&:id)
    rows = raw_rows.map { |row| serialize(row, native_periods:) }
    total_count = result.fetch("total_count").to_i

    Result.new(
      data: rows,
      meta: {
        current_page: @page,
        per_page: @per_page,
        total_count: total_count,
        total_pages: (total_count.to_f / @per_page).ceil,
        statuses: decoded_json(result.fetch("statuses"), fallback: {}).transform_values(&:to_i),
        sources: decoded_json(result.fetch("sources"), fallback: {}).transform_values(&:to_i),
        years: decoded_json(result.fetch("years"), fallback: []).map(&:to_i)
      }
    )
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def union_sql
    company = connection.quote(@company_id)
    <<~SQL.squish
      SELECT
        ('native:' || pp.id::text) AS key,
        'native'::text AS record_type,
        pp.id,
        pp.company_id,
        pp.start_date,
        pp.end_date,
        pp.pay_date,
        pp.status::text AS status,
        pp.run_purpose::text AS run_purpose,
        pp.includes_base_salary,
        pp.includes_recurring_items,
        pp.correction_status::text AS correction_status,
        pp.notes::text AS notes,
        COUNT(pi.id)::bigint AS employee_count,
        COALESCE(SUM(pi.gross_pay), 0)::numeric AS total_gross,
        COALESCE(SUM(pi.net_pay), 0)::numeric AS total_net,
        pp.committed_at AS processed_at,
        committed_user.name::text AS processed_by_name,
        'cornerstone'::text AS source_system,
        'Cornerstone'::text AS source_label,
        (pp.status = 'committed') AS source_locked
      FROM pay_periods pp
      LEFT JOIN payroll_items pi ON pi.pay_period_id = pp.id AND COALESCE(pi.voided, FALSE) = FALSE
      LEFT JOIN users committed_user ON committed_user.id = pp.committed_by_id AND committed_user.company_id = pp.company_id
      WHERE pp.company_id = #{company}
        #{client_native_visibility_sql}
      GROUP BY pp.id, committed_user.name
      UNION ALL
      SELECT
        ('imported:' || historical_period.id::text) AS key,
        'imported'::text AS record_type,
        historical_period.id,
        historical_period.company_id,
        historical_period.start_date,
        historical_period.end_date,
        historical_period.pay_date,
        'locked'::text AS status,
        'regular'::text AS run_purpose,
        TRUE AS includes_base_salary,
        TRUE AS includes_recurring_items,
        NULL::text AS correction_status,
        NULL::text AS notes,
        historical_period.paycheck_count::bigint AS employee_count,
        COALESCE(NULLIF(historical_period.totals ->> 'gross_pay', '')::numeric, 0) AS total_gross,
        COALESCE(NULLIF(historical_period.totals ->> 'net_pay', '')::numeric, 0) AS total_net,
        historical_batch.locked_at AS processed_at,
        locked_user.name::text AS processed_by_name,
        'quickbooks_online'::text AS source_system,
        historical_period.source_label::text AS source_label,
        TRUE AS source_locked
      FROM historical_pay_periods historical_period
      INNER JOIN historical_import_batches historical_batch
        ON historical_batch.id = historical_period.historical_import_batch_id
        AND historical_batch.company_id = historical_period.company_id
        AND historical_batch.status = 'locked'
      LEFT JOIN users locked_user
        ON locked_user.id = historical_batch.locked_by_id
        AND locked_user.company_id = historical_period.company_id
      WHERE historical_period.company_id = #{company}
        AND historical_period.period_type = 'regular'
    SQL
  end

  def filtered_sql(include_status: true)
    clauses = []
    clauses << "status = #{connection.quote(@status)}" if include_status && STATUSES.include?(@status)
    clauses << "EXTRACT(YEAR FROM pay_date)::integer = #{@year}" if @year
    clauses << "source_system = 'cornerstone'" if @source == "cornerstone"
    clauses << "source_system = 'quickbooks_online'" if @source == "quickbooks"
    if @search
      query = connection.quote("%#{ActiveRecord::Base.sanitize_sql_like(@search)}%")
      clauses << <<~SQL.squish
        (CAST(start_date AS text) ILIKE #{query}
          OR CAST(end_date AS text) ILIKE #{query}
          OR CAST(pay_date AS text) ILIKE #{query}
          OR TO_CHAR(start_date, 'Mon FMDD, YYYY') ILIKE #{query}
          OR TO_CHAR(end_date, 'Mon FMDD, YYYY') ILIKE #{query}
          OR TO_CHAR(pay_date, 'Mon FMDD, YYYY') ILIKE #{query}
          OR (CASE
            WHEN EXTRACT(YEAR FROM start_date) = EXTRACT(YEAR FROM end_date)
              AND EXTRACT(MONTH FROM start_date) = EXTRACT(MONTH FROM end_date)
            THEN TO_CHAR(start_date, 'Mon FMDD') || ' - ' || TO_CHAR(end_date, 'FMDD, YYYY')
            ELSE TO_CHAR(start_date, 'Mon FMDD, YYYY') || ' - ' || TO_CHAR(end_date, 'Mon FMDD, YYYY')
          END) ILIKE #{query}
          OR status ILIKE #{query}
          OR run_purpose ILIKE #{query}
          OR source_label ILIKE #{query}
          OR COALESCE(processed_by_name, '') ILIKE #{query})
      SQL
    end
    clauses.any? ? "WHERE #{clauses.join(' AND ')}" : ""
  end

  def client_native_visibility_sql
    return "" unless @audience == :client

    "AND pp.status = 'committed' AND (pp.correction_status IS NULL OR pp.correction_status = 'correction')"
  end

  def result_sql
    offset = (@page - 1) * @per_page
    order = "#{SORT_COLUMNS.fetch(@sort)} #{@direction} NULLS LAST, record_type ASC, id DESC"
    <<~SQL.squish
      WITH payroll_history AS MATERIALIZED (#{union_sql}),
      filtered_history AS (
        SELECT * FROM payroll_history #{filtered_sql}
      ),
      page_rows AS (
        SELECT * FROM filtered_history ORDER BY #{order} LIMIT #{@per_page} OFFSET #{offset}
      )
      SELECT
        COALESCE((SELECT JSONB_AGG(TO_JSONB(page_rows) ORDER BY #{order}) FROM page_rows), '[]'::jsonb) AS data,
        (SELECT COUNT(*) FROM filtered_history) AS total_count,
        COALESCE((
          SELECT JSONB_OBJECT_AGG(status, count)
          FROM (
            SELECT status, COUNT(*) AS count
            FROM payroll_history #{filtered_sql(include_status: false)}
            GROUP BY status
          ) status_counts
        ), '{}'::jsonb) AS statuses,
        COALESCE((
          SELECT JSONB_OBJECT_AGG(source_system, count)
          FROM (
            SELECT source_system, COUNT(*) AS count
            FROM payroll_history #{filtered_sql}
            GROUP BY source_system
          ) source_counts
        ), '{}'::jsonb) AS sources,
        COALESCE((
          SELECT JSONB_AGG(year ORDER BY year DESC)
          FROM (
            SELECT DISTINCT EXTRACT(YEAR FROM pay_date)::integer AS year
            FROM payroll_history
          ) available_years
        ), '[]'::jsonb) AS years
    SQL
  end

  def decoded_json(value, fallback:)
    return value if value.is_a?(Array) || value.is_a?(Hash)
    return fallback if value.blank?

    JSON.parse(value)
  end

  def serialize(row, native_periods:)
    imported = row.fetch("record_type") == "imported"
    parallel_run = !imported && native_periods[row.fetch("id").to_i]&.parallel_run?
    status = row.fetch("status")
    correction_status = row["correction_status"]
    editable = @audience == :staff && !imported && status != "committed" && correction_status != "voided"

    {
      key: row.fetch("key"),
      record_type: row.fetch("record_type"),
      id: row.fetch("id").to_i,
      company_id: row.fetch("company_id").to_i,
      start_date: row.fetch("start_date"),
      end_date: row.fetch("end_date"),
      pay_date: row.fetch("pay_date"),
      status: status,
      run_purpose: row.fetch("run_purpose"),
      includes_base_salary: row.fetch("includes_base_salary"),
      includes_recurring_items: row.fetch("includes_recurring_items"),
      correction_status: correction_status,
      notes: row["notes"],
      compliance_warnings: imported ? [] : (native_periods[row.fetch("id").to_i]&.compliance_warnings || []),
      parallel_run: parallel_run,
      employee_count: row.fetch("employee_count").to_i,
      total_gross: row.fetch("total_gross").to_d.to_f,
      total_net: row.fetch("total_net").to_d.to_f,
      processed_at: row["processed_at"],
      processed_by_name: row["processed_by_name"],
      source: {
        system: row.fetch("source_system"),
        label: imported ? "QuickBooks import" : row.fetch("source_label"),
        detail: row.fetch("source_label"),
        locked: ActiveModel::Type::Boolean.new.cast(row.fetch("source_locked"))
      },
      capabilities: {
        view: true,
        edit: editable,
        delete: editable,
        enter_hours: @audience == :staff && !imported && status == "draft" && correction_status != "voided",
        run: @audience == :staff && !imported && %w[draft calculated].include?(status) && correction_status != "voided",
        approve: @audience == :staff && !imported && status == "calculated" && correction_status != "voided",
        commit: @audience == :staff && !imported && !parallel_run && status == "approved" && correction_status != "voided"
      }
    }
  end
end
