#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "mysql2"
require "php_serialize"
require_relative "category_permissions"
require_relative "category_eligibility"
require_relative "medals"
require_relative "smilies"
require_relative "../../script/import_scripts/base"

class DiscuzImportVerifier
  ALLOWED_SAMPLE_DATABASES = %w[
    discourse_migration_sample
    discourse_migration_sample_uid18_20261013
    discourse_migration_sell_sample_20261018
    discourse_migration_sell_preview_20261018
    discourse_migration_sell_public_preview_20261018
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
      elsif ARGV.include?("--sample-attachments")
        :attachments
      elsif ARGV.include?("--sample-medals")
        :medals
      elsif ARGV.include?("--sample-sell")
        :sell
      elsif ARGV.include?("--sample-acceptance")
        :acceptance
      end

    connection.transaction do
      connection.execute("SET TRANSACTION READ ONLY")
      verify_local_target!(connection)
      report =
        if ARGV.include?("--source-preflight")
          source_preflight
        elsif sample_stage == :attachments
          verify_sample_attachments
        elsif sample_stage == :medals
          verify_discuz_medals(@sample_manifest.fetch("member_uids"), mode: "sample_discuz_medals")
        elsif sample_stage == :sell
          verify_sample_sell
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
      sell_post_ids
      sell_log_ids
      sell_buyer_uids
    ].each do |key|
      next unless manifest.key?(key)

      ids = manifest.fetch(key)
      unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(Integer) && id.positive? } &&
               ids.uniq.length == ids.length
        raise "invalid sample manifest IDs for #{key}"
      end
    end
    if manifest.key?("sell_section_ids")
      pairs = manifest.fetch("sell_section_ids")
      valid_pairs =
        pairs.is_a?(Array) &&
          pairs.all? do |pair|
            pair.is_a?(Array) && pair.length == 2 &&
              pair.all? { |id| id.is_a?(Integer) && id >= 0 } && pair.first.positive?
          end && pairs.uniq.length == pairs.length
      raise "invalid sample manifest IDs for sell_section_ids" unless valid_pairs
    end
    manifest
  rescue Errno::ENOENT
    raise "sample manifest does not exist"
  end

  def sample_id_sql(key)
    ids = @sample_manifest.fetch(key, []).map(&:to_i)
    ids.empty? ? "0" : ids.join(",")
  end

  def requested_attachment_ids
    raw_ids = ENV["DISCUZX_ATTACHMENT_IDS"].to_s.strip
    return [] if raw_ids.blank?

    ids = raw_ids.split(",").map(&:strip)
    unless ids.all? { |id| id.match?(/\A[1-9]\d*\z/) } && ids.uniq.length == ids.length
      raise "DISCUZX_ATTACHMENT_IDS must be a comma-separated list of unique positive integers"
    end

    ids.map(&:to_i)
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
        attachments:
          "COS objects can remain in place; metadata-only imports are checked against the relation-closed sample, while object availability and signed delivery need separate checks",
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
    email_conflict_remaps = flagged_source_user_ids("discuz_email_conflict", user_imports)
    email_confirmation_report =
      verify_email_confirmation(
        source,
        user_imports,
        expected_duplicate_emails,
        email_conflict_remaps,
      )
    provenance_report = verify_discuz_provenance(user_imports)
    avatar_report = verify_discuz_avatar_mapping(source, user_imports)
    expected_category_imports =
      category_imports.select { |source_id, _target_id| source[:category_ids].include?(source_id) }
    site_setup_report = verify_site_setup(expected_category_imports)

    category_comparison = compare_ids(source[:category_ids], expected_category_imports.keys.to_set)
    category_content_report = verify_categories(source, expected_category_imports)
    password_report = verify_legacy_password_fields(source, user_imports)
    sample_source_integrity = verify_sample_source_integrity(source)
    medal_report =
      if stage == :acceptance
        verify_discuz_medals(@sample_manifest.fetch("member_uids"), mode: "sample_discuz_medals")
      end
    sell_report =
      if stage == :acceptance && @sample_manifest.key?("sell_section_ids")
        verify_sample_sell
      elsif @sample_manifest.key?("sell_section_ids")
        { status: "deferred_until_sample_sell_stage" }
      end
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
      provenance_report[:mismatch_count],
      provenance_report[:unexpected_tagged_account_count],
      avatar_report[:failure_count],
      email_confirmation_report[:failure_count],
      site_setup_report[:failure_count],
      category_comparison[:missing_count],
      category_comparison[:unexpected_count],
      category_duplicate_values.length,
      category_content_report[:name_mismatches],
      category_content_report[:parent_mismatches],
      category_content_report[:read_restriction_mismatches],
      category_content_report[:permission_mismatches],
      category_content_report[:access_metadata_mismatches],
      category_content_report[:category_content_failure_count],
      password_report[:failure_count],
      sample_source_integrity[:mismatch_count],
      medal_report&.dig(:acceptance, :failure_count),
      sell_report&.dig(:acceptance, :failure_count),
    ]
    core_failures.compact!
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
        target_email_conflict_remap_count: email_conflict_remaps.length,
        email_confirmation: email_confirmation_report,
        provenance: provenance_report,
        avatar_mapping: avatar_report,
        legacy_auth: password_report,
      },
      site_setup: site_setup_report,
      categories: {
        imported_id_count: expected_category_imports.length,
        retained_excluded_mapping_count: category_imports.length - expected_category_imports.length,
        id_comparison: category_comparison,
        duplicate_import_id_count: category_duplicate_values.length,
        content_relationships: category_content_report,
      },
      posts: post_report || { status: "deferred_until_sample_content_stage" },
      private_messages: pm_report || { status: "deferred_until_sample_content_stage" },
      medals: medal_report || { status: "deferred_until_sample_medal_stage" },
      paid_sections: sell_report || { status: "deferred_until_sample_sell_stage" },
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

  def verify_sample_attachments
    raise "attachment verification requires DISCUZX_SAMPLE_MANIFEST" unless @sample_manifest

    source_post_ids = @sample_manifest.fetch("post_ids").map(&:to_i)
    post_filter = source_post_ids.empty? ? "0" : source_post_ids.join(",")
    requested_ids = requested_attachment_ids
    attachment_filter = " AND aid IN (#{requested_ids.join(",")})" if requested_ids.present?
    index_rows =
      rows(
        "SELECT aid, pid, tableid FROM #{bbs("forum_attachment")} " \
          "WHERE pid IN (#{post_filter})#{attachment_filter} ORDER BY aid",
      )
    source_details =
      index_rows
        .group_by { |row| row["tableid"].to_i }
        .flat_map do |table_id, entries|
          aid_filter = entries.map { |row| row["aid"].to_i }.join(",")
          rows(
            "SELECT aid, pid, tid, uid, dateline, filename, attachment, filesize, remote, " \
              "isimage, thumb, readperm, price FROM #{bbs("forum_attachment_#{table_id}")} " \
              "WHERE aid IN (#{aid_filter})",
          )
        end
    remote_source_count = source_details.count { |row| row["remote"].to_i == 1 }
    details_by_aid = source_details.index_by { |row| row["aid"].to_i }
    topic_ids = source_details.map { |row| row["tid"].to_i }.uniq
    topic_filter = topic_ids.empty? ? "0" : topic_ids.join(",")
    topic_prices =
      rows(
        "SELECT tid, price FROM #{bbs("forum_thread")} WHERE tid IN (#{topic_filter})",
      ).to_h { |row| [row["tid"].to_i, row["price"].to_i] }

    source_ids = index_rows.map { |row| row["aid"].to_i }.to_set
    source_duplicate_aid_count = index_rows.length - source_ids.length
    target_records =
      ::DiscourseDiscuzBbcode::Attachment
        .where(discuz_pid: source_post_ids)
        .then { |scope| requested_ids.present? ? scope.where(aid: requested_ids) : scope }
        .index_by { |record| record.aid.to_i }
    target_ids = target_records.keys.to_set
    post_imports, = imported_values(PostCustomField, :post_id)
    missing_count = (source_ids - target_ids).length
    missing_aids = source_ids - target_ids
    missing_source_pids =
      index_rows
        .filter_map { |row| row["pid"].to_i if missing_aids.include?(row["aid"].to_i) }
        .to_set
    unmapped_missing_source_pid_count =
      (missing_source_pids - post_imports.keys.map(&:to_i).to_set).length
    unexpected_count = (target_ids - source_ids).length
    missing_source_detail_count = source_ids.count { |aid| !details_by_aid.key?(aid) }
    metadata_mismatch_count = 0
    post_relation_mismatch_count = 0

    source_ids.each do |aid|
      source = details_by_aid[aid]
      target = target_records[aid]
      next unless source && target

      relative_path = source["attachment"].to_s
      expected_filename = source["filename"].to_s.presence || File.basename(relative_path)
      expected_post_id = post_imports[source["pid"].to_s]
      post_relation_mismatch_count += 1 if target.post_id.to_i != expected_post_id.to_i
      expected_values = {
        discuz_pid: source["pid"].to_i,
        discuz_tid: source["tid"].to_i,
        discuz_uid: source["uid"].to_i,
        object_key: "forum/#{relative_path}",
        filename: expected_filename,
        filesize: source["filesize"].to_i,
        is_image: source["isimage"].to_i == 1,
        has_thumbnail: source["thumb"].to_i == 1,
        is_remote: source["remote"].to_i == 1,
        readperm: source["readperm"].to_i,
        attachment_price: source["price"].to_i,
        topic_price: topic_prices.fetch(source["tid"].to_i, 0),
        uploaded_at: source["dateline"].to_i,
      }
      metadata_mismatch_count +=
        expected_values.count { |attribute, expected| target.public_send(attribute) != expected }
    end

    source_posts =
      rows("SELECT pid, message FROM #{bbs("forum_post")} WHERE pid IN (#{post_filter})")
    referenced_pairs =
      source_posts
        .flat_map do |post|
          post["message"]
            .to_s
            .scan(%r{\[attach\](\d+)\[/attach\]}i)
            .flatten
            .map { |aid| [post["pid"].to_i, aid.to_i] }
        end
        .select { |_source_pid, aid| requested_ids.blank? || requested_ids.include?(aid) }
    referenced_ids = referenced_pairs.map(&:last).uniq
    referenced_source_rows =
      if referenced_ids.empty?
        []
      else
        rows(
          "SELECT aid, pid FROM #{bbs("forum_attachment")} " \
            "WHERE aid IN (#{referenced_ids.join(",")})",
        )
      end
    referenced_source_by_aid = referenced_source_rows.index_by { |row| row["aid"].to_i }
    referenced_attachment_mismatch_count =
      referenced_pairs.count do |source_pid, aid|
        referenced_source_by_aid[aid].nil? ||
          referenced_source_by_aid[aid]["pid"].to_i != source_pid
      end
    referenced_attachment_absent_from_source_count =
      referenced_pairs.count { |_source_pid, aid| !referenced_source_by_aid.key?(aid) }
    referenced_attachment_wrong_post_count =
      referenced_attachment_mismatch_count - referenced_attachment_absent_from_source_count

    requested_ids_missing_from_sample_count = (requested_ids.to_set - source_ids).length
    failure_count =
      missing_count + unexpected_count + missing_source_detail_count + metadata_mismatch_count +
        post_relation_mismatch_count + unmapped_missing_source_pid_count +
        requested_ids_missing_from_sample_count
    source_reference_issue_count = referenced_attachment_mismatch_count

    {
      mode: "sample_attachment_metadata",
      source_attachment_count: source_ids.length,
      source_attachment_index_row_count: index_rows.length,
      source_remote_object_count: remote_source_count,
      source_local_flag_count: source_details.length - remote_source_count,
      duplicate_source_aid_count: source_duplicate_aid_count,
      source_posts_with_attachments: index_rows.map { |row| row["pid"].to_i }.uniq.length,
      posts_with_missing_target_attachment: missing_source_pids.length,
      missing_target_attachments_by_partition:
        index_rows
          .select { |row| missing_aids.include?(row["aid"].to_i) }
          .group_by { |row| row["tableid"].to_i }
          .transform_values(&:length),
      target_attachment_count: target_ids.length,
      inline_reference_count: referenced_pairs.length,
      missing_count: missing_count,
      missing_attachments_with_unmapped_post_count: unmapped_missing_source_pid_count,
      missing_attachments_with_mapped_post_count: missing_count - unmapped_missing_source_pid_count,
      unexpected_count: unexpected_count,
      missing_source_detail_count: missing_source_detail_count,
      metadata_mismatch_count: metadata_mismatch_count,
      post_relation_mismatch_count: post_relation_mismatch_count,
      referenced_attachment_mismatch_count: referenced_attachment_mismatch_count,
      referenced_attachment_absent_from_source_count:
        referenced_attachment_absent_from_source_count,
      referenced_attachment_wrong_post_count: referenced_attachment_wrong_post_count,
      requested_ids_missing_from_sample_count: requested_ids_missing_from_sample_count,
      binary_objects_read_or_copied: false,
      acceptance: {
        status:
          if failure_count.positive?
            "failed"
          elsif source_reference_issue_count.positive?
            "passed_with_source_reference_issues"
          else
            "passed"
          end,
        failure_count: failure_count,
        source_reference_issue_count: source_reference_issue_count,
      },
    }
  end

  def verify_sample_sell
    unless @sample_manifest&.key?("sell_section_ids")
      raise "paid-section verification requires a sell sample manifest"
    end

    manifest_post_ids = @sample_manifest.fetch("post_ids").map(&:to_i)
    candidates =
      rows(
        "SELECT post.pid, post.tid, post.authorid, post.message, COALESCE(thread.fid, 0) fid " \
          "FROM #{bbs("forum_post")} post " \
          "LEFT JOIN #{bbs("forum_thread")} thread ON thread.tid = post.tid " \
          "WHERE post.pid IN (#{sample_id_sql("post_ids")}) " \
          "AND LOCATE('[sell', LOWER(post.message)) > 0 ORDER BY post.pid",
      )
    source_sections = {}
    source_authors = {}
    sanitized_source_by_pid = {}
    candidates.each do |row|
      pid = row["pid"].to_i
      sanitized, parsed =
        DiscourseDiscuzBbcode::SellTagParser.extract(row["message"], discuz_pid: pid)
      next if parsed.empty?

      source_authors[pid] = row["authorid"].to_i
      sanitized_source_by_pid[pid] = sanitized
      parsed.each do |section|
        key = [pid, section.fetch(:section_index)]
        source_sections[key] = {
          author_uid: row["authorid"].to_i,
          discuz_fid: row["fid"].to_i,
          price: section.fetch(:price),
          credit_id: section.fetch(:credit_id),
          body: section.fetch(:body),
          attachment_aids:
            section
              .fetch(:body)
              .scan(%r{\[attach\](\d+)\[/attach\]}i)
              .flatten
              .map(&:to_i)
              .uniq
              .sort,
        }
      end
    end

    source_sell_post_ids = source_sections.keys.map(&:first).uniq.sort
    declared_sell_post_ids = @sample_manifest.fetch("sell_post_ids").map(&:to_i).sort
    source_section_ids = source_sections.keys.sort
    declared_section_ids =
      @sample_manifest.fetch("sell_section_ids").map { |pair| pair.map(&:to_i) }.sort
    source_logs =
      if source_sell_post_ids.empty?
        []
      else
        rows(
          "SELECT id, pid, cid, uid, dateline, pay, extcredit, authorid, authorincome " \
            "FROM #{bbs("dc_sell_log")} WHERE pid IN (#{source_sell_post_ids.join(",")}) ORDER BY id",
        )
      end
    valid_logs =
      source_logs.select do |row|
        key = [row["pid"].to_i, row["cid"].to_i]
        section = source_sections[key]
        next false unless section && row["uid"].to_i.positive?
        if row["authorid"].to_i.positive? && row["authorid"].to_i != section[:author_uid]
          raise "source paid-section purchase author mismatch"
        end
        true
      end
    source_log_ids = valid_logs.map { |row| row["id"].to_i }.sort
    declared_log_ids = @sample_manifest.fetch("sell_log_ids").map(&:to_i).sort
    source_buyer_uids = valid_logs.map { |row| row["uid"].to_i }.uniq.sort
    declared_buyer_uids = @sample_manifest.fetch("sell_buyer_uids").map(&:to_i).sort
    source_attachment_rows =
      source_sections
        .flat_map do |(pid, section_index), section|
          section[:attachment_aids].map do |aid|
            { "discuz_pid" => pid, "section_index" => section_index, "aid" => aid }
          end
        end
        .sort_by { |row| [row["discuz_pid"], row["section_index"], row["aid"]] }
    declared_attachments = @sample_manifest.fetch("sell_attachment_aids", [])
    declared_attachments =
      declared_attachments.sort_by do |row|
        [row.fetch("discuz_pid").to_i, row.fetch("section_index").to_i, row.fetch("aid").to_i]
      end

    post_import_rows =
      PostCustomField.where(name: "import_id", value: source_sell_post_ids.map(&:to_s)).pluck(
        :value,
        :post_id,
      )
    post_by_source_id =
      post_import_rows.to_h do |source_id, target_id|
        [source_id.to_i, Post.with_deleted.find_by(id: target_id)]
      end
    target_sections =
      ::DiscourseDiscuzBbcode::SellSection
        .where(discuz_pid: source_sell_post_ids)
        .order(:discuz_pid, :section_index)
        .to_a
    target_by_key =
      target_sections.index_by { |section| [section.discuz_pid.to_i, section.section_index.to_i] }
    target_purchases =
      ::DiscourseDiscuzBbcode::SellPurchase
        .where(source_log_id: source_log_ids)
        .order(:source_log_id)
        .to_a
    target_purchase_by_log = target_purchases.index_by { |purchase| purchase.source_log_id.to_i }
    user_imports =
      UserCustomField
        .where(
          name: "import_id",
          value: (source_buyer_uids + source_authors.values).uniq.map(&:to_s),
        )
        .pluck(:value, :user_id)
        .to_h { |source_uid, user_id| [source_uid.to_i, user_id.to_i] }

    post_marker_mismatches = 0
    leaked_body_count = 0
    author_mapping_mismatches = 0
    marker_issue_keys = []
    possible_leak_section_keys = []
    source_sections.each do |(pid, section_index), source_section|
      post = post_by_source_id[pid]
      unless post
        post_marker_mismatches += 1
        marker_issue_keys << [pid, section_index, "post_missing"]
        next
      end
      marker = DiscourseDiscuzBbcode::SellTagParser.marker(pid, section_index)
      marker_count = post.raw.scan(Regexp.new(Regexp.escape(marker), Regexp::IGNORECASE)).length
      has_sell_open = post.raw.match?(/\[sell\s*=/i)
      if marker_count != 1 || has_sell_open
        post_marker_mismatches += 1
        marker_issue_keys << [pid, section_index, marker_count, has_sell_open]
      end
      if source_section[:body].strip.length >= 24 && post.raw.include?(source_section[:body]) &&
           !sanitized_source_by_pid.fetch(pid).include?(source_section[:body])
        leaked_body_count += 1
        possible_leak_section_keys << [pid, section_index, source_section[:body].bytesize]
      end
      target = target_by_key[[pid, section_index]]
      next unless target
      expected_author_user_id = user_imports[source_section[:author_uid]]
      author_mapping_mismatches += 1 if target.author_uid.to_i != source_section[:author_uid]
      author_mapping_mismatches += 1 if target.author_user_id.to_i != post.user_id.to_i
      author_mapping_mismatches += 1 if expected_author_user_id &&
        post.user_id.to_i != expected_author_user_id
    end

    section_field_mismatches = 0
    source_sections.each do |key, source_section|
      target = target_by_key[key]
      next unless target
      section_field_mismatches += 1 if target.price.to_i != source_section[:price]
      section_field_mismatches += 1 if target.credit_id.to_i != source_section[:credit_id]
      section_field_mismatches += 1 if target.discuz_fid.to_i != source_section[:discuz_fid]
      credit_type = source_discuz_credit_types[source_section[:credit_id]] || {}
      expected_title = credit_type[:title].presence || "积分 #{source_section[:credit_id]}"
      section_field_mismatches += 1 if target.credit_title.to_s != expected_title
      section_field_mismatches += 1 if target.credit_unit.to_s != credit_type[:unit].to_s
      section_field_mismatches += 1 if Array(target.attachment_aids).map(&:to_i).uniq.sort !=
        source_section[:attachment_aids]
      section_field_mismatches += 1 if target.body.blank?
    end

    purchase_field_mismatches = 0
    valid_logs.each do |source_log|
      target = target_purchase_by_log[source_log["id"].to_i]
      unless target
        purchase_field_mismatches += 1
        next
      end
      source_uid = source_log["uid"].to_i
      source_pid = source_log["pid"].to_i
      source_cid = source_log["cid"].to_i
      expected_author_uid = source_sections.fetch([source_pid, source_cid]).fetch(:author_uid)
      target_user_id = user_imports[source_uid]
      purchase_field_mismatches += 1 if target.discuz_uid.to_i != source_uid
      purchase_field_mismatches += 1 if target.user_id.to_i != target_user_id.to_i
      purchase_field_mismatches += 1 if target.discuz_pid.to_i != source_pid
      purchase_field_mismatches += 1 if target.section_index.to_i != source_cid
      purchase_field_mismatches += 1 if target.author_uid.to_i != expected_author_uid
      purchase_field_mismatches += 1 if target.paid_amount.to_i != source_log["pay"].to_i
      purchase_field_mismatches += 1 if target.credit_id.to_i != source_log["extcredit"].to_i
      purchase_field_mismatches += 1 if target.author_income.to_i != source_log["authorincome"].to_i
      purchase_field_mismatches += 1 if target.purchased_at.to_i != source_log["dateline"].to_i
    end

    target_attachment_aids =
      target_sections.flat_map { |section| Array(section.attachment_aids).map(&:to_i) }.uniq
    imported_attachment_aids =
      ::DiscourseDiscuzBbcode::Attachment
        .where(aid: target_attachment_aids)
        .pluck(:aid)
        .map(&:to_i)
        .to_set
    missing_attachment_metadata_count =
      (target_attachment_aids.to_set - imported_attachment_aids).length

    permission_matrix =
      verify_sell_access_matrix(target_sections, target_purchases, post_by_source_id)
    manifest_mismatch_count =
      symmetric_difference_count(source_sell_post_ids, declared_sell_post_ids) +
        symmetric_difference_count(source_section_ids, declared_section_ids) +
        symmetric_difference_count(source_log_ids, declared_log_ids) +
        symmetric_difference_count(source_buyer_uids, declared_buyer_uids) +
        (source_attachment_rows == declared_attachments ? 0 : 1) +
        (manifest_post_ids.include?(@sample_manifest.fetch("sell_candidate_post_id").to_i) ? 0 : 1)
    target_count_mismatches =
      symmetric_difference_count(source_section_ids, target_by_key.keys.sort) +
        symmetric_difference_count(source_log_ids, target_purchase_by_log.keys.sort)
    financial_import = verify_sell_financial_import(@sample_manifest.fetch("member_uids"))
    failure_count =
      manifest_mismatch_count + target_count_mismatches + post_marker_mismatches +
        leaked_body_count + author_mapping_mismatches + section_field_mismatches +
        purchase_field_mismatches + missing_attachment_metadata_count +
        permission_matrix[:failure_count] + financial_import[:failure_count]

    {
      mode: "sample_discuz_paid_sections",
      source_sell_post_count: source_sell_post_ids.length,
      source_section_count: source_sections.length,
      source_valid_purchase_count: source_log_ids.length,
      source_orphan_purchase_count: source_logs.length - valid_logs.length,
      source_buyer_count: source_buyer_uids.length,
      protected_attachment_count: target_attachment_aids.length,
      target_section_count: target_sections.length,
      target_purchase_count: target_purchases.length,
      manifest_mismatch_count: manifest_mismatch_count,
      target_count_mismatches: target_count_mismatches,
      post_marker_mismatches: post_marker_mismatches,
      post_marker_issue_keys: marker_issue_keys,
      possible_plain_body_leaks: leaked_body_count,
      possible_plain_body_leak_section_keys: possible_leak_section_keys,
      author_mapping_mismatches: author_mapping_mismatches,
      section_field_mismatches: section_field_mismatches,
      purchase_field_mismatches: purchase_field_mismatches,
      missing_protected_attachment_metadata: missing_attachment_metadata_count,
      financial_import: financial_import.except(:failure_count),
      access_matrix: permission_matrix[:results],
      acceptance: {
        status: failure_count.zero? ? "passed" : "failed",
        failure_count: failure_count,
      },
    }
  end

  def verify_sell_access_matrix(sections, purchases, posts_by_source_id)
    section =
      sections.find do |candidate|
        purchases.any? do |purchase|
          purchase.discuz_pid.to_i == candidate.discuz_pid.to_i &&
            purchase.section_index.to_i == candidate.section_index.to_i
        end
      end
    unless section
      return { failure_count: 1, results: { status: "no_purchased_section_available" } }
    end

    guardian_class =
      Struct.new(:staff) do
        def is_staff?
          staff
        end
      end
    purchase =
      purchases.find do |candidate|
        candidate.discuz_pid.to_i == section.discuz_pid.to_i &&
          candidate.section_index.to_i == section.section_index.to_i
      end
    author = posts_by_source_id[section.discuz_pid.to_i]&.user
    buyer = User.find_by(id: purchase.user_id)
    purchaser_ids =
      purchases
        .select do |candidate|
          candidate.discuz_pid.to_i == section.discuz_pid.to_i &&
            candidate.section_index.to_i == section.section_index.to_i
        end
        .map(&:user_id)
        .compact
        .to_set
    free_group_ids =
      DiscourseDiscuzBbcode::SellAccess.parse_ids(
        SiteSetting.discourse_discuz_bbcode_sell_free_group_ids,
      )
    unrelated_candidates =
      UserCustomField
        .where(name: "discuz_source", value: "discuz_x3.5")
        .where.not(user_id: purchaser_ids.to_a + [author&.id].compact)
    free_group_user_ids =
      UserCustomField.where(name: "discuz_group_id", value: free_group_ids.map(&:to_s)).select(
        :user_id,
      )
    unrelated_id =
      unrelated_candidates.where.not(user_id: free_group_user_ids).limit(1).pick(:user_id)
    unrelated = User.find_by(id: unrelated_id) if unrelated_id
    guardian = guardian_class.new(false)
    results = {
      anonymous_denied: !DiscourseDiscuzBbcode::SellAccess.allowed?(section, nil, guardian),
      author_allowed:
        author && DiscourseDiscuzBbcode::SellAccess.allowed?(section, author, guardian),
      buyer_allowed: buyer && DiscourseDiscuzBbcode::SellAccess.allowed?(section, buyer, guardian),
      unrelated_user_denied:
        unrelated && !DiscourseDiscuzBbcode::SellAccess.allowed?(section, unrelated, guardian),
      staff_allowed:
        DiscourseDiscuzBbcode::SellAccess.allowed?(section, nil, guardian_class.new(true)),
    }
    required_results = results.reject { |key, _| key == :unrelated_user_denied }
    failure_count = required_results.count { |_key, value| value != true }
    failure_count += 1 if unrelated && results[:unrelated_user_denied] != true
    { failure_count: failure_count, results: results }
  end

  def verify_sell_financial_import(source_uids)
    source_settings_rows =
      rows(
        "SELECT variable, value FROM #{bbs("common_pluginvar")} " \
          "WHERE pluginid = (SELECT pluginid FROM #{bbs("common_plugin")} " \
          "WHERE identifier = 'dc_sell' LIMIT 1) " \
          "AND variable IN ('open', 'fids', 'free', 'maxprice', 'salestax')",
      )
    source_settings = source_settings_rows.to_h { |row| [row["variable"], row["value"]] }
    source_open = source_settings.fetch("open", "0").to_i == 1
    expected_tax = source_settings.fetch("salestax", "0").to_i
    expected_max_price = source_settings.fetch("maxprice", "100").to_i
    expected_free_group_ids = unserialize_discuz_ids(source_settings.fetch("free", ""))
    expected_forum_ids = unserialize_discuz_ids(source_settings.fetch("fids", ""))
    settings_mismatches = 0
    settings_mismatches += 1 if !SiteSetting.discourse_discuz_bbcode_sell_source_configured
    settings_mismatches += 1 if SiteSetting.discourse_discuz_bbcode_sell_source_open != source_open
    settings_mismatches += 1 if SiteSetting.discourse_discuz_bbcode_sell_purchase_enabled !=
      source_open
    settings_mismatches += 1 if SiteSetting.discourse_discuz_bbcode_sell_tax_percent.to_i !=
      expected_tax
    settings_mismatches += 1 if SiteSetting.discourse_discuz_bbcode_sell_max_price.to_i !=
      expected_max_price
    settings_mismatches += 1 if DiscourseDiscuzBbcode::SellAccess.parse_ids(
      SiteSetting.discourse_discuz_bbcode_sell_free_group_ids,
    ) != expected_free_group_ids
    settings_mismatches += 1 if DiscourseDiscuzBbcode::SellAccess.parse_ids(
      SiteSetting.discourse_discuz_bbcode_sell_forum_ids,
    ) != expected_forum_ids

    uids = source_uids.map(&:to_i).select(&:positive?).uniq
    if uids.empty?
      return(
        {
          failure_count: settings_mismatches + 1,
          source_user_count: 0,
          balance_mismatches: 0,
          group_mismatches: 0,
          settings_mismatches: settings_mismatches,
        }
      )
    end

    credit_columns =
      (1..8).map { |id| "COALESCE(counts.extcredits#{id}, 0) extcredits#{id}" }.join(", ")
    source_rows =
      rows(
        "SELECT members.uid, members.groupid group_id, #{credit_columns} " \
          "FROM (SELECT uid, groupid FROM #{bbs("common_member")} " \
          "UNION ALL SELECT archived.uid, archived.groupid FROM #{bbs("common_member_archive")} archived " \
          "WHERE NOT EXISTS (SELECT 1 FROM #{bbs("common_member")} active " \
          "WHERE active.uid = archived.uid)) members " \
          "LEFT JOIN #{bbs("common_member_count")} counts USING(uid) " \
          "WHERE members.uid IN (#{uids.join(",")}) ORDER BY members.uid",
      )
    source_by_uid = source_rows.index_by { |row| row["uid"].to_i }
    imports =
      UserCustomField.where(name: "import_id", value: uids.map(&:to_s)).pluck(:value, :user_id)
    target_by_uid = imports.group_by { |source_uid, _user_id| source_uid.to_i }
    target_user_ids = imports.map { |_source_uid, user_id| user_id.to_i }.uniq
    target_balances =
      ::DiscourseDiscuzBbcode::SellCreditBalance
        .where(user_id: target_user_ids)
        .pluck(:user_id, :credit_id, :balance)
        .to_h { |user_id, credit_id, balance| [[user_id.to_i, credit_id.to_i], balance.to_i] }
    target_groups =
      UserCustomField
        .where(user_id: target_user_ids, name: "discuz_group_id")
        .pluck(:user_id, :value)
        .to_h { |user_id, group_id| [user_id.to_i, group_id.to_i] }
    balance_mismatches = 0
    group_mismatches = 0

    source_by_uid.each do |uid, source_row|
      matches = target_by_uid.fetch(uid, [])
      if matches.length != 1
        balance_mismatches += 8
        group_mismatches += 1
        next
      end

      user_id = matches.first.last.to_i
      group_mismatches += 1 if target_groups[user_id].to_i != source_row["group_id"].to_i
      (1..8).each do |credit_id|
        expected = source_row["extcredits#{credit_id}"].to_i
        actual = target_balances[[user_id, credit_id]]
        balance_mismatches += 1 if actual != expected
      end
    end

    {
      failure_count: settings_mismatches + balance_mismatches + group_mismatches,
      source_user_count: source_by_uid.length,
      balance_mismatches: balance_mismatches,
      group_mismatches: group_mismatches,
      settings_mismatches: settings_mismatches,
    }
  end

  def source_discuz_credit_types
    return @source_discuz_credit_types if defined?(@source_discuz_credit_types)

    row =
      rows("SELECT svalue FROM #{bbs("common_setting")} WHERE skey = 'extcredits' LIMIT 1").first
    definitions = row && PHP.unserialize(row["svalue"].to_s)
    @source_discuz_credit_types =
      if definitions.is_a?(Hash)
        definitions.each_with_object({}) do |(id, definition), result|
          credit_id = id.to_i
          next unless credit_id.between?(1, 8) && definition.is_a?(Hash)

          definition = definition.transform_keys(&:to_s)
          result[credit_id] = {
            title: definition["title"].to_s.strip,
            unit: definition["unit"].to_s.strip,
          }
        end
      else
        {}
      end
  end

  def unserialize_discuz_ids(value)
    decoded = PHP.unserialize(value.to_s)
    values = decoded.is_a?(Hash) ? decoded.values : Array(decoded)
    values
      .filter_map do |item|
        text = item.to_s
        text.to_i if text.match?(/\A\d+\z/) && text.to_i.positive?
      end
      .uniq
      .sort
  end

  def symmetric_difference_count(left, right)
    left_set = left.to_set
    right_set = right.to_set
    (left_set - right_set).length + (right_set - left_set).length
  end

  def verify_discuz_medals(source_uids, mode:)
    if mode == "sample_discuz_medals" && @sample_manifest.nil?
      raise "sample medal verification requires DISCUZX_SAMPLE_MANIFEST"
    end

    source_uids = source_uids.map(&:to_i).uniq.sort
    definitions =
      rows("SELECT medalid, name, description, image, available FROM #{bbs("forum_medal")}")
    definitions_by_id = definitions.index_by { |row| row["medalid"].to_i }

    target_mappings = ::DiscourseDiscuzMedals::MedalMapping.includes(:badge).to_a
    mappings_by_id = target_mappings.index_by { |mapping| mapping.discuz_medalid.to_i }
    source_definition_ids = definitions_by_id.keys.to_set
    target_mapping_ids = mappings_by_id.keys.to_set
    missing_definition_count = (source_definition_ids - target_mapping_ids).length
    duplicate_mapping_count = target_mappings.length - target_mapping_ids.length
    retired_active_mapping_count =
      target_mappings.count do |mapping|
        !source_definition_ids.include?(mapping.discuz_medalid.to_i) &&
          (mapping.source_available || mapping.badge&.enabled?)
      end

    definition_metadata_mismatch_count = 0
    badge_definition_mismatch_count = 0
    definitions.each do |definition|
      medalid = definition["medalid"].to_i
      mapping = mappings_by_id[medalid]
      next unless mapping

      expected_name = definition["name"].to_s.presence || "Discuz 勋章 #{medalid}"
      expected_available = definition["available"].to_i == 1
      if mapping.source_name != expected_name ||
           mapping.source_description != definition["description"].to_s ||
           mapping.source_image != definition["image"].to_s ||
           mapping.source_available != expected_available
        definition_metadata_mismatch_count += 1
      end

      badge = mapping.badge
      if badge.nil? || badge.name != DiscuzMigration::Medals.badge_name(medalid, expected_name) ||
           badge.enabled? != expected_available
        badge_definition_mismatch_count += 1
      end
    end

    imported_users_by_uid = Hash.new { |hash, uid| hash[uid] = [] }
    source_uids.each_slice(1_000) do |uid_batch|
      UserCustomField
        .where(name: "import_id", value: uid_batch.map(&:to_s))
        .pluck(:value, :user_id)
        .each { |value, user_id| imported_users_by_uid[value.to_i] << user_id.to_i }
    end
    duplicate_user_uid_count =
      imported_users_by_uid.count { |_uid, user_ids| user_ids.uniq.length > 1 }
    uid_to_user =
      imported_users_by_uid
        .filter_map { |uid, user_ids| [uid, user_ids.first] if user_ids.uniq.length == 1 }
        .to_h
    missing_user_count = (source_uids - uid_to_user.keys).length

    source_user_ids = uid_to_user.values.uniq
    source_markers = {}
    source_user_ids.each_slice(1_000) do |user_id_batch|
      UserCustomField
        .where(user_id: user_id_batch, name: %w[discuz_source discuz_uid])
        .pluck(:user_id, :name, :value)
        .each { |user_id, name, value| source_markers[[user_id.to_i, name]] = value.to_s }
    end
    marker_mismatch_count =
      uid_to_user.count do |uid, user_id|
        source_markers[[user_id, "discuz_source"]] != "discuz_x3.5" ||
          source_markers[[user_id, "discuz_uid"]] != uid.to_s
      end

    source_memberships = {}
    expired_assignment_count = 0
    malformed_token_count = 0
    source_uids.each_slice(1_000) do |uid_batch|
      next if uid_batch.empty?

      rows(
        "SELECT uid, medals FROM #{bbs("common_member_field_forum")} " \
          "WHERE uid IN (#{uid_batch.join(",")})",
      ).each do |row|
        parsed = DiscuzMigration::Medals.parse_memberships(row["medals"], now_epoch: Time.now.to_i)
        uid = row["uid"].to_i
        source_memberships[uid] = parsed[:assignments]
        expired_assignment_count += parsed[:expired_count]
        malformed_token_count += parsed[:malformed_count]
      end
    end

    expected_pairs = Set.new
    expected_expiration_by_pair = {}
    unavailable_assignment_count = 0
    undefined_assignment_count = 0
    source_memberships.each do |uid, assignments|
      assignments.each do |assignment|
        definition = definitions_by_id[assignment[:medalid]]
        if definition.nil?
          undefined_assignment_count += 1
        elsif definition["available"].to_i != 1
          unavailable_assignment_count += 1
        else
          pair = [uid, assignment[:medalid]]
          expected_pairs << pair
          expected_expiration_by_pair[pair] = assignment[:expiration]
        end
      end
    end

    source_award_dates = {}
    pairs_by_uid = expected_pairs.group_by(&:first)
    pairs_by_uid
      .keys
      .sort
      .each_slice(1_000) do |uid_batch|
        batch_pairs = uid_batch.flat_map { |uid| pairs_by_uid.fetch(uid) }
        medal_ids = batch_pairs.map(&:last).uniq.sort
        next if medal_ids.empty?

        rows(
          "SELECT uid, medalid, MAX(dateline) dateline FROM #{bbs("forum_medallog")} " \
            "WHERE uid IN (#{uid_batch.join(",")}) AND medalid IN (#{medal_ids.join(",")}) " \
            "AND type IN (0, 1) GROUP BY uid, medalid",
        ).each do |row|
          dateline = row["dateline"].to_i
          source_award_dates[
            [row["uid"].to_i, row["medalid"].to_i]
          ] = dateline if dateline.positive?
        end
      end

    imported_grants =
      source_uids
        .each_slice(1_000)
        .flat_map do |uid_batch|
          ::DiscourseDiscuzMedals::UserMedalGrant.where(discuz_uid: uid_batch).to_a
        end
    actual_grant_pairs =
      imported_grants.map { |grant| [grant.discuz_uid.to_i, grant.discuz_medalid.to_i] }.to_set
    duplicate_grant_count = imported_grants.length - actual_grant_pairs.length
    grant_pair_comparison = compare_ids(expected_pairs, actual_grant_pairs)

    mapping_badge_ids = mappings_by_id.transform_values { |mapping| mapping.badge_id.to_i }
    grant_ownership_mismatch_count = 0
    expiration_mismatch_count = 0
    source_award_date_mismatch_count = 0
    imported_grants.each do |grant|
      pair = [grant.discuz_uid.to_i, grant.discuz_medalid.to_i]
      expected_user_id = uid_to_user[pair.first]
      expected_badge_id = mapping_badge_ids[pair.last]
      if grant.user_id.to_i != expected_user_id || grant.badge_id.to_i != expected_badge_id
        grant_ownership_mismatch_count += 1
      end
      if expected_expiration_by_pair.key?(pair) &&
           grant.source_expiration_at.to_i != expected_expiration_by_pair[pair].to_i
        expiration_mismatch_count += 1
      end
      if expected_pairs.include?(pair) && grant.source_awarded_at&.to_i != source_award_dates[pair]
        source_award_date_mismatch_count += 1
      end
    end

    reverse_uid_map = uid_to_user.invert
    reverse_badge_map = mapping_badge_ids.invert
    native_badge_rows = []
    native_badge_ids = mapping_badge_ids.values.uniq
    if native_badge_ids.present?
      source_user_ids.each_slice(1_000) do |user_id_batch|
        native_badge_rows.concat(
          UserBadge.where(user_id: user_id_batch, badge_id: native_badge_ids).pluck(
            :user_id,
            :badge_id,
            :post_id,
          ),
        )
      end
    end

    native_pairs = Set.new
    unmapped_native_badge_count = 0
    post_specific_native_badge_count = 0
    native_badge_rows.each do |user_id, badge_id, post_id|
      uid = reverse_uid_map[user_id.to_i]
      medalid = reverse_badge_map[badge_id.to_i]
      if uid.nil? || medalid.nil?
        unmapped_native_badge_count += 1
        next
      end
      native_pairs << [uid, medalid]
      post_specific_native_badge_count += 1 if post_id.present?
    end
    native_pair_comparison = compare_ids(expected_pairs, native_pairs)

    target_users = User.where(id: source_user_ids).index_by(&:id)
    native_user_badges = {}
    if native_badge_ids.present?
      source_user_ids.each_slice(1_000) do |user_id_batch|
        UserBadge
          .where(user_id: user_id_batch, badge_id: native_badge_ids)
          .each do |user_badge|
            native_user_badges[[user_badge.user_id, user_badge.badge_id]] = user_badge
          end
      end
    end

    missing_award_date_count = 0
    native_award_timestamp_mismatch_count = 0
    expected_pairs.each do |uid, medalid|
      user_id = uid_to_user[uid]
      badge_id = mapping_badge_ids[medalid]
      next unless user_id && badge_id

      user_badge = native_user_badges[[user_id, badge_id]]
      next unless user_badge

      source_dateline = source_award_dates[[uid, medalid]]
      expected_granted_at =
        source_dateline ? Time.zone.at(source_dateline) : target_users[user_id]&.created_at
      missing_award_date_count += 1 unless source_dateline
      if expected_granted_at && user_badge.granted_at.to_i != expected_granted_at.to_i
        native_award_timestamp_mismatch_count += 1
      end
    end

    enable_badges_failure = SiteSetting.enable_badges ? 0 : 1
    failure_count =
      missing_definition_count + duplicate_mapping_count + retired_active_mapping_count +
        definition_metadata_mismatch_count + badge_definition_mismatch_count +
        duplicate_user_uid_count + missing_user_count + marker_mismatch_count +
        malformed_token_count + grant_pair_comparison[:missing_count] +
        grant_pair_comparison[:unexpected_count] + duplicate_grant_count +
        grant_ownership_mismatch_count + expiration_mismatch_count +
        source_award_date_mismatch_count + native_pair_comparison[:missing_count] +
        native_pair_comparison[:unexpected_count] + unmapped_native_badge_count +
        post_specific_native_badge_count + native_award_timestamp_mismatch_count +
        enable_badges_failure

    {
      mode: mode,
      sampled_member_uids: source_uids.length,
      source_definition_count: definitions.length,
      target_mapping_count: target_mappings.length,
      missing_definition_count: missing_definition_count,
      duplicate_mapping_count: duplicate_mapping_count,
      active_retired_mapping_count: retired_active_mapping_count,
      definition_metadata_mismatch_count: definition_metadata_mismatch_count,
      native_badge_definition_mismatch_count: badge_definition_mismatch_count,
      native_badge_setting_enabled: SiteSetting.enable_badges,
      source_assignment_count: expected_pairs.length,
      expired_source_assignment_count: expired_assignment_count,
      unavailable_source_assignment_count: unavailable_assignment_count,
      assignments_without_definition_count: undefined_assignment_count,
      malformed_membership_token_count: malformed_token_count,
      target_user_mapping_missing_count: missing_user_count,
      target_user_mapping_duplicate_count: duplicate_user_uid_count,
      target_user_source_marker_mismatch_count: marker_mismatch_count,
      imported_assignment_count: actual_grant_pairs.length,
      assignment_ledger_comparison: grant_pair_comparison,
      duplicate_assignment_ledger_count: duplicate_grant_count,
      assignment_ownership_mismatch_count: grant_ownership_mismatch_count,
      assignment_expiration_mismatch_count: expiration_mismatch_count,
      assignment_award_date_mismatch_count: source_award_date_mismatch_count,
      native_user_badge_comparison: native_pair_comparison,
      native_badges_without_mapping_count: unmapped_native_badge_count,
      post_specific_native_medal_badge_count: post_specific_native_badge_count,
      native_award_timestamp_mismatch_count: native_award_timestamp_mismatch_count,
      awards_using_account_creation_fallback_date: missing_award_date_count,
      intentional_exclusions: {
        undefined_medal_definition: undefined_assignment_count,
      },
      image_handling:
        "Valid Discuz medal filenames link to the legacy static host; image files are not copied",
      acceptance: {
        status: failure_count.zero? ? "passed" : "failed",
        failure_count: failure_count,
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
    email_conflict_remaps = flagged_source_user_ids("discuz_email_conflict", user_imports)
    email_confirmation_report =
      verify_email_confirmation(
        source,
        user_imports,
        expected_duplicate_emails,
        email_conflict_remaps,
      )
    provenance_report = verify_discuz_provenance(user_imports)
    avatar_report = verify_discuz_avatar_mapping(source, user_imports)
    expected_category_imports =
      category_imports.select { |source_id, _target_id| source[:category_ids].include?(source_id) }
    site_setup_report = verify_site_setup(expected_category_imports)

    category_comparison = compare_ids(source[:category_ids], expected_category_imports.keys.to_set)
    category_content_report = verify_categories(source, expected_category_imports)
    post_report = verify_posts(source, user_imports, category_imports)
    pm_report = verify_private_messages(source, user_imports, pm_posts, pm_duplicate_values)
    password_report = verify_legacy_password_fields(source, user_imports)
    medal_report = verify_discuz_medals(source[:member_ids], mode: "discuz_medal_acceptance")

    core_failures = [
      user_comparison[:missing_count],
      user_comparison[:unexpected_count],
      user_duplicate_values.length,
      compare_ids(expected_placeholders, imported_placeholders)[:missing_count],
      compare_ids(expected_placeholders, imported_placeholders)[:unexpected_count],
      active_placeholder_count,
      compare_ids(expected_duplicate_emails, imported_duplicate_emails)[:missing_count],
      compare_ids(expected_duplicate_emails, imported_duplicate_emails)[:unexpected_count],
      provenance_report[:mismatch_count],
      provenance_report[:unexpected_tagged_account_count],
      avatar_report[:failure_count],
      email_confirmation_report[:failure_count],
      site_setup_report[:failure_count],
      category_comparison[:missing_count],
      category_comparison[:unexpected_count],
      category_duplicate_values.length,
      category_content_report[:name_mismatches],
      category_content_report[:parent_mismatches],
      category_content_report[:read_restriction_mismatches],
      category_content_report[:permission_mismatches],
      category_content_report[:access_metadata_mismatches],
      category_content_report[:category_content_failure_count],
      post_report[:failure_count],
      pm_report[:failure_count],
      password_report[:failure_count],
      medal_report.dig(:acceptance, :failure_count),
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
        target_email_conflict_remap_count: email_conflict_remaps.length,
        email_confirmation: email_confirmation_report,
        provenance: provenance_report,
        avatar_mapping: avatar_report,
        legacy_auth: password_report,
      },
      site_setup: site_setup_report,
      categories: {
        imported_id_count: expected_category_imports.length,
        retained_excluded_mapping_count: category_imports.length - expected_category_imports.length,
        id_comparison: category_comparison,
        duplicate_import_id_count: category_duplicate_values.length,
        content_relationships: category_content_report,
      },
      posts: post_report,
      private_messages: pm_report,
      medals: medal_report,
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
    members =
      rows(
        "SELECT uid, email, emailstatus, avatarstatus FROM (#{member_union}) members#{member_filter} ORDER BY uid",
      )
    member_ids = members.map { |row| row["uid"].to_s }.to_set
    references = @sample_manifest ? sample_referenced_uid_union : referenced_uid_union
    reference_ids = rows(<<~SQL).map { |row| row["uid"].to_s }.to_set
      SELECT refs.uid
        FROM (#{references}) refs
       WHERE refs.uid IS NOT NULL
    SQL
    member_email_key = source_email_comparison_sql("members.email")
    candidate_email_key = source_email_comparison_sql("candidates.email")
    duplicate_email_uids = rows(<<~SQL).map { |row| row["uid"].to_s }.to_set
      SELECT members.uid
        FROM (#{member_union}) members
        JOIN (
          SELECT #{candidate_email_key} email_key, MIN(uid) retained_uid
            FROM (#{member_union}) candidates
           WHERE email IS NOT NULL AND TRIM(email) <> ''
           GROUP BY email_key
          HAVING COUNT(DISTINCT uid) > 1
        ) duplicates ON #{member_email_key} = duplicates.email_key
       WHERE members.uid <> duplicates.retained_uid
    SQL
    duplicate_email_uids &= member_ids if @sample_manifest
    medals_enabled =
      scalar("SELECT COUNT(*) count FROM #{bbs("forum_medal")} WHERE available = 1") > 0
    category_rows = rows(<<~SQL)
      SELECT f.fid id, f.fup parent_id, f.name, f.type, f.status,
             d.description, d.rules, d.viewperm, d.formulaperm, d.password forum_password,
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
        .select { |row| DiscuzCategoryEligibility.importable?(row) }
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
    source_rows = source[:category_rows].select { |row| DiscuzCategoryEligibility.importable?(row) }
    effective_parent_ids =
      DiscuzCategoryEligibility.effective_parent_ids(
        source[:category_rows],
        max_nesting: DiscuzCategoryEligibility::MAX_CATEGORY_NESTING,
      )
    source_read_restricted =
      DiscuzCategoryPermissions.source_category_read_restrictions(
        source[:category_rows],
        medals_enabled: source[:medals_enabled],
      )
    target_rows =
      Category
        .where(id: category_imports.values)
        .pluck(:id, :name, :parent_category_id, :read_restricted, :description, :topic_id)
        .to_h do |id, name, parent_id, read_restricted, description, topic_id|
          [
            id,
            {
              name: name,
              parent_id: parent_id,
              read_restricted: read_restricted,
              description: description,
              topic_id: topic_id,
            },
          ]
        end
    content_field_names = %w[discuz_rules skip_category_definition]
    content_fields =
      CategoryCustomField
        .where(category_id: category_imports.values, name: content_field_names)
        .pluck(:category_id, :name, :value)
        .to_h { |category_id, name, value| [[category_id, name], value] }
    permission_rows =
      CategoryGroup.where(category_id: category_imports.values).pluck(
        :category_id,
        :group_id,
        :permission_type,
      )
    target_permissions = Hash.new { |hash, key| hash[key] = {} }
    permission_rows.each do |category_id, group_id, permission_type|
      target_permissions[category_id][group_id] = permission_type
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
    category_nesting_setting_mismatches =
      (
        if SiteSetting.max_category_nesting.to_i == DiscuzCategoryEligibility::MAX_CATEGORY_NESTING
          0
        else
          1
        end
      )
    description_presence_mismatches = 0
    rules_presence_mismatches = 0
    skip_definition_marker_mismatches = 0
    category_definition_topic_ids = []
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
      description_presence_mismatches += 1 if target[:description].present? !=
        row["description"].present?
      rules_value = content_fields[[category_id, "discuz_rules"]]
      rules_presence_mismatches += 1 if rules_value.present? != row["rules"].present?
      skip_marker = content_fields[[category_id, "skip_category_definition"]]
      skip_definition_marker_mismatches += 1 unless truthy_field?(skip_marker)
      category_definition_topic_ids << category_id if target[:topic_id].present?
      effective_parent_id = effective_parent_ids[row["id"].to_i]
      expected_parent = category_imports[effective_parent_id.to_s] if effective_parent_id
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
          { Group::AUTO_GROUPS[:staff] => full_permission }
        elsif write_restricted
          write_restricted_categories += 1
          {
            Group::AUTO_GROUPS[:everyone] => readonly_permission,
            Group::AUTO_GROUPS[:staff] => full_permission,
          }
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

    category_content_failure_count =
      category_nesting_setting_mismatches + description_presence_mismatches +
        rules_presence_mismatches + skip_definition_marker_mismatches +
        category_definition_topic_ids.length

    {
      name_mismatches: name_mismatches,
      parent_mismatches: parent_mismatches,
      description_presence_mismatches: description_presence_mismatches,
      rules_presence_mismatches: rules_presence_mismatches,
      skip_definition_marker_mismatches: skip_definition_marker_mismatches,
      category_definition_topic_count: category_definition_topic_ids.length,
      category_definition_topic_ids: category_definition_topic_ids,
      category_content_failure_count: category_content_failure_count,
      read_restriction_mismatches: read_restriction_mismatches,
      read_restriction_mismatch_ids: read_restriction_mismatch_ids,
      permission_mismatches: permission_mismatches,
      access_metadata_mismatches: access_metadata_mismatches,
      category_nesting_setting_mismatches: category_nesting_setting_mismatches,
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
          "SELECT COUNT(*) count FROM #{bbs("forum_forum")} WHERE #{DiscuzCategoryEligibility.sql_condition}",
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
    existing_imported_ids = CategoryCustomField.where(name: "import_id").select(:category_id)
    reserved_root_names =
      Category
        .where(parent_category_id: nil)
        .where.not(id: existing_imported_ids)
        .pluck(:name)
        .map { |name| name.to_s.strip[0..49].downcase }
        .to_set
    effective_parent_ids =
      DiscuzCategoryEligibility.effective_parent_ids(
        source_rows,
        max_nesting: DiscuzCategoryEligibility::MAX_CATEGORY_NESTING,
      )
    DiscuzCategoryEligibility.display_names(
      source_rows,
      effective_parent_ids: effective_parent_ids,
      reserved_root_names: reserved_root_names,
    )
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
    candidates = rows.select { |row| DiscuzCategoryEligibility.importable?(row) }
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
    unconverted_smiley_source_ids = []
    smiley_conversion_mismatch_count = 0
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
        smiley_conversion_mismatch_count += counts.delete(:smiley_conversion_mismatch_count)
        unconverted_smiley_source_ids.concat(counts.delete(:unconverted_smiley_source_ids))
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
      smiley_conversion_mismatch_count += counts.delete(:smiley_conversion_mismatch_count)
      unconverted_smiley_source_ids.concat(counts.delete(:unconverted_smiley_source_ids))
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
      smiley_conversion_mismatch_count,
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
      unconverted_discuz_smiley_count: smiley_conversion_mismatch_count,
      unconverted_discuz_smiley_source_ids: unconverted_smiley_source_ids.first(100),
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
      SELECT id_field.value import_id, p.deleted_at, p.topic_id, p.user_id, p.raw,
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
    smiley_conversion_mismatch_count = 0
    unconverted_smiley_source_ids = []

    batch.each do |record|
      target_rows = imported_by_id[record[:id]] || []
      if record[:expected]
        if target_rows.empty?
          missing_count += 1
          next
        end

        target = target_rows.first
        source = record[:source]
        target_raw = target["raw"].to_s
        if DiscuzMigration::Smilies.convert(target_raw) != target_raw
          smiley_conversion_mismatch_count += 1
          unconverted_smiley_source_ids << record[:id] if unconverted_smiley_source_ids.length < 100
        end
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
      smiley_conversion_mismatch_count: smiley_conversion_mismatch_count,
      unconverted_smiley_source_ids: unconverted_smiley_source_ids,
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
    sample_filter = "WHERE members.uid IN (#{sample_id_sql("member_uids")})" if @sample_manifest
    source_types = rows(<<~SQL).to_h { |row| [row["uid"].to_s, row["hash_type"]] }
      SELECT members.uid,
             CASE
               WHEN COALESCE(uc.password, '') = '' THEN 'no_legacy_password'
               WHEN COALESCE(uc.salt, '') = ''
                    AND LENGTH(uc.password) = 60
                    AND LEFT(uc.password, 4) IN (
                      CONCAT(CHAR(36), '2y', CHAR(36)),
                      CONCAT(CHAR(36), '2a', CHAR(36)),
                      CONCAT(CHAR(36), '2b', CHAR(36))
                    ) THEN 'bcrypt'
               WHEN LENGTH(uc.salt) = 6
                    AND uc.password REGEXP '^[A-Fa-f0-9]{32}$' THEN 'md5_salt6'
               ELSE 'unsupported'
             END hash_type
        FROM (#{member_union}) members
        LEFT JOIN #{uc("members")} uc ON uc.uid = members.uid
       #{sample_filter}
    SQL
    target_types = {}
    native_password_user_ids = Set.new
    user_imports.each_slice(500) do |batch|
      target_ids = batch.map(&:last)
      next if target_ids.empty?

      target_rows = ActiveRecord::Base.connection.select_all(<<~SQL).to_a
        SELECT user_id,
               CASE
                 WHEN COALESCE(hash_value, '') = '' THEN 'no_legacy_password'
                 WHEN COALESCE(salt_value, '') = ''
                      AND LENGTH(hash_value) = 60
                      AND LEFT(hash_value, 4) IN (
                        chr(36) || '2y' || chr(36),
                        chr(36) || '2a' || chr(36),
                        chr(36) || '2b' || chr(36)
                      ) THEN 'bcrypt'
                 WHEN LENGTH(salt_value) = 6
                      AND hash_value ~ '^[A-Fa-f0-9]{32}$' THEN 'md5_salt6'
                 ELSE 'unsupported'
               END hash_type
          FROM (
            SELECT user_id,
                   MAX(value) FILTER (WHERE name = 'discuz_password_hash') hash_value,
                   MAX(value) FILTER (WHERE name = 'discuz_password_salt') salt_value
              FROM user_custom_fields
             WHERE user_id IN (#{target_ids.join(",")})
               AND name IN ('discuz_password_hash', 'discuz_password_salt')
             GROUP BY user_id
          ) credentials
      SQL
      target_types.merge!(target_rows.to_h { |row| [row["user_id"], row["hash_type"]] })
      native_password_user_ids.merge(UserPassword.where(user_id: target_ids).pluck(:user_id))
      target_ids.each { |target_id| target_types[target_id] ||= "no_legacy_password" }
    end

    mapped_source_types =
      source_types
        .filter_map do |uid, source_type|
          target_id = user_imports[uid]
          next unless target_id

          target_type = target_types[target_id]
          if %w[bcrypt md5_salt6].include?(source_type) && target_type == "no_legacy_password" &&
               native_password_user_ids.include?(target_id)
            target_type = "discuz_password_upgraded"
          end
          [uid, target_type]
        end
        .to_h
    hash_type_mismatch_count =
      source_types.count do |uid, hash_type|
        user_imports.key?(uid) && mapped_source_types[uid] != "discuz_password_upgraded" &&
          mapped_source_types[uid] != hash_type
      end
    unsupported_source_hash_count = source_types.count { |_uid, type| type == "unsupported" }
    missing_hash_or_salt_count =
      source_types.count do |uid, type|
        %w[bcrypt md5_salt6].include?(type) &&
          (!user_imports[uid] || !mapped_source_types.key?(uid))
      end
    source_type_counts = source_types.values.tally.sort.to_h
    imported_type_counts = mapped_source_types.values.tally.sort.to_h
    failure_count =
      hash_type_mismatch_count + unsupported_source_hash_count + missing_hash_or_salt_count

    {
      source_accounts_by_hash_type: source_type_counts,
      imported_accounts_by_hash_type: imported_type_counts,
      legacy_password_upgraded_count:
        mapped_source_types.values.count { |type| type == "discuz_password_upgraded" },
      hash_type_mismatch_count: hash_type_mismatch_count,
      unsupported_source_hash_count: unsupported_source_hash_count,
      missing_hash_or_salt_count: missing_hash_or_salt_count,
      failure_count: failure_count,
      verification:
        "hashes and salts are classified in SQL; successfully upgraded Discourse passwords are accepted",
    }
  end

  def imported_values(model, foreign_key)
    pairs = model.where(name: "import_id").pluck(:value, foreign_key)
    grouped = pairs.group_by { |value, _id| value.to_s }
    mapping = grouped.transform_values { |entries| entries.first.last }
    duplicate_values = grouped.select { |_value, entries| entries.length > 1 }.keys.to_set
    [mapping, duplicate_values]
  end

  def verify_discuz_provenance(user_imports)
    expected_source_by_user = user_imports.invert
    fields =
      UserCustomField.where(name: %w[discuz_source discuz_uid]).pluck(:user_id, :name, :value)
    source_by_user =
      fields
        .filter { |_user_id, name, _value| name == "discuz_source" }
        .to_h { |user_id, _name, value| [user_id, value] }
    uid_by_user =
      fields
        .filter { |_user_id, name, _value| name == "discuz_uid" }
        .to_h { |user_id, _name, value| [user_id, value] }

    mismatch_count =
      expected_source_by_user.count do |user_id, source_uid|
        source_by_user[user_id] != "discuz_x3.5" || uid_by_user[user_id].to_s != source_uid.to_s
      end
    expected_user_ids = expected_source_by_user.keys.to_set
    unexpected_tagged_account_count =
      (
        source_by_user.select { |_user_id, source| source == "discuz_x3.5" }.keys.to_set -
          expected_user_ids
      ).length

    {
      expected_tagged_account_count: expected_source_by_user.length,
      matching_tagged_account_count: expected_source_by_user.length - mismatch_count,
      mismatch_count: mismatch_count,
      unexpected_tagged_account_count: unexpected_tagged_account_count,
    }
  end

  def verify_discuz_avatar_mapping(source, user_imports)
    expected_status_by_uid =
      source[:members].to_h do |row|
        [row["uid"].to_s, row["avatarstatus"].to_s.to_i == 1 ? "1" : "0"]
      end
    target_ids = expected_status_by_uid.keys.filter_map { |uid| user_imports[uid] }.uniq
    users = User.where(id: target_ids).index_by(&:id)
    imported_status_by_user =
      UserCustomField
        .where(user_id: target_ids, name: "discuz_avatarstatus")
        .pluck(:user_id, :value)
        .to_h

    missing_target_count =
      expected_status_by_uid.count { |uid, _status| !users.key?(user_imports[uid]) }
    marker_mismatch_count =
      expected_status_by_uid.count do |uid, expected_status|
        user_id = user_imports[uid]
        users.key?(user_id) && imported_status_by_user[user_id].to_s != expected_status
      end
    rendering_mismatch_count =
      expected_status_by_uid.count do |uid, expected_status|
        user = users[user_imports[uid]]
        next false unless user

        if expected_status == "1" && user.uploaded_avatar_id.blank?
          user.avatar_template != discuz_avatar_template(uid)
        elsif expected_status == "0"
          user.uploaded_avatar_id.present? ||
            user.avatar_template !=
              ::DiscourseDiscuzLegacyAuth::UserAvatarExtension.local_default_avatar_template(
                user.username,
              )
        else
          user.avatar_template.start_with?(
            ::DiscourseDiscuzLegacyAuth::UserAvatarExtension::DISCUZ_AVATAR_BASE_URL,
          )
        end
      end

    {
      source_without_custom_avatar_count:
        expected_status_by_uid.count { |_uid, status| status == "0" },
      source_with_custom_avatar_count:
        expected_status_by_uid.count { |_uid, status| status == "1" },
      missing_target_count: missing_target_count,
      marker_mismatch_count: marker_mismatch_count,
      rendering_mismatch_count: rendering_mismatch_count,
      failure_count: missing_target_count + marker_mismatch_count + rendering_mismatch_count,
      comparison:
        "Discuz avatarstatus=0 must use the Discourse default avatar; status=1 uses the DZ URL unless an uploaded Discourse avatar exists",
    }
  end

  def discuz_avatar_template(uid)
    padded_uid = uid.to_s.rjust(9, "0")
    avatar_path = [padded_uid[0, 3], padded_uid[3, 2], padded_uid[5, 2]]
    filename = "#{padded_uid[-2, 2]}_avatar_small.jpg"
    base_url = ::DiscourseDiscuzLegacyAuth::UserAvatarExtension::DISCUZ_AVATAR_BASE_URL
    "#{base_url}/#{(avatar_path + [filename]).join("/")}"
  end

  def verify_email_confirmation(source, user_imports, duplicate_email_uids, email_conflict_uids)
    target_users = {}
    user_imports
      .values
      .uniq
      .each_slice(500) do |target_ids|
        User
          .where(id: target_ids)
          .includes(:email_tokens, :single_sign_on_record)
          .each do |user|
            email_tokens = user.email_tokens.to_a
            email_confirmed =
              !!(
                email_tokens.any? { |token| token.email == user.email && token.confirmed } ||
                  email_tokens.empty? ||
                  user.single_sign_on_record&.external_email&.downcase == user.email
              )
            target_users[user.id] = {
              email: user.email,
              email_confirmed: email_confirmed,
              active: user.active?,
            }
          end
      end

    expected_confirmed_uids = Set.new
    source_confirmed_email_mismatch_count = 0
    source[:members].each do |row|
      next unless row["emailstatus"].to_s.to_i == 1

      uid = row["uid"].to_s
      next if duplicate_email_uids.include?(uid) || email_conflict_uids.include?(uid)

      source_email = row["email"].to_s.strip
      next unless EmailAddressValidator.valid_value?(source_email)

      target_user = target_users[user_imports[uid]]
      if target_user && target_user[:email] == source_email.downcase
        expected_confirmed_uids.add(uid)
      else
        source_confirmed_email_mismatch_count += 1
      end
    end

    inactive_source_member_count =
      source[:member_ids].count do |uid|
        target_user = target_users[user_imports[uid]]
        target_user && !target_user[:active]
      end

    confirmation_mismatch_count =
      user_imports.count do |uid, target_id|
        target_user = target_users[target_id]
        expected_confirmed = expected_confirmed_uids.include?(uid)
        !target_user || target_user[:email_confirmed] != expected_confirmed
      end

    {
      source_confirmed_mappable_count: expected_confirmed_uids.length,
      source_confirmed_email_mismatch_count: source_confirmed_email_mismatch_count,
      target_confirmed_imported_count: target_users.values.count { |user| user[:email_confirmed] },
      source_member_active_count:
        source[:member_ids].count { |uid| target_users[user_imports[uid]]&.[](:active) },
      inactive_source_member_count: inactive_source_member_count,
      confirmation_mismatch_count: confirmation_mismatch_count,
      failure_count:
        source_confirmed_email_mismatch_count + confirmation_mismatch_count +
          inactive_source_member_count,
      comparison:
        "Source emailstatus is compared with Discourse User#email_confirmed?; " \
          "every imported Discuz member must remain active; duplicate and conflict remaps remain unconfirmed",
    }
  end

  def verify_site_setup(category_imports)
    seed_topic_settings = %w[guidelines_topic_id welcome_topic_id admin_quick_start_topic_id]
    remaining_seed_topics =
      seed_topic_settings.filter do |setting_name|
        topic_id = SiteSetting.get(setting_name).to_i
        next false unless topic_id.positive?

        topic = Topic.find_by(id: topic_id)
        topic && topic.deleted_at.blank?
      end
    locale_matches = SiteSetting.default_locale == "zh_CN"
    unicode_usernames_enabled = SiteSetting.unicode_usernames
    imported_category_ids = category_imports.values.to_set
    general_setting_id = SiteSetting.general_category_id.to_i
    general_candidate_ids = Category.where(slug: "general").pluck(:id).to_set
    general_candidate_ids.add(general_setting_id) if general_setting_id.positive?
    unimported_general_categories =
      Category
        .where(id: general_candidate_ids.to_a)
        .where.not(id: imported_category_ids.to_a)
        .order(:id)
        .pluck(:id, :name, :slug, :topic_count)
        .map do |id, name, slug, topic_count|
          { id: id, name: name, slug: slug, topic_count: topic_count }
        end
    missing_general_setting_target =
      general_setting_id.positive? && !Category.exists?(id: general_setting_id)
    default_forum_category_setting_ids =
      %w[meta_category_id staff_category_id].to_h do |setting_name|
        [setting_name, SiteSetting.get(setting_name).to_i]
      end
    default_forum_category_ids =
      default_forum_category_setting_ids.values.select(&:positive?).to_set
    remaining_default_forum_categories =
      Category
        .where(id: default_forum_category_ids.to_a)
        .order(:id)
        .pluck(:id, :name, :slug)
        .map { |id, name, slug| { id: id, name: name, slug: slug } }
    active_topics_in_default_forum_categories =
      Topic
        .where(category_id: default_forum_category_ids.to_a)
        .order(:id)
        .pluck(:id, :title, :category_id)
        .map { |id, title, category_id| { id: id, title: title, category_id: category_id } }
    retained_system_category_settings =
      %w[uncategorized_category_id meta_category_id staff_category_id].to_h do |setting_name|
        category_id = SiteSetting.get(setting_name).to_i
        category = Category.find_by(id: category_id) if category_id.positive?
        [setting_name, { id: category_id, name: category&.name }]
      end
    default_composer_category_id = SiteSetting.default_composer_category.to_s
    missing_default_composer_category =
      default_composer_category_id.present? && default_composer_category_id.match?(/\A\d+\z/) &&
        !Category.exists?(id: default_composer_category_id.to_i)
    default_navigation_category_ids =
      SiteSetting
        .default_navigation_menu_categories
        .split("|")
        .filter_map { |id| id.to_i if id.match?(/\A\d+\z/) }
        .uniq
    missing_default_navigation_category_ids =
      default_navigation_category_ids -
        Category.where(id: default_navigation_category_ids).pluck(:id)
    default_navigation_category_set = default_navigation_category_ids.to_set
    missing_imported_sidebar_category_ids = imported_category_ids - default_navigation_category_set
    unexpected_sidebar_category_ids = default_navigation_category_set - imported_category_ids
    default_sidebar_categories_match_imports =
      missing_imported_sidebar_category_ids.empty? && unexpected_sidebar_category_ids.empty?
    failure_count =
      (locale_matches ? 0 : 1) + (unicode_usernames_enabled ? 0 : 1) +
        remaining_seed_topics.length + unimported_general_categories.length +
        remaining_default_forum_categories.length +
        active_topics_in_default_forum_categories.length +
        (missing_general_setting_target ? 1 : 0) + (missing_default_composer_category ? 1 : 0) +
        missing_default_navigation_category_ids.length +
        (default_sidebar_categories_match_imports ? 0 : 1)

    {
      default_locale: SiteSetting.default_locale,
      expected_default_locale: "zh_CN",
      locale_matches: locale_matches,
      unicode_usernames_enabled: unicode_usernames_enabled,
      expected_unicode_usernames_enabled: true,
      remaining_default_seed_topics: remaining_seed_topics,
      retained_system_category_settings: retained_system_category_settings,
      default_forum_category_setting_ids: default_forum_category_setting_ids,
      remaining_default_forum_categories: remaining_default_forum_categories,
      active_topics_in_default_forum_categories: active_topics_in_default_forum_categories,
      required_default_forum_categories_absent:
        remaining_default_forum_categories.empty? &&
          active_topics_in_default_forum_categories.empty?,
      unimported_general_categories: unimported_general_categories,
      general_category_setting_id: general_setting_id,
      default_composer_category_id: default_composer_category_id,
      missing_general_setting_target: missing_general_setting_target,
      missing_default_composer_category: missing_default_composer_category,
      default_navigation_category_ids: default_navigation_category_ids,
      missing_default_navigation_category_ids: missing_default_navigation_category_ids,
      missing_imported_sidebar_category_ids: missing_imported_sidebar_category_ids.to_a.sort,
      unexpected_sidebar_category_ids: unexpected_sidebar_category_ids.to_a.sort,
      default_sidebar_categories_match_imports: default_sidebar_categories_match_imports,
      default_category_cleanup_policy:
        "remove untouched Site Feedback and Staff seed categories before importing Discuz categories; retain their positive setting IDs as tombstones to prevent reseeding",
      general_category_cleanup_policy:
        "remove only an untouched, unimported General seed category with no active topics or children; preserve edited, imported, or content-bearing categories",
      failure_count: failure_count,
    }
  end

  def source_email_comparison_sql(expression)
    return "LOWER(TRIM(#{expression}))" unless SiteSetting.normalize_emails?

    <<~SQL.squish
      LOWER(CONCAT(
        REPLACE(SUBSTRING_INDEX(SUBSTRING_INDEX(TRIM(#{expression}), '@', 1), '+', 1), '.', ''),
        '@',
        SUBSTRING_INDEX(TRIM(#{expression}), '@', -1)
      ))
    SQL
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
      SELECT uid, email, emailstatus, avatarstatus FROM #{active}
      UNION ALL
      SELECT archived.uid, archived.email, archived.emailstatus, archived.avatarstatus
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
    sell_buyers =
      "SELECT DISTINCT uid FROM #{bbs("dc_sell_log")} " \
        "WHERE uid > 0 AND uid IN (#{sample_id_sql("sell_buyer_uids")})"
    [post_authors, pm_members, pm_authors, pm_pair_participants, sell_buyers].join("\nUNION\n")
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
