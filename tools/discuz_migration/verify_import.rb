#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "mysql2"
require_relative "category_permissions"
require_relative "../../script/import_scripts/base"

class DiscuzImportVerifier
  ALLOWED_SAMPLE_DATABASES = %w[
    discourse_migration_sample
    discourse_migration_sample_uid18_20261013
  ].freeze

  def initialize
    @source_host = ENV.fetch("DISCUZX_DB_HOST", "127.0.0.1")
    @source_port = Integer(ENV.fetch("DISCUZX_DB_PORT", "13306"))
    @bbs_db = ENV.fetch("DISCUZX_DB", "bbs")
    @uc_db = ENV.fetch("UCENTER_DB", "ucenter")
    @prefix = ENV.fetch("DISCUZX_TABLE_PREFIX", "")
    @target_db = ENV.fetch("DISCOURSE_DEV_DB", "discourse_development")
    @sample_manifest = load_sample_manifest

    unless @source_host == "127.0.0.1" && @source_port == 13_306
      raise "source MySQL must be loopback 127.0.0.1:13306"
    end
    unless @bbs_db == "bbs" && @uc_db == "ucenter" && @prefix.empty?
      raise "source must use the bbs/ucenter lab schemas without a table prefix"
    end

    @source =
      Mysql2::Client.new(
        host: @source_host,
        port: @source_port,
        username: ENV.fetch("DISCUZX_DB_USER"),
        password: ENV.fetch("MYSQL_PWD"),
        database: @bbs_db,
        encoding: "utf8mb4",
        connect_timeout: 5,
        read_timeout: 120,
        write_timeout: 120,
        get_server_public_key: true,
      )
    @source.query("SET SESSION TRANSACTION READ ONLY")
    @source.query("START TRANSACTION READ ONLY")
  end

  def run
    report = nil
    connection = ActiveRecord::Base.connection
    sample_stage =
      if ARGV.include?("--sample-identities")
        :identities
      elsif ARGV.include?("--sample-acceptance")
        :acceptance
      end

    connection.transaction do
      connection.execute("SET TRANSACTION READ ONLY")
      verify_local_target!(connection)
      report =
        if ARGV.include?("--source-preflight")
          source_preflight
        elsif sample_stage
          verify_sample(sample_stage)
        else
          verify_import
        end
    end

    puts JSON.pretty_generate(report)
    failures = (report.dig(:acceptance, :failure_count) || 0).to_i
    exit(failures.positive? ? 1 : 0)
  ensure
    @source&.query("COMMIT")
    @source&.close
  end

  private

  def load_sample_manifest
    path = ENV["DISCUZX_SAMPLE_MANIFEST"]
    return nil if path.blank?

    lab_root = File.realpath("/Users/daren/discourse-lab")
    real_path = File.realpath(File.expand_path(path))
    unless real_path.start_with?("#{lab_root}/") && File.file?(real_path)
      raise "sample manifest must be a file under /Users/daren/discourse-lab"
    end
    raise "sample manifest permissions must be 0600" if (File.stat(real_path).mode & 0o077).nonzero?

    manifest = JSON.parse(File.read(real_path))
    raise "unsupported sample manifest version" unless manifest["version"] == 1
    %w[
      member_uids
      pm_declared_participant_uids
      category_ids
      topic_ids
      post_ids
      pm_thread_ids
      pm_message_ids
      placeholder_uids
      required_uids
    ].each do |key|
      ids = manifest.fetch(key)
      unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(Integer) && id.positive? } &&
               ids.uniq.length == ids.length
        raise "invalid sample manifest IDs for #{key}"
      end
    end
    manifest
  rescue Errno::ENOENT
    raise "sample manifest does not exist"
  end

  def sample_id_sql(key)
    ids = @sample_manifest.fetch(key).map(&:to_i)
    ids.empty? ? "0" : ids.join(",")
  end

  def verify_local_target!(connection)
    host = ENV.fetch("PGHOST", "localhost")
    port = Integer(ENV.fetch("PGPORT", "5432"))
    database = connection.select_value("SELECT current_database()")

    expected_database =
      (
        if @sample_manifest
          @sample_manifest.fetch("target_database", "discourse_migration_sample")
        else
          "discourse_development"
        end
      )
    approved_sample_database =
      !@sample_manifest || ALLOWED_SAMPLE_DATABASES.include?(expected_database)
    unless host == "127.0.0.1" && port == 15_432 && @target_db == expected_database &&
             database == expected_database && approved_sample_database
      raise "Discourse target must be an approved loopback lab PostgreSQL database"
    end
  end

  def source_preflight
    source = load_source_data
    metrics = source_metrics(source)

    {
      mode: "source_preflight",
      source: metrics,
      guidance: {
        hidden_content: "Imported non-public Discuz states must be soft-trashed and recoverable",
        category_access:
          "Source-restricted categories use a staff-only fallback; exact Discuz group, formula, password, and per-user rules remain pending",
        text_content:
          "Stable IDs and relations are checked; normalized text and rendered content need a separate review",
        attachments: "Deferred until a local read-only file snapshot is available",
        custom_features: "Virtual-airline and paid-post adapters remain pending",
      },
    }
  end

  def verify_sample(stage)
    raise "sample verification requires DISCUZX_SAMPLE_MANIFEST" unless @sample_manifest

    source = load_source_data
    user_imports, user_duplicate_values = imported_values(UserCustomField, :user_id)
    category_imports, category_duplicate_values = imported_values(CategoryCustomField, :category_id)
    pm_posts, pm_duplicate_values = imported_post_rows

    source_user_ids = source[:member_ids] | source[:reference_ids]
    user_comparison = compare_ids(source_user_ids, user_imports.keys.to_set)
    expected_placeholders = source[:reference_ids] - source[:member_ids]
    imported_placeholders = flagged_source_user_ids("discuz_missing_bbs_member", user_imports)
    placeholder_target_ids = expected_placeholders.filter_map { |uid| user_imports[uid] }
    active_placeholder_count = User.where(id: placeholder_target_ids, active: true).count
    expected_duplicate_emails = source[:duplicate_email_uids]
    imported_duplicate_emails = flagged_source_user_ids("discuz_duplicate_email", user_imports)

    category_comparison = compare_ids(source[:category_ids], category_imports.keys.to_set)
    category_content_report = verify_categories(source, category_imports)
    password_report = verify_legacy_password_fields(source, user_imports)
    sample_source_integrity = verify_sample_source_integrity(source)
    content_reports =
      if stage == :acceptance
        [
          verify_posts(source, user_imports, category_imports),
          verify_private_messages(source, user_imports, pm_posts, pm_duplicate_values),
        ]
      end
    post_report, pm_report = content_reports if content_reports

    core_failures = [
      user_comparison[:missing_count],
      user_comparison[:unexpected_count],
      user_duplicate_values.length,
      compare_ids(expected_placeholders, imported_placeholders)[:missing_count],
      compare_ids(expected_placeholders, imported_placeholders)[:unexpected_count],
      active_placeholder_count,
      compare_ids(expected_duplicate_emails, imported_duplicate_emails)[:missing_count],
      compare_ids(expected_duplicate_emails, imported_duplicate_emails)[:unexpected_count],
      category_comparison[:missing_count],
      category_comparison[:unexpected_count],
      category_duplicate_values.length,
      category_content_report[:name_mismatches],
      category_content_report[:parent_mismatches],
      category_content_report[:read_restriction_mismatches],
      category_content_report[:permission_mismatches],
      category_content_report[:access_metadata_mismatches],
      password_report[:missing_hash_or_salt_count],
      sample_source_integrity[:mismatch_count],
    ]
    if post_report && pm_report
      core_failures.concat([post_report[:failure_count], pm_report[:failure_count]])
    end

    {
      mode: "relation_closed_sample_#{stage}",
      sample: {
        selection: @sample_manifest.dig("selection", "seed"),
        sampled_member_rows: @sample_manifest.fetch("member_uids").length,
        member_dependency_closure: source_user_ids.length,
        placeholder_accounts: expected_placeholders.length,
        categories: source[:category_ids].length,
        selected_topics: @sample_manifest.fetch("topic_ids").length,
        selected_posts: @sample_manifest.fetch("post_ids").length,
        selected_pm_threads: @sample_manifest.fetch("pm_thread_ids").length,
        selected_pm_messages: @sample_manifest.fetch("pm_message_ids").length,
        selected_pm_messages_by_shard: @sample_manifest.fetch("pm_shard_message_counts"),
        declared_one_to_one_pm_participants:
          @sample_manifest.fetch("pm_declared_participant_uids").length,
        pm_shard_zero_included:
          @sample_manifest.dig("sample_counts", "pm_threads_with_shard_zero_messages"),
        relation_policy:
          "all posts per selected topic; all messages and participants per selected PM thread; all referenced users",
        source_manifest_integrity: sample_source_integrity,
      },
      users: {
        imported_uid_count: user_imports.length,
        uid_comparison: user_comparison,
        duplicate_import_uid_count: user_duplicate_values.length,
        expected_non_login_placeholder_count: expected_placeholders.length,
        placeholder_flag_comparison: compare_ids(expected_placeholders, imported_placeholders),
        active_non_login_placeholders: active_placeholder_count,
        expected_duplicate_email_remaps: expected_duplicate_emails.length,
        duplicate_email_flag_comparison:
          compare_ids(expected_duplicate_emails, imported_duplicate_emails),
        legacy_auth: password_report,
      },
      categories: {
        imported_id_count: category_imports.length,
        id_comparison: category_comparison,
        duplicate_import_id_count: category_duplicate_values.length,
        content_relationships: category_content_report,
      },
      posts: post_report || { status: "deferred_until_sample_content_stage" },
      private_messages: pm_report || { status: "deferred_until_sample_content_stage" },
      acceptance: {
        status:
          (
            if core_failures.any?(&:positive?)
              "failed"
            else
              (stage == :acceptance ? "passed_with_pending_stages" : "identity_stage_passed")
            end
          ),
        failure_count: core_failures.sum,
        pending_content_stage: stage == :identities,
      },
    }
  end

  def verify_import
    source = load_source_data
    source_report = source_metrics(source)
    user_imports, user_duplicate_values = imported_values(UserCustomField, :user_id)
    category_imports, category_duplicate_values = imported_values(CategoryCustomField, :category_id)
    pm_posts, pm_duplicate_values = imported_post_rows

    source_user_ids = source[:member_ids] | source[:reference_ids]
    user_comparison = compare_ids(source_user_ids, user_imports.keys.to_set)
    expected_placeholders = source[:reference_ids] - source[:member_ids]
    imported_placeholders = flagged_source_user_ids("discuz_missing_bbs_member", user_imports)
    placeholder_target_ids = expected_placeholders.filter_map { |uid| user_imports[uid] }
    active_placeholder_count = User.where(id: placeholder_target_ids, active: true).count
    expected_duplicate_emails = source[:duplicate_email_uids]
    imported_duplicate_emails = flagged_source_user_ids("discuz_duplicate_email", user_imports)

    category_comparison = compare_ids(source[:category_ids], category_imports.keys.to_set)
    category_content_report = verify_categories(source, category_imports)
    post_report = verify_posts(source, user_imports, category_imports)
    pm_report = verify_private_messages(source, user_imports, pm_posts, pm_duplicate_values)
    password_report = verify_legacy_password_fields(source, user_imports)

    core_failures = [
      user_comparison[:missing_count],
      user_comparison[:unexpected_count],
      user_duplicate_values.length,
      compare_ids(expected_placeholders, imported_placeholders)[:missing_count],
      compare_ids(expected_placeholders, imported_placeholders)[:unexpected_count],
      active_placeholder_count,
      compare_ids(expected_duplicate_emails, imported_duplicate_emails)[:missing_count],
      compare_ids(expected_duplicate_emails, imported_duplicate_emails)[:unexpected_count],
      category_comparison[:missing_count],
      category_comparison[:unexpected_count],
      category_duplicate_values.length,
      category_content_report[:name_mismatches],
      category_content_report[:parent_mismatches],
      category_content_report[:read_restriction_mismatches],
      category_content_report[:permission_mismatches],
      category_content_report[:access_metadata_mismatches],
      post_report[:failure_count],
      pm_report[:failure_count],
      password_report[:missing_hash_or_salt_count],
    ]

    {
      mode: "import_acceptance",
      source: source_report,
      users: {
        imported_uid_count: user_imports.length,
        uid_comparison: user_comparison,
        duplicate_import_uid_count: user_duplicate_values.length,
        expected_non_login_placeholder_count: expected_placeholders.length,
        placeholder_flag_comparison: compare_ids(expected_placeholders, imported_placeholders),
        active_non_login_placeholders: active_placeholder_count,
        expected_duplicate_email_remaps: expected_duplicate_emails.length,
        duplicate_email_flag_comparison:
          compare_ids(expected_duplicate_emails, imported_duplicate_emails),
        legacy_auth: password_report,
      },
      categories: {
        imported_id_count: category_imports.length,
        id_comparison: category_comparison,
        duplicate_import_id_count: category_duplicate_values.length,
        content_relationships: category_content_report,
      },
      posts: post_report,
      private_messages: pm_report,
      deferred: {
        category_access: {
          status: "staff_only_fallback_exact_mapping_pending",
          source_restricted_categories:
            source_report.dig(:category_access, :effective_read_restricted),
          categories_with_user_view_overrides:
            source_report.dig(:category_access, :categories_with_user_view_overrides),
        },
        text_content: {
          status: "pending_normalization_and_render_review",
          verified_fields: %w[stable_ids authors categories threads timestamps visibility],
          body_text_is_not_selected_or_printed: true,
        },
        attachments: {
          status: "pending_file_snapshot",
          source_attachment_rows: source_report[:attachment_record_count],
          source_avatar_users: source_report[:avatar_user_count],
        },
        custom_features: {
          status: "pending_adaptation",
          items: %w[virtual_airline paid_posts],
        },
      },
      acceptance: {
        status: core_failures.any?(&:positive?) ? "failed" : "passed_with_pending_stages",
        failure_count: core_failures.sum,
        pending_stage_count: 4,
      },
    }
  end

  def load_source_data
    member_filter = " WHERE uid IN (#{sample_id_sql("member_uids")})" if @sample_manifest
    members = rows("SELECT uid, email FROM (#{member_union}) members#{member_filter} ORDER BY uid")
    member_ids = members.map { |row| row["uid"].to_s }.to_set
    references = @sample_manifest ? sample_referenced_uid_union : referenced_uid_union
    reference_ids = rows(<<~SQL).map { |row| row["uid"].to_s }.to_set
      SELECT refs.uid
        FROM (#{references}) refs
       WHERE refs.uid IS NOT NULL
    SQL
    duplicate_email_uids = rows(<<~SQL).map { |row| row["uid"].to_s }.to_set
      SELECT members.uid
        FROM (#{member_union}) members
        JOIN (
          SELECT LOWER(TRIM(email)) email_key, MIN(uid) retained_uid
            FROM (#{member_union}) candidates
           WHERE email IS NOT NULL AND TRIM(email) <> ''
           GROUP BY LOWER(TRIM(email))
          HAVING COUNT(DISTINCT uid) > 1
        ) duplicates ON LOWER(TRIM(members.email)) = duplicates.email_key
       WHERE members.uid <> duplicates.retained_uid
    SQL
    duplicate_email_uids &= member_ids if @sample_manifest
    medals_enabled =
      scalar("SELECT COUNT(*) count FROM #{bbs("forum_medal")} WHERE available = 1") > 0
    category_rows = rows(<<~SQL)
      SELECT f.fid id, f.fup parent_id, f.name, f.type, f.status,
             d.viewperm, d.formulaperm, d.password forum_password,
             d.postperm, d.replyperm,
             EXISTS (
               SELECT 1 FROM #{bbs("forum_access")} access
                WHERE access.fid = f.fid AND access.allowview <> 0
             ) has_user_view_override
        FROM #{bbs("forum_forum")} f
        LEFT JOIN #{bbs("forum_forumfield")} d USING(fid)
    SQL
    category_ids =
      category_rows
        .reject { |row| row["type"] == "group" || row["status"].to_i == 2 }
        .map { |row| row["id"].to_s }
        .to_set
    pm_rows = rows(pm_message_union_sql)
    pm_filter = " WHERE plid IN (#{sample_id_sql("pm_thread_ids")})" if @sample_manifest
    pm_members = rows("SELECT plid thread_id, uid FROM #{uc("pm_members")}#{pm_filter}")
    pm_list_rows = rows("SELECT plid thread_id, pmtype, min_max FROM #{uc("pm_lists")}#{pm_filter}")
    pm_indexes = rows("SELECT plid thread_id, pmid id FROM #{uc("pm_indexes")}#{pm_filter}")

    {
      members: members,
      member_ids: member_ids,
      reference_ids: reference_ids,
      duplicate_email_uids: duplicate_email_uids,
      category_rows: category_rows,
      category_ids: category_ids,
      medals_enabled: medals_enabled,
      pm_rows: pm_rows,
      pm_members: pm_members,
      pm_lists: pm_list_rows.map { |row| row["thread_id"].to_s }.to_set,
      pm_list_rows: pm_list_rows,
      pm_indexes: pm_indexes,
    }
  end

  def verify_categories(source, category_imports)
    source_rows =
      source[:category_rows].reject { |row| row["type"] == "group" || row["status"].to_i == 2 }
    source_read_restricted =
      DiscuzCategoryPermissions.source_category_read_restrictions(
        source[:category_rows],
        medals_enabled: source[:medals_enabled],
      )
    target_rows =
      Category
        .where(id: category_imports.values)
        .pluck(:id, :name, :parent_category_id, :read_restricted)
        .to_h do |id, name, parent_id, read_restricted|
          [id, { name: name, parent_id: parent_id, read_restricted: read_restricted }]
        end
    permission_rows =
      CategoryGroup
        .joins(:group)
        .where(category_id: category_imports.values)
        .pluck(:category_id, "groups.name", :permission_type)
    target_permissions = Hash.new { |hash, key| hash[key] = {} }
    permission_rows.each do |category_id, group_name, permission_type|
      target_permissions[category_id][group_name] = permission_type
    end
    access_field_names = %w[
      discuz_viewperm_configured
      discuz_formulaperm_configured
      discuz_password_protected
      discuz_postperm_configured
      discuz_replyperm_configured
      discuz_user_view_overrides_present
    ]
    access_fields =
      CategoryCustomField
        .where(category_id: category_imports.values, name: access_field_names)
        .pluck(:category_id, :name, :value)
        .to_h { |category_id, name, value| [[category_id, name], value] }
    expected_names = expected_category_names(source_rows)
    name_mismatches = 0
    parent_mismatches = 0
    read_restriction_mismatches = 0
    read_restriction_mismatch_ids = []
    permission_mismatches = 0
    access_metadata_mismatches = 0
    restricted_categories = 0
    write_restricted_categories = 0
    categories_with_user_view_overrides = 0
    full_permission = CategoryGroup.permission_types[:full]
    readonly_permission = CategoryGroup.permission_types[:readonly]

    source_rows.each do |row|
      category_id = category_imports[row["id"].to_s]
      target = target_rows[category_id]
      next unless target

      expected_name = expected_names[row["id"].to_i]
      name_mismatches += 1 if target[:name] != expected_name
      expected_parent = category_imports[row["parent_id"].to_s] if row["parent_id"].to_i.positive?
      parent_mismatches += 1 if target[:parent_id] != expected_parent

      read_restricted = source_read_restricted[row["id"].to_i]
      write_restricted = DiscuzCategoryPermissions.write_restricted?(row)
      if target[:read_restricted] != read_restricted
        read_restriction_mismatches += 1
        read_restriction_mismatch_ids << row["id"].to_i
      end
      expected_permissions =
        if read_restricted
          restricted_categories += 1
          { "staff" => full_permission }
        elsif write_restricted
          write_restricted_categories += 1
          { "everyone" => readonly_permission, "staff" => full_permission }
        else
          {}
        end
      permission_mismatches += 1 if target_permissions[category_id] != expected_permissions

      expected_fields = {
        "discuz_viewperm_configured" => row["viewperm"].present?,
        "discuz_formulaperm_configured" => row["formulaperm"].present?,
        "discuz_password_protected" => row["forum_password"].present?,
        "discuz_postperm_configured" => row["postperm"].present?,
        "discuz_replyperm_configured" => row["replyperm"].present?,
        "discuz_user_view_overrides_present" => row["has_user_view_override"].to_i.positive?,
      }
      categories_with_user_view_overrides += 1 if expected_fields[
        "discuz_user_view_overrides_present"
      ]
      expected_fields.each do |name, expected|
        actual = truthy_field?(access_fields[[category_id, name]])
        access_metadata_mismatches += 1 if actual != expected
      end
    end

    {
      name_mismatches: name_mismatches,
      parent_mismatches: parent_mismatches,
      read_restriction_mismatches: read_restriction_mismatches,
      read_restriction_mismatch_ids: read_restriction_mismatch_ids,
      permission_mismatches: permission_mismatches,
      access_metadata_mismatches: access_metadata_mismatches,
      source_restricted_categories: restricted_categories,
      source_write_restricted_categories: write_restricted_categories,
      categories_with_user_view_overrides: categories_with_user_view_overrides,
      permission_mapping:
        "staff-only for restricted reads; public read-only for post/reply restrictions",
    }
  end

  def verify_sample_source_integrity(source)
    manifest_members = @sample_manifest.fetch("member_uids").map(&:to_s).to_set
    manifest_pm_participants =
      @sample_manifest.fetch("pm_declared_participant_uids").map(&:to_s).to_set
    manifest_required = @sample_manifest.fetch("required_uids").map(&:to_s).to_set
    manifest_placeholders = @sample_manifest.fetch("placeholder_uids").map(&:to_s).to_set
    manifest_categories = @sample_manifest.fetch("category_ids").map(&:to_s).to_set
    manifest_topics = @sample_manifest.fetch("topic_ids").map(&:to_i).to_set
    manifest_posts = @sample_manifest.fetch("post_ids").map(&:to_i).to_set
    manifest_pm_ids = @sample_manifest.fetch("pm_message_ids").map(&:to_i).to_set

    baseline = @sample_manifest.fetch("source_counts")
    baseline_count_mismatches = 0
    actual_baseline = {
      "members" => scalar("SELECT COUNT(*) count FROM (#{member_union}) members"),
      "categories" =>
        scalar(
          "SELECT COUNT(*) count FROM #{bbs("forum_forum")} WHERE type <> 'group' AND status <> 2",
        ),
      "threads" => scalar("SELECT COUNT(*) count FROM #{bbs("forum_thread")}"),
      "posts" => scalar("SELECT COUNT(*) count FROM #{bbs("forum_post")}"),
    }
    actual_baseline.each do |key, count|
      baseline_count_mismatches += 1 if count != baseline.fetch(key).to_i
    end
    expected_pm_shards = baseline.fetch("pm_messages_by_shard").transform_values(&:to_i)
    actual_pm_shards =
      (0..9).to_h do |shard|
        key = "pm_messages_#{shard}"
        [key, scalar("SELECT COUNT(*) count FROM #{uc(key)}")]
      end
    pm_baseline_count_mismatches =
      (expected_pm_shards.keys.to_set ^ actual_pm_shards.keys.to_set).length +
        (expected_pm_shards.keys.to_set & actual_pm_shards.keys.to_set).count do |key|
          expected_pm_shards[key] != actual_pm_shards[key]
        end
    source_posts =
      @source.query(post_source_sql, cache_rows: false).map { |row| row["id"].to_i }.to_set
    source_topics =
      rows("SELECT tid FROM #{bbs("forum_thread")} WHERE tid IN (#{sample_id_sql("topic_ids")})")
        .map { |row| row["tid"].to_i }
        .to_set
    source_pm_ids = source[:pm_rows].map { |row| row["id"].to_i }.to_set
    source_pm_participants =
      source[:pm_list_rows]
        .select { |row| row["pmtype"].to_i == 1 }
        .flat_map { |row| row["min_max"].to_s.split("_", -1) }
        .to_set
    actual_placeholders = source[:reference_ids] - source[:member_ids]
    pm_shard_mismatches = 0
    @sample_manifest
      .fetch("pm_shard_message_counts")
      .each do |shard, expected|
        raise "invalid PM shard in sample manifest" unless shard.match?(/\A[0-9]\z/)
        actual =
          scalar(
            "SELECT COUNT(*) count FROM #{uc("pm_messages_#{shard}")} WHERE plid IN (#{sample_id_sql("pm_thread_ids")})",
          )
        pm_shard_mismatches += 1 if actual != expected.to_i
      end

    mismatch_counts = {
      member_uid_mismatches:
        (manifest_members - source[:member_ids]).length +
          (source[:member_ids] - manifest_members).length,
      pm_declared_participant_uid_mismatches:
        (manifest_pm_participants - source_pm_participants).length +
          (source_pm_participants - manifest_pm_participants).length,
      required_uid_closure_mismatches:
        (manifest_required - (source[:member_ids] | source[:reference_ids])).length +
          ((source[:member_ids] | source[:reference_ids]) - manifest_required).length,
      placeholder_uid_mismatches:
        (manifest_placeholders - actual_placeholders).length +
          (actual_placeholders - manifest_placeholders).length,
      category_id_mismatches:
        (manifest_categories - source[:category_ids]).length +
          (source[:category_ids] - manifest_categories).length,
      topic_id_mismatches:
        (manifest_topics - source_topics).length + (source_topics - manifest_topics).length,
      post_id_mismatches:
        (manifest_posts - source_posts).length + (source_posts - manifest_posts).length,
      pm_message_id_mismatches:
        (manifest_pm_ids - source_pm_ids).length + (source_pm_ids - manifest_pm_ids).length,
      pm_shard_count_mismatches: pm_shard_mismatches,
      global_pm_baseline_count_mismatches: pm_baseline_count_mismatches,
      baseline_count_mismatches: baseline_count_mismatches,
    }
    mismatch_counts.merge(mismatch_count: mismatch_counts.values.sum)
  end

  def expected_category_names(source_rows)
    eligible = source_rows.reject { |row| row["type"] == "group" || row["status"].to_i == 2 }
    eligible_ids = eligible.map { |row| row["id"].to_i }.to_set
    existing_imported_ids = CategoryCustomField.where(name: "import_id").select(:category_id)
    reserved_root_names =
      Category
        .where(parent_category_id: nil)
        .where.not(id: existing_imported_ids)
        .pluck(:name)
        .map { |name| name.to_s.strip[0..49].downcase }
        .to_set
    groups =
      eligible.group_by do |row|
        parent_id = row["parent_id"].to_i
        parent_id = nil if eligible_ids.exclude?(parent_id)
        name = row["name"].to_s.strip
        name = "Blank" if name.empty?
        [parent_id, name[0..49].downcase]
      end
    groups.each_with_object({}) do |((parent_id, base_name), rows), expected|
      collision = rows.length > 1 || (parent_id.nil? && reserved_root_names.include?(base_name))
      rows.each do |row|
        name = row["name"].to_s.strip
        name = "Blank" if name.empty?
        name = name[0..49]
        if collision
          suffix = " [DZ #{row["id"]}]"
          name = name[0, 50 - suffix.length] + suffix
        end
        expected[row["id"].to_i] = name
      end
    end
  end

  def truthy_field?(value)
    %w[true t 1].include?(value.to_s.downcase)
  end

  def source_metrics(source)
    active_ids = rows("SELECT uid FROM #{bbs("common_member")}").map { |row| row["uid"].to_s }
    archive_ids =
      rows("SELECT uid FROM #{bbs("common_member_archive")}").map { |row| row["uid"].to_s }
    pm_shards =
      (0..9).to_h do |shard|
        table = uc("pm_messages_#{shard}")
        [shard, scalar("SELECT COUNT(*) count FROM #{table}")]
      end
    actual_pm_ids = source[:pm_rows].map { |row| row["id"].to_s }
    actual_pm_id_set = actual_pm_ids.to_set
    actual_first_ids = {}
    source[:pm_rows].each do |row|
      thread_id = row["thread_id"].to_s
      actual_first_ids[thread_id] = row["id"].to_i if !actual_first_ids.key?(thread_id) ||
        row["id"].to_i < actual_first_ids[thread_id]
    end
    index_first_ids = {}
    source[:pm_indexes].each do |row|
      thread_id = row["thread_id"].to_s
      index_first_ids[thread_id] = row["id"].to_i if !index_first_ids.key?(thread_id) ||
        row["id"].to_i < index_first_ids[thread_id]
    end
    stale_first_threads =
      actual_first_ids
        .keys
        .select do |thread_id|
          index_first_ids.key?(thread_id) &&
            index_first_ids[thread_id] != actual_first_ids[thread_id]
        end
        .to_set
    pm_message_counts = Hash.new(0)
    source[:pm_rows].each { |row| pm_message_counts[row["thread_id"].to_s] += 1 }
    indexed_pm_ids = source[:pm_indexes].map { |row| row["id"].to_s }.to_set
    participant_uids = source[:pm_members].map { |row| row["uid"].to_s }.to_set
    missing_pm_index_count = (actual_pm_id_set - indexed_pm_ids).length
    orphan_pm_index_count = (indexed_pm_ids - actual_pm_id_set).length
    post_summary = rows(<<~SQL).first
      SELECT COUNT(*) post_rows,
             SUM(thread.tid IS NULL) no_thread,
             SUM(thread.tid IS NOT NULL AND first_post.pid IS NULL) no_first_post,
             COUNT(DISTINCT CASE WHEN post.authorid IS NOT NULL AND member.uid IS NULL
                                 THEN post.authorid END) missing_author_uids,
             SUM(post.first <> 1 AND first_post.pid > post.pid) reply_before_first,
             SUM(post.first <> 1 AND post.invisible = 0 AND
                 (first_post.invisible <> 0 OR thread.displayorder < 0))
                 public_replies_under_nonpublic_first_posts,
             SUM(CHAR_LENGTH(TRIM(COALESCE(post.message, ''))) = 0 AND
                 EXISTS (SELECT 1 FROM #{bbs("forum_attachment")} attachment
                          WHERE attachment.pid = post.pid)) empty_posts_with_attachments
        FROM #{bbs("forum_post")} post
        LEFT JOIN #{bbs("forum_thread")} thread ON thread.tid = post.tid
        LEFT JOIN #{bbs("forum_post")} first_post
          ON first_post.tid = post.tid AND first_post.first = 1
        LEFT JOIN (#{member_union}) member ON member.uid = post.authorid
    SQL
    multiple_first_post_threads = scalar(<<~SQL)
      SELECT COUNT(*) count
        FROM (
          SELECT tid
            FROM #{bbs("forum_post")}
           WHERE first = 1
           GROUP BY tid
          HAVING COUNT(*) > 1
        ) duplicate_threads
    SQL

    {
      current_member_rows: active_ids.length,
      archived_member_rows: archive_ids.length,
      current_archive_uid_overlap: (active_ids & archive_ids).length,
      distinct_bbs_member_uids: source[:member_ids].length,
      bbs_members_with_blank_email:
        source[:members].count { |row| row["email"].nil? || row["email"].strip.empty? },
      duplicate_email_uid_count: source[:duplicate_email_uids].length,
      referenced_uids: source[:reference_ids].length,
      referenced_uids_without_bbs_member: (source[:reference_ids] - source[:member_ids]).length,
      post_source_rows: post_summary["post_rows"].to_i,
      posts_without_thread: post_summary["no_thread"].to_i,
      posts_without_first_post: post_summary["no_first_post"].to_i,
      post_author_uids_without_bbs_member: post_summary["missing_author_uids"].to_i,
      reply_rows_before_first_post_in_pid_order: post_summary["reply_before_first"].to_i,
      public_replies_under_nonpublic_first_posts:
        post_summary["public_replies_under_nonpublic_first_posts"].to_i,
      empty_posts_with_attachments: post_summary["empty_posts_with_attachments"].to_i,
      threads_with_multiple_first_posts: multiple_first_post_threads,
      imported_categories_expected: source[:category_ids].length,
      categories_excluded_by_importer: source[:category_rows].length - source[:category_ids].length,
      category_access:
        category_access_metrics(source[:category_rows], medals_enabled: source[:medals_enabled]),
      pm_messages_by_shard: pm_shards,
      pm_message_rows: source[:pm_rows].length,
      pm_index_rows: source[:pm_indexes].length,
      pm_message_ids_without_index: missing_pm_index_count,
      orphan_pm_index_rows: orphan_pm_index_count,
      duplicate_pm_message_ids: actual_pm_ids.length - actual_pm_id_set.length,
      pm_threads_with_stale_first_index: stale_first_threads.length,
      pm_messages_affected_by_stale_first_index:
        stale_first_threads.sum { |thread_id| pm_message_counts[thread_id] },
      pm_participant_uids_without_bbs_member: (participant_uids - source[:member_ids]).length,
      attachment_record_count: scalar("SELECT COUNT(*) count FROM #{bbs("forum_attachment")}"),
      avatar_user_count:
        scalar("SELECT COUNT(*) count FROM (#{member_union}) members WHERE avatarstatus = 1"),
      category_icon_count:
        scalar(
          "SELECT COUNT(*) count FROM #{bbs("forum_forumfield")} WHERE icon IS NOT NULL AND TRIM(icon) <> ''",
        ),
      pm_threads_missing_list_metadata:
        (source[:pm_rows].map { |row| row["thread_id"].to_s }.to_set - source[:pm_lists]).length,
    }
  end

  def category_access_metrics(rows, medals_enabled:)
    candidates = rows.reject { |row| row["type"] == "group" || row["status"].to_i == 2 }
    restricted = DiscuzCategoryPermissions.source_category_read_restrictions(rows, medals_enabled:)
    {
      effective_read_restricted: candidates.count { |row| restricted[row["id"].to_i] },
      categories_with_viewperm: candidates.count { |row| row["viewperm"].present? },
      categories_with_formulaperm: candidates.count { |row| row["formulaperm"].present? },
      categories_with_password: candidates.count { |row| row["forum_password"].present? },
      categories_with_post_or_reply_restrictions:
        candidates.count { |row| DiscuzCategoryPermissions.write_restricted?(row) },
      categories_with_user_view_overrides:
        candidates.count { |row| row["has_user_view_override"].to_i.positive? },
    }
  end

  def verify_posts(source, user_imports, category_imports)
    expected_ids = Set.new
    exclusion_counts = Hash.new(0)
    missing_count = 0
    unexpected_source_count = 0
    state_mismatch_count = 0
    hidden_source_count = 0
    hidden_public_count = 0
    hidden_public_posts = []
    relation_mismatches = Hash.new(0)
    target_topic_by_source_root = {}
    source_row_count = 0
    batch = []

    @source
      .query(post_source_sql, cache_rows: false)
      .each do |row|
        source_row_count += 1
        import_id = row["id"].to_i
        reason = post_exclusion_reason(row, user_imports, category_imports)
        expected = reason.nil?
        exclusion_counts[reason] += 1 if reason
        expected_ids.add(import_id) if expected
        hidden =
          row["invisible"].to_i != 0 || row["thread_status"].to_i < 0 ||
            row["first_post_status"].to_i != 0 ||
            (row["blank_message"].to_i == 1 && row["has_attachment"].to_i != 1)
        hidden_source_count += 1 if expected && hidden
        batch << { id: import_id, source: row, expected: expected, hidden: hidden }
        next if batch.length < 1_000

        counts =
          verify_post_batch(batch, user_imports, category_imports, target_topic_by_source_root)
        missing_count += counts.delete(:missing_count)
        unexpected_source_count += counts.delete(:unexpected_count)
        state_mismatch_count += counts.delete(:state_mismatch_count)
        hidden_public_count += counts.delete(:hidden_public_count)
        hidden_public_posts.concat(counts.delete(:hidden_public_posts))
        counts.each { |name, count| relation_mismatches[name] += count }
        batch.clear
      end

    unless batch.empty?
      counts = verify_post_batch(batch, user_imports, category_imports, target_topic_by_source_root)
      missing_count += counts.delete(:missing_count)
      unexpected_source_count += counts.delete(:unexpected_count)
      state_mismatch_count += counts.delete(:state_mismatch_count)
      hidden_public_count += counts.delete(:hidden_public_count)
      hidden_public_posts.concat(counts.delete(:hidden_public_posts))
      counts.each { |name, count| relation_mismatches[name] += count }
    end

    target_count = ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT COUNT(*)::bigint total_count,
             COUNT(DISTINCT value)::bigint unique_count
        FROM post_custom_fields
       WHERE name = 'import_id' AND value ~ '^[0-9]+$'
    SQL
    duplicate_count = target_count["total_count"].to_i - target_count["unique_count"].to_i
    unexpected_target_count = 0
    PostCustomField
      .where(name: "import_id")
      .where("value ~ '^[0-9]+$'")
      .find_each(batch_size: 10_000) do |field|
        unexpected_target_count += 1 if expected_ids.exclude?(field.value.to_i)
      end

    comparison = {
      expected_count: expected_ids.length,
      actual_count: target_count["unique_count"].to_i,
      missing_count: missing_count,
      unexpected_count: unexpected_source_count + unexpected_target_count,
      duplicate_source_import_id_count: duplicate_count,
    }
    failures = [
      comparison[:missing_count],
      comparison[:unexpected_count],
      comparison[:duplicate_source_import_id_count],
      state_mismatch_count,
      hidden_public_count,
      *relation_mismatches.values,
    ]

    {
      source_rows: source_row_count,
      expected_imported_rows: expected_ids.length,
      imported_discuz_post_ids: comparison[:actual_count],
      id_comparison: comparison,
      intentional_exclusions: exclusion_counts.sort.to_h,
      preserved_original_visibility_state_mismatches: state_mismatch_count,
      hidden_or_deleted_source_posts: hidden_source_count,
      hidden_or_deleted_posts_still_public: hidden_public_count,
      hidden_public_posts: hidden_public_posts,
      author_mismatches: relation_mismatches[:author_mismatches],
      topic_category_mismatches: relation_mismatches[:topic_category_mismatches],
      source_thread_mismatches: relation_mismatches[:source_thread_mismatches],
      created_at_mismatches: relation_mismatches[:created_at_mismatches],
      failure_count: failures.sum,
    }
  end

  def post_exclusion_reason(row, user_imports, category_imports)
    return "post_without_thread" if row["source_thread_id"].nil?
    return "post_without_first_post" if row["first_id"].nil?
    return "post_author_unmapped" unless user_imports.key?(row["user_id"].to_s)
    if row["is_first"].to_i != 1 && !user_imports.key?(row["first_user_id"].to_s)
      return "post_parent_author_unmapped"
    end
    return "post_category_unmapped" unless category_imports.key?(row["category_id"].to_s)

    nil
  end

  def verify_post_batch(batch, user_imports, category_imports, target_topic_by_source_root)
    ids = batch.map { |record| record[:id] }.uniq
    sql_ids = ids.map { |id| ActiveRecord::Base.connection.quote(id.to_s) }.join(",")
    sql = <<~SQL
      SELECT id_field.value import_id, p.deleted_at, p.topic_id, p.user_id,
             EXTRACT(EPOCH FROM p.created_at)::bigint created_epoch,
             t.category_id,
             invisible_field.value discuz_invisible,
             displayorder_field.value discuz_thread_displayorder
        FROM post_custom_fields id_field
        JOIN posts p ON p.id = id_field.post_id
        LEFT JOIN topics t ON t.id = p.topic_id
        LEFT JOIN post_custom_fields invisible_field
          ON invisible_field.post_id = p.id AND invisible_field.name = 'discuz_invisible'
        LEFT JOIN post_custom_fields displayorder_field
          ON displayorder_field.post_id = p.id
         AND displayorder_field.name = 'discuz_thread_displayorder'
       WHERE id_field.name = 'import_id' AND id_field.value IN (#{sql_ids})
    SQL
    imported_by_id =
      ActiveRecord::Base.connection.exec_query(sql).group_by { |row| row["import_id"].to_i }
    missing_count = 0
    unexpected_count = 0
    state_mismatch_count = 0
    hidden_public_count = 0
    hidden_public_posts = []
    author_mismatches = 0
    topic_category_mismatches = 0
    source_thread_mismatches = 0
    created_at_mismatches = 0

    batch.each do |record|
      target_rows = imported_by_id[record[:id]] || []
      if record[:expected]
        if target_rows.empty?
          missing_count += 1
          next
        end

        target = target_rows.first
        source = record[:source]
        state_mismatch_count += 1 if target["discuz_invisible"].to_i != source["invisible"].to_i ||
          target["discuz_thread_displayorder"].to_i != source["thread_status"].to_i
        if record[:hidden] && target["deleted_at"].nil?
          hidden_public_count += 1
          hidden_public_posts << {
            source_post_id: record[:id],
            invisible: source["invisible"].to_i,
            first_post_invisible: source["first_post_status"].to_i,
            thread_displayorder: source["thread_status"].to_i,
            blank_message: source["blank_message"].to_i == 1,
            has_attachment: source["has_attachment"].to_i == 1,
          }
        end
        expected_author_id = user_imports[source["user_id"].to_s]
        author_mismatches += 1 if (target["user_id"] || 0).to_i != expected_author_id.to_i
        expected_category_id = category_imports[source["category_id"].to_s]
        topic_category_mismatches += 1 if (target["category_id"] || 0).to_i !=
          expected_category_id.to_i
        created_at_mismatches += 1 if target["created_epoch"].to_i !=
          (source["created_at"] || 0).to_i

        if source["is_first"].to_i == 1
          target_topic_by_source_root[source["id"].to_i] = target["topic_id"].to_i
        else
          expected_topic_id = target_topic_by_source_root[source["first_id"].to_i]
          source_thread_mismatches += 1 if expected_topic_id.nil? ||
            target["topic_id"].to_i != expected_topic_id
        end
      elsif !target_rows.empty?
        unexpected_count += 1
      end
    end

    {
      missing_count: missing_count,
      unexpected_count: unexpected_count,
      state_mismatch_count: state_mismatch_count,
      hidden_public_count: hidden_public_count,
      hidden_public_posts: hidden_public_posts,
      author_mismatches: author_mismatches,
      topic_category_mismatches: topic_category_mismatches,
      source_thread_mismatches: source_thread_mismatches,
      created_at_mismatches: created_at_mismatches,
    }
  end

  def verify_private_messages(source, user_imports, imported_posts, duplicate_values)
    participant_ids = Hash.new { |hash, key| hash[key] = Set.new }
    source[:pm_members].each { |row| participant_ids[row["thread_id"].to_s].add(row["uid"].to_s) }
    list_ids = source[:pm_lists]
    first_message = {}
    source[:pm_rows].each do |row|
      thread_id = row["thread_id"].to_s
      first_message[thread_id] ||= row
      first_message[thread_id] = row if row["id"].to_i < first_message[thread_id]["id"].to_i
    end

    invalid_pair_threads = Set.new
    source[:pm_list_rows]
      .select { |row| row["pmtype"].to_i == 1 }
      .each do |row|
        thread_id = row["thread_id"].to_s
        pair = row["min_max"].to_s.split("_", -1)
        first_author = first_message[thread_id]&.fetch("user_id", nil).to_s
        unless pair.length == 2 && pair.all? { |uid| uid.match?(/\A[1-9][0-9]*\z/) } &&
                 pair.include?(first_author)
          invalid_pair_threads.add(thread_id)
          next
        end
        pair.each { |uid| participant_ids[thread_id].add(uid) }
      end

    unimportable_threads = Set.new
    exclusions = Hash.new(0)
    first_message.each do |thread_id, message|
      members = participant_ids[thread_id]
      if !list_ids.include?(thread_id)
        exclusions["pm_thread_metadata_missing"] += 1
        unimportable_threads.add(thread_id)
      elsif invalid_pair_threads.include?(thread_id)
        exclusions["pm_one_to_one_pair_invalid"] += 1
        unimportable_threads.add(thread_id)
      elsif members.empty?
        exclusions["pm_participants_missing"] += 1
        unimportable_threads.add(thread_id)
      elsif !user_imports.key?(message["user_id"].to_s)
        exclusions["pm_author_unmapped"] += 1
        unimportable_threads.add(thread_id)
      elsif members.any? { |uid| !user_imports.key?(uid) }
        exclusions["pm_participant_unmapped"] += 1
        unimportable_threads.add(thread_id)
      elsif members.all? { |uid| uid == message["user_id"].to_s }
        exclusions["pm_without_recipient"] += 1
        unimportable_threads.add(thread_id)
      end
    end

    expected_ids = Set.new
    expected_thread_participants = {}
    expected_thread_first_message = {}
    source[:pm_rows].each do |row|
      thread_id = row["thread_id"].to_s
      next if unimportable_threads.include?(thread_id)

      user_id = user_imports[row["user_id"].to_s]
      unless user_id
        exclusions["pm_message_author_unmapped"] += 1
        next
      end

      expected_ids.add("pm:#{row["id"]}")
      expected_thread_participants[thread_id] = (
        participant_ids[thread_id].map { |uid| user_imports[uid] } +
          [user_imports[first_message[thread_id]["user_id"].to_s]]
      ).compact.to_set
      expected_thread_first_message[thread_id] = "pm:#{first_message[thread_id]["id"]}"
    end

    target_pm = imported_posts.select { |import_id, _meta| import_id.start_with?("pm:") }
    pm_duplicate_values = duplicate_values.select { |import_id| import_id.start_with?("pm:") }
    comparison = compare_ids(expected_ids, target_pm.keys.to_set, pm_duplicate_values.length)
    topic_ids = target_pm.values.map { |meta| meta["topic_id"] }.compact.uniq
    allowed_users = Hash.new { |hash, key| hash[key] = Set.new }
    TopicAllowedUser
      .where(topic_id: topic_ids)
      .pluck(:topic_id, :user_id)
      .each { |topic_id, user_id| allowed_users[topic_id].add(user_id) }

    thread_topics = {}
    participant_mismatches = 0
    wrong_archetype_count = 0
    wrong_message_thread_count = 0
    wrong_message_author_count = 0
    wrong_message_created_at_count = 0

    expected_thread_participants.each do |thread_id, expected_participants|
      first_import_id = expected_thread_first_message[thread_id]
      first_post = target_pm[first_import_id]
      unless first_post
        participant_mismatches += 1
        next
      end

      thread_topics[thread_id] = first_post["topic_id"]
      wrong_archetype_count += 1 unless first_post["archetype"] == "private_message"
      actual_participants = allowed_users[first_post["topic_id"]].dup
      actual_participants.add(first_post["topic_user_id"].to_i)
      participant_mismatches += 1 unless actual_participants == expected_participants
    end

    source[:pm_rows].each do |row|
      import_id = "pm:#{row["id"]}"
      meta = target_pm[import_id]
      next unless meta && expected_ids.include?(import_id)

      expected_topic_id = thread_topics[row["thread_id"].to_s]
      wrong_message_thread_count += 1 if expected_topic_id && meta["topic_id"] != expected_topic_id
      expected_author_id = user_imports[row["user_id"].to_s]
      wrong_message_author_count += 1 if expected_author_id &&
        meta["user_id"].to_i != expected_author_id.to_i
      wrong_message_created_at_count += 1 if meta["created_epoch"].to_i !=
        (row["created_at"] || 0).to_i
    end

    failures = [
      comparison[:missing_count],
      comparison[:unexpected_count],
      comparison[:duplicate_source_import_id_count],
      source[:pm_rows].length - expected_ids.length,
      participant_mismatches,
      wrong_archetype_count,
      wrong_message_thread_count,
      wrong_message_author_count,
      wrong_message_created_at_count,
    ]

    {
      source_message_rows: source[:pm_rows].length,
      expected_imported_message_rows: expected_ids.length,
      imported_message_rows: target_pm.length,
      message_id_comparison: comparison,
      unimportable_source_threads: unimportable_threads.length,
      unimportable_thread_ids: unimportable_threads.map(&:to_i).sort,
      excluded_source_message_rows: source[:pm_rows].length - expected_ids.length,
      exclusion_reasons: exclusions.sort.to_h,
      participant_set_mismatches: participant_mismatches,
      non_private_message_topics: wrong_archetype_count,
      messages_in_wrong_topic: wrong_message_thread_count,
      messages_with_wrong_author: wrong_message_author_count,
      message_created_at_mismatches: wrong_message_created_at_count,
      failure_count: failures.sum,
    }
  end

  def verify_legacy_password_fields(_source, user_imports)
    sample_filter = " AND members.uid IN (#{sample_id_sql("member_uids")})" if @sample_manifest
    expected_uids = rows(<<~SQL).map { |row| row["uid"].to_s }.to_set
      SELECT members.uid
        FROM (#{member_union}) members
        JOIN #{uc("members")} uc ON uc.uid = members.uid
       WHERE COALESCE(uc.password, '') <> '' AND COALESCE(uc.salt, '') <> ''
       #{sample_filter}
    SQL
    target_user_ids = expected_uids.filter_map { |uid| user_imports[uid] }
    stored =
      UserCustomField
        .where(user_id: target_user_ids, name: %w[discuz_password_hash discuz_password_salt])
        .pluck(:user_id, :name)
        .group_by(&:first)
        .transform_values { |fields| fields.map(&:last).to_set }
    missing =
      target_user_ids.count do |user_id|
        !%w[discuz_password_hash discuz_password_salt].all? do |name|
          stored[user_id]&.include?(name)
        end
      end

    {
      source_accounts_with_hash_and_salt: expected_uids.length,
      mapped_accounts_with_hash_and_salt: target_user_ids.length,
      missing_hash_or_salt_count: missing + (expected_uids - user_imports.keys.to_set).length,
      verification: "field presence only; secret values are never selected or printed",
    }
  end

  def imported_values(model, foreign_key)
    pairs = model.where(name: "import_id").pluck(:value, foreign_key)
    grouped = pairs.group_by { |value, _id| value.to_s }
    mapping = grouped.transform_values { |entries| entries.first.last }
    duplicate_values = grouped.select { |_value, entries| entries.length > 1 }.keys.to_set
    [mapping, duplicate_values]
  end

  def imported_post_rows
    sql = <<~SQL
      SELECT p.id post_id, p.topic_id, p.user_id, p.deleted_at,
             EXTRACT(EPOCH FROM p.created_at)::bigint created_epoch,
             t.archetype, t.user_id topic_user_id,
             id_field.value import_id,
             invisible_field.value discuz_invisible,
             displayorder_field.value discuz_thread_displayorder
        FROM post_custom_fields id_field
        JOIN posts p ON p.id = id_field.post_id
        LEFT JOIN topics t ON t.id = p.topic_id
        LEFT JOIN post_custom_fields invisible_field
          ON invisible_field.post_id = p.id AND invisible_field.name = 'discuz_invisible'
        LEFT JOIN post_custom_fields displayorder_field
          ON displayorder_field.post_id = p.id
         AND displayorder_field.name = 'discuz_thread_displayorder'
       WHERE id_field.name = 'import_id' AND id_field.value LIKE 'pm:%'
    SQL
    rows =
      ActiveRecord::Base
        .connection
        .exec_query(sql)
        .to_a
        .select { |row| row["import_id"].to_s.match?(/\A(?:\d+|pm:\d+)\z/) }
    grouped = rows.group_by { |row| row["import_id"].to_s }
    mapping = grouped.transform_values(&:first)
    duplicate_values = grouped.select { |_id, matches| matches.length > 1 }.keys.to_set
    [mapping, duplicate_values]
  end

  def flagged_source_user_ids(field_name, user_imports)
    imported_id_by_target_id = user_imports.to_h { |source_id, target_id| [target_id, source_id] }
    UserCustomField
      .where(name: field_name)
      .pluck(:user_id, :value)
      .filter_map do |target_id, value|
        next if %w[true t 1].exclude?(value.to_s.downcase)

        imported_id_by_target_id[target_id]
      end
      .to_set
  end

  def compare_ids(expected, actual, duplicate_count = 0)
    {
      expected_count: expected.length,
      actual_count: actual.length,
      missing_count: (expected - actual).length,
      unexpected_count: (actual - expected).length,
      duplicate_source_import_id_count: duplicate_count,
    }
  end

  def bbs(table)
    qualified_table(@bbs_db, "#{@prefix}#{table}")
  end

  def uc(table)
    qualified_table(@uc_db, table)
  end

  def qualified_table(database, table)
    unless database.match?(/\A[a-zA-Z0-9_]+\z/) && table.match?(/\A[a-zA-Z0-9_]+\z/)
      raise "invalid SQL identifier"
    end

    "`#{database}`.`#{table}`"
  end

  def member_union
    active = bbs("common_member")
    archived = bbs("common_member_archive")

    <<~SQL
      SELECT uid, email, avatarstatus FROM #{active}
      UNION ALL
      SELECT archived.uid, archived.email, archived.avatarstatus
        FROM #{archived} archived
       WHERE NOT EXISTS (SELECT 1 FROM #{active} active WHERE active.uid = archived.uid)
    SQL
  end

  def referenced_uid_union
    pm_lists = uc("pm_lists")
    pm_authors =
      (0..9)
        .map { |shard| "SELECT DISTINCT authorid uid FROM #{uc("pm_messages_#{shard}")}" }
        .join("\nUNION\n")

    <<~SQL
      SELECT DISTINCT authorid uid FROM #{bbs("forum_post")}
      UNION
      SELECT DISTINCT uid FROM #{uc("pm_members")}
      UNION
      #{pm_authors}
      UNION
      SELECT CAST(SUBSTRING_INDEX(min_max, '_', 1) AS UNSIGNED) uid
        FROM #{pm_lists}
       WHERE pmtype = 1 AND min_max REGEXP '^[0-9]+_[0-9]+$'
      UNION
      SELECT CAST(SUBSTRING_INDEX(min_max, '_', -1) AS UNSIGNED) uid
        FROM #{pm_lists}
       WHERE pmtype = 1 AND min_max REGEXP '^[0-9]+_[0-9]+$'
    SQL
  end

  def sample_referenced_uid_union
    post_authors =
      "SELECT DISTINCT authorid uid FROM #{bbs("forum_post")} WHERE authorid > 0 AND tid IN (#{sample_id_sql("topic_ids")})"
    pm_authors =
      (0..9)
        .map do |shard|
          "SELECT DISTINCT authorid uid FROM #{uc("pm_messages_#{shard}")} WHERE authorid > 0 AND plid IN (#{sample_id_sql("pm_thread_ids")})"
        end
        .join("\nUNION\n")
    pm_members =
      "SELECT DISTINCT uid FROM #{uc("pm_members")} WHERE uid > 0 AND plid IN (#{sample_id_sql("pm_thread_ids")})"
    pm_lists = uc("pm_lists")
    pm_pair_participants = <<~SQL
      SELECT CAST(SUBSTRING_INDEX(min_max, '_', 1) AS UNSIGNED) uid
        FROM #{pm_lists}
       WHERE pmtype = 1 AND min_max REGEXP '^[0-9]+_[0-9]+$'
         AND plid IN (#{sample_id_sql("pm_thread_ids")})
      UNION
      SELECT CAST(SUBSTRING_INDEX(min_max, '_', -1) AS UNSIGNED) uid
        FROM #{pm_lists}
       WHERE pmtype = 1 AND min_max REGEXP '^[0-9]+_[0-9]+$'
         AND plid IN (#{sample_id_sql("pm_thread_ids")})
    SQL
    [post_authors, pm_members, pm_authors, pm_pair_participants].join("\nUNION\n")
  end

  def pm_message_union_sql
    (0..9)
      .map do |shard|
        filter = " WHERE plid IN (#{sample_id_sql("pm_thread_ids")})" if @sample_manifest
        "SELECT pmid id, plid thread_id, authorid user_id, dateline created_at FROM #{uc("pm_messages_#{shard}")}#{filter}"
      end
      .join("\nUNION ALL\n")
  end

  def post_source_sql
    <<~SQL
      SELECT post.pid id, post.tid thread_id, thread.tid source_thread_id,
             post.authorid user_id, post.invisible invisible,
             post.first is_first, post.dateline created_at,
             thread.displayorder thread_status,
             first_post.authorid first_user_id,
             first_post.invisible first_post_status,
             thread.fid category_id, first_post.pid first_id,
             EXISTS (
               SELECT 1 FROM #{bbs("forum_attachment")} attachment
                WHERE attachment.pid = post.pid
             ) has_attachment,
             CHAR_LENGTH(TRIM(COALESCE(post.message, ''))) = 0 blank_message
        FROM #{bbs("forum_post")} post
        LEFT JOIN #{bbs("forum_thread")} thread ON thread.tid = post.tid
        LEFT JOIN #{bbs("forum_post")} first_post
          ON first_post.tid = post.tid AND first_post.first = 1
       #{"WHERE thread.tid IN (#{sample_id_sql("topic_ids")})" if @sample_manifest}
       ORDER BY COALESCE(first_post.pid, post.pid) ASC,
                post.first DESC,
                post.pid ASC
    SQL
  end

  def rows(sql)
    @source.query(sql, cache_rows: false).to_a
  end

  def scalar(sql)
    rows(sql).first.fetch("count").to_i
  end
end

DiscuzImportVerifier.new.run
