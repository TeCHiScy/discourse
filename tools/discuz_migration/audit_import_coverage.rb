#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "date"
require "fileutils"
require "json"
require "mysql2"
require "optparse"
require "time"
require "yaml"

class DiscuzImportCoverageAudit
  DEFAULT_BBS_SCHEMA = "bbs"
  DEFAULT_UCENTER_SCHEMA = "ucenter"
  DEFAULT_HOST = "127.0.0.1"
  DEFAULT_PORT = 13_306
  DISPOSITIONS = %w[migrated_direct migrated_adapted logic_only not_needed pending_review].freeze

  def initialize(argv)
    @root = File.expand_path("../..", __dir__)
    @policy_path = File.join(__dir__, "field_coverage_policy.yml")
    @output_path =
      File.join(__dir__, "reports", "discuz-field-coverage-#{Date.today.strftime("%Y%m%d")}.csv")
    @summary_path = nil
    @external_schema_manifest_path =
      File.join(__dir__, "schema_snapshots", "extend-flydata-20261021.json")
    @include_external_schema_manifest = true
    @external_schema_supplement = nil
    @options = {
      host: DEFAULT_HOST,
      port: DEFAULT_PORT,
      bbs: DEFAULT_BBS_SCHEMA,
      ucenter: DEFAULT_UCENTER_SCHEMA,
    }
    parse_options(argv)
    @summary_path ||= @output_path.sub(/\.csv\z/, ".summary.json")
  end

  def run
    validate_source_configuration!
    load_policy!
    @client = connect_source
    @client.query("SET SESSION TRANSACTION READ ONLY")
    @client.query("START TRANSACTION READ ONLY")

    columns = source_columns
    raise "source schema returned no columns" if columns.empty?

    validate_policy_against_schema!(columns)
    rows = columns.map { |column| report_row(column) }
    summary = build_summary(rows)
    write_csv(rows)
    write_summary(summary)
    print_summary(summary)
  ensure
    begin
      @client&.query("ROLLBACK")
    rescue Mysql2::Error
      nil
    end
    @client&.close
  end

  private

  def parse_options(argv)
    OptionParser
      .new do |parser|
        parser.banner = "Usage: audit_import_coverage.rb [options]"
        parser.on("--output PATH", "CSV output path (schema metadata only)") do |value|
          @output_path = File.expand_path(value)
        end
        parser.on("--summary PATH", "JSON summary output path") do |value|
          @summary_path = File.expand_path(value)
        end
        parser.on("--host HOST", "Source MySQL host; only 127.0.0.1 is allowed") do |value|
          @options[:host] = value
        end
        parser.on("--port PORT", Integer, "Source MySQL port; only 13306 is allowed") do |value|
          @options[:port] = value
        end
        parser.on("--bbs-schema NAME", "BBS schema; only bbs is allowed") do |value|
          @options[:bbs] = value
        end
        parser.on("--ucenter-schema NAME", "UCenter schema; only ucenter is allowed") do |value|
          @options[:ucenter] = value
        end
        parser.on(
          "--external-schema-manifest PATH",
          "Schema-only supplemental manifest; defaults to the captured extend_flydata snapshot",
        ) { |value| @external_schema_manifest_path = File.expand_path(value) }
        parser.on("--without-external-schema-manifest", "Audit only the bbs/ucenter baseline") do
          @include_external_schema_manifest = false
        end
        parser.on("-h", "--help", "Show this help") do
          puts parser
          exit
        end
      end
      .parse!(argv)
    raise OptionParser::InvalidArgument, "unexpected arguments: #{ARGV.join(" ")}" if ARGV.any?
  end

  def validate_source_configuration!
    unless @options[:host] == DEFAULT_HOST && @options[:port] == DEFAULT_PORT &&
             @options[:bbs] == DEFAULT_BBS_SCHEMA && @options[:ucenter] == DEFAULT_UCENTER_SCHEMA
      raise "audit is restricted to the local bbs/ucenter baseline at 127.0.0.1:13306"
    end
    unless ENV.fetch("DISCUZX_DB_HOST", DEFAULT_HOST) == DEFAULT_HOST &&
             Integer(ENV.fetch("DISCUZX_DB_PORT", DEFAULT_PORT.to_s)) == DEFAULT_PORT &&
             ENV.fetch("DISCUZX_DB", DEFAULT_BBS_SCHEMA) == DEFAULT_BBS_SCHEMA &&
             ENV.fetch("UCENTER_DB", DEFAULT_UCENTER_SCHEMA) == DEFAULT_UCENTER_SCHEMA &&
             ENV.fetch("DISCUZX_TABLE_PREFIX", "").empty?
      raise "audit environment must point only to the local bbs/ucenter baseline without a table prefix"
    end
    raise "DISCUZX_DB_USER is required" if ENV["DISCUZX_DB_USER"].to_s.empty?
    raise "MYSQL_PWD is required" if ENV["MYSQL_PWD"].to_s.empty?
  end

  def connect_source
    Mysql2::Client.new(
      host: @options[:host],
      port: @options[:port],
      username: ENV.fetch("DISCUZX_DB_USER"),
      password: ENV.fetch("MYSQL_PWD"),
      database: @options[:bbs],
      encoding: "utf8mb4",
      connect_timeout: 5,
      read_timeout: 120,
      write_timeout: 120,
      get_server_public_key: true,
    )
  end

  def load_policy!
    @policy = YAML.safe_load_file(@policy_path, aliases: false)
    raise "unsupported coverage policy version" unless @policy["version"] == 1

    @exact_rules = {}
    @table_rules = {}
    @pending_table_notes = @policy.fetch("pending_table_notes", {})
    @patterns =
      Array(@policy["patterns"]).map do |entry|
        [entry.fetch("database"), Regexp.new(entry.fetch("table_regex")), entry.fetch("fields")]
      end

    @policy
      .fetch("tables")
      .each do |qualified_table, entry|
        database, table = qualified_table.split(".", 2)
        raise "invalid table policy key #{qualified_table}" unless database && table

        @table_rules[[database, table]] = entry["all_fields"] if entry.key?("all_fields")
        entry
          .fetch("fields", {})
          .each { |column, rule| @exact_rules[[database, table, column]] = rule }
      end
  end

  def source_columns
    schema_names = [@options[:bbs], @options[:ucenter]]
    placeholders = schema_names.map { "?" }.join(",")
    baseline_columns =
      @client
        .prepare(
          "SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE, " \
            "COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY " \
            "FROM information_schema.COLUMNS " \
            "WHERE TABLE_SCHEMA IN (#{placeholders}) " \
            "ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION",
        )
        .execute(*schema_names)
        .to_a

    baseline_columns + external_schema_columns
  end

  def external_schema_columns
    return [] unless @include_external_schema_manifest

    manifest = JSON.parse(File.read(@external_schema_manifest_path))
    raise "unsupported external schema manifest version" unless manifest["manifest_version"] == 1

    source = manifest.fetch("source")
    raise "unsupported external schema supplement" unless source["schema"] == "extend_flydata"

    excluded_fields = Array(source["excluded_field_metadata"])
    columns = manifest.fetch("columns")
    raise "external schema manifest returned no columns" if columns.empty?

    required_column_keys = %w[
      TABLE_SCHEMA
      TABLE_NAME
      COLUMN_NAME
      ORDINAL_POSITION
      DATA_TYPE
      COLUMN_TYPE
      IS_NULLABLE
      COLUMN_KEY
    ]
    columns.each do |column|
      missing_keys = required_column_keys.reject { |key| column.key?(key) }
      if missing_keys.any?
        raise "external schema manifest is missing column metadata: #{missing_keys.join(", ")}"
      end
      unless column["TABLE_SCHEMA"] == source["schema"]
        raise "unexpected external schema in manifest"
      end
      qualified_field =
        "#{column.fetch("TABLE_SCHEMA")}.#{column.fetch("TABLE_NAME")}.#{column.fetch("COLUMN_NAME")}"
      if excluded_fields.include?(qualified_field.sub(/\Aextend_flydata\./, "")) ||
           excluded_fields.include?(qualified_field)
        raise "excluded field metadata must not be present: #{qualified_field}"
      end
    end

    @external_schema_supplement = {
      manifest_file: @external_schema_manifest_path.delete_prefix("#{@root}/"),
      schema: source.fetch("schema"),
      captured_on: source.fetch("captured_on"),
      capture_method: source.fetch("capture_method"),
      scope: source.fetch("scope"),
      excluded_field_metadata: excluded_fields,
      note: source.fetch("note"),
      table_count: columns.map { |column| column.fetch("TABLE_NAME") }.uniq.length,
      column_count: columns.length,
    }
    columns
  end

  def validate_policy_against_schema!(columns)
    source_keys =
      columns.to_h do |column|
        [
          [column.fetch("TABLE_SCHEMA"), column.fetch("TABLE_NAME"), column.fetch("COLUMN_NAME")],
          true,
        ]
      end
    stale = @exact_rules.keys.reject { |key| source_keys.key?(key) }
    missing_tables =
      @table_rules.keys.reject do |database, table|
        columns.any? do |column|
          column["TABLE_SCHEMA"] == database && column["TABLE_NAME"] == table
        end
      end
    unmatched_patterns =
      @patterns.reject do |database, pattern, _fields|
        columns.any? do |column|
          column["TABLE_SCHEMA"] == database && pattern.match?(column["TABLE_NAME"])
        end
      end
    stale_pattern_fields =
      @patterns.flat_map do |database, pattern, fields|
        matched_tables =
          columns
            .select do |column|
              column["TABLE_SCHEMA"] == database && pattern.match?(column["TABLE_NAME"])
            end
            .map { |column| column["TABLE_NAME"] }
            .uniq
        matched_tables.flat_map do |table|
          fields.keys.filter_map do |field|
            field_key = [database, table, field]
            field_key unless source_keys.key?(field_key)
          end
        end
      end
    missing_note_tables =
      @pending_table_notes.keys.reject do |qualified_table|
        database, table = qualified_table.split(".", 2)
        columns.any? do |column|
          column["TABLE_SCHEMA"] == database && column["TABLE_NAME"] == table
        end
      end

    unless stale.empty? && missing_tables.empty? && unmatched_patterns.empty? &&
             stale_pattern_fields.empty? && missing_note_tables.empty?
      details = []
      details << "stale field rules: #{stale.map { |key| key.join(".") }.join(", ")}" if stale.any?
      if missing_tables.any?
        details << "missing table rules: #{missing_tables.map { |key| key.join(".") }.join(", ")}"
      end
      if stale_pattern_fields.any?
        details << "stale pattern fields: #{stale_pattern_fields.map { |key| key.join(".") }.join(", ")}"
      end
      if missing_note_tables.any?
        details << "missing pending-note tables: #{missing_note_tables.join(", ")}"
      end
      if unmatched_patterns.any?
        details << "patterns matched no tables: #{unmatched_patterns.map { |database, pattern, _| "#{database}.#{pattern}" }.join(", ")}"
      end
      raise "coverage policy does not match source schema: #{details.join("; ")}"
    end
  end

  def policy_for(database, table, column)
    return @exact_rules[[database, table, column]] if @exact_rules.key?([database, table, column])
    return @table_rules[[database, table]] if @table_rules.key?([database, table])

    pattern =
      @patterns.find do |pattern_database, regex, _fields|
        pattern_database == database && regex.match?(table)
      end
    return pattern.last[column] if pattern && pattern.last.key?(column)
    if @pending_table_notes.key?("#{database}.#{table}")
      return(
        {
          "disposition" => "pending_review",
          "target" => "No confirmed Discourse/plugin mapping",
          "reason" => @pending_table_notes.fetch("#{database}.#{table}"),
          "evidence" =>
            "Coverage policy table note; field-level mapping or omission decision is open.",
        }
      )
    end

    @policy.fetch("default")
  end

  def report_row(column)
    database = column.fetch("TABLE_SCHEMA")
    table = column.fetch("TABLE_NAME")
    name = column.fetch("COLUMN_NAME")
    rule = policy_for(database, table, name)
    disposition = rule.fetch("disposition")
    case disposition
    when *DISPOSITIONS
      nil
    else
      raise "invalid disposition #{disposition} for #{database}.#{table}.#{name}"
    end

    {
      "database" => database,
      "table" => table,
      "column" => name,
      "ordinal_position" => column.fetch("ORDINAL_POSITION"),
      "data_type" => column.fetch("DATA_TYPE"),
      "column_type" => column.fetch("COLUMN_TYPE"),
      "nullable" => column.fetch("IS_NULLABLE"),
      "key" => column.fetch("COLUMN_KEY"),
      "disposition" => disposition,
      "target" => rule.fetch("target", ""),
      "reason" => rule.fetch("reason", ""),
      "evidence" => rule.fetch("evidence", ""),
    }
  end

  def build_summary(rows)
    counts = rows.group_by { |row| row.fetch("disposition") }.transform_values(&:length)
    DISPOSITIONS.each { |disposition| counts[disposition] ||= 0 }
    by_database =
      rows
        .group_by { |row| row.fetch("database") }
        .transform_values do |database_rows|
          database_rows.group_by { |row| row.fetch("disposition") }.transform_values(&:length)
        end
    by_table =
      rows
        .group_by { |row| [row.fetch("database"), row.fetch("table")] }
        .map do |(database, table), table_rows|
          disposition_counts =
            table_rows.group_by { |row| row.fetch("disposition") }.transform_values(&:length)
          {
            database: database,
            table: table,
            column_count: table_rows.length,
            pending_review: disposition_counts.fetch("pending_review", 0),
            migrated_direct: disposition_counts.fetch("migrated_direct", 0),
            migrated_adapted: disposition_counts.fetch("migrated_adapted", 0),
            logic_only: disposition_counts.fetch("logic_only", 0),
            not_needed: disposition_counts.fetch("not_needed", 0),
          }
        end
    {
      generated_at_utc: Time.now.utc.iso8601,
      source: {
        host: @options[:host],
        port: @options[:port],
        schemas: [@options[:bbs], @options[:ucenter]],
        database_connection: "read-only transaction; information_schema only",
        external_schema_supplements:
          @external_schema_supplement ? [@external_schema_supplement] : [],
      },
      policy_version: @policy.fetch("version"),
      total_tables: by_table.length,
      total_columns: rows.length,
      disposition_counts: counts,
      by_database: by_database,
      top_pending_tables:
        by_table
          .select { |table| table[:pending_review].positive? }
          .sort_by { |table| [-table[:pending_review], table[:database], table[:table]] }
          .first(30),
      fully_reviewed_tables: by_table.count { |table| table[:pending_review].zero? },
      tables_with_pending_fields: by_table.count { |table| table[:pending_review].positive? },
      priority_pending_tables:
        @pending_table_notes.map do |qualified_table, reason|
          database, table = qualified_table.split(".", 2)
          table_summary =
            by_table.find { |item| item[:database] == database && item[:table] == table }
          {
            database: database,
            table: table,
            pending_fields: table_summary&.fetch(:pending_review, 0).to_i,
            reason: reason,
          }
        end,
    }
  end

  def write_csv(rows)
    FileUtils.mkdir_p(File.dirname(@output_path))
    CSV.open(
      @output_path,
      "wb",
      write_headers: true,
      headers: rows.first.keys,
      force_quotes: true,
    ) { |csv| rows.each { |row| csv << row.values } }
  end

  def write_summary(summary)
    FileUtils.mkdir_p(File.dirname(@summary_path))
    File.write(@summary_path, JSON.pretty_generate(summary) + "\n")
  end

  def print_summary(summary)
    puts JSON.pretty_generate(
           csv_path: @output_path,
           summary_path: @summary_path,
           total_tables: summary.fetch(:total_tables),
           total_columns: summary.fetch(:total_columns),
           disposition_counts: summary.fetch(:disposition_counts),
           by_database: summary.fetch(:by_database),
           fully_reviewed_tables: summary.fetch(:fully_reviewed_tables),
           tables_with_pending_fields: summary.fetch(:tables_with_pending_fields),
           priority_pending_tables: summary.fetch(:priority_pending_tables),
           top_pending_tables: summary.fetch(:top_pending_tables).first(15),
         )
  end
end

DiscuzImportCoverageAudit.new(ARGV).run
