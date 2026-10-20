#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "mysql2"
require "time"
require_relative "../../plugins/discourse-discuz-bbcode/lib/discourse_discuz_bbcode/sell_tag_parser"
require_relative "category_permissions"

class DiscuzSellSampleBuilder
  TARGET_DATABASE = "discourse_migration_sell_public_preview_20261018"
  BASE_MANIFEST = "/Users/daren/discourse-lab/discuz-sample-manifest-uid18-20261013.json"

  def initialize
    @host = ENV.fetch("DISCUZX_DB_HOST", "127.0.0.1")
    @port = Integer(ENV.fetch("DISCUZX_DB_PORT", "13306"))
    unless @host == "127.0.0.1" && @port == 13_306
      raise "source MySQL must be loopback 127.0.0.1:13306"
    end

    @source =
      Mysql2::Client.new(
        host: @host,
        port: @port,
        username: ENV.fetch("DISCUZX_DB_USER"),
        password: ENV.fetch("MYSQL_PWD"),
        database: "bbs",
        encoding: "utf8mb4",
        connect_timeout: 5,
        read_timeout: 120,
        get_server_public_key: true,
      )
    @source.query("SET SESSION TRANSACTION READ ONLY")
    @source.query("START TRANSACTION READ ONLY")
  end

  def run
    manifest = JSON.parse(File.read(base_manifest_path))
    raise "unsupported base sample manifest" unless manifest["version"] == 1

    @base_category_ids = manifest.fetch("category_ids").map(&:to_i)
    topic_id = selected_topic_id
    added_post_rows =
      query("SELECT pid, authorid FROM bbs.forum_post WHERE tid = #{topic_id} ORDER BY pid")
    raise "selected attachment sell topic has no posts" if added_post_rows.empty?

    post_ids =
      (manifest.fetch("post_ids") + added_post_rows.map { |row| row["pid"].to_i }).uniq.sort
    topic_ids = (manifest.fetch("topic_ids") + [topic_id]).uniq.sort
    sell_rows =
      query(
        "SELECT pid, tid, authorid, message FROM bbs.forum_post " \
          "WHERE pid IN (#{csv(post_ids)}) AND LOCATE('[sell', LOWER(message)) > 0 ORDER BY pid",
      )
    sections_by_key = {}
    sell_rows.each do |row|
      pid = row["pid"].to_i
      _sanitized, sections =
        DiscourseDiscuzBbcode::SellTagParser.extract(row["message"], discuz_pid: pid)
      sections.each do |section|
        key = [pid, section.fetch(:section_index)]
        sections_by_key[key] = {
          author_uid: row["authorid"].to_i,
          price: section.fetch(:price),
          credit_id: section.fetch(:credit_id),
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
    if post_ids.count(@candidate_sell_post_id).zero?
      raise "selected attachment sell post was not selected"
    end
    unless sections_by_key.any? { |(pid, _index), section|
             pid == @candidate_sell_post_id && section[:attachment_aids].any?
           }
      raise "selected sell post no longer has an attachment inside its protected section"
    end

    sell_post_ids = sections_by_key.keys.map(&:first).uniq.sort
    raise "selected sample contains no valid Discuz sell sections" if sell_post_ids.empty?
    log_rows =
      query(
        "SELECT id, pid, cid, uid, authorid FROM bbs.dc_sell_log " \
          "WHERE pid IN (#{csv(sell_post_ids)}) ORDER BY id",
      )
    valid_logs =
      log_rows.select do |row|
        key = [row["pid"].to_i, row["cid"].to_i]
        section = sections_by_key[key]
        next false unless section && row["uid"].to_i.positive?

        if row["authorid"].to_i.positive? && row["authorid"].to_i != section[:author_uid]
          raise "sample purchase author does not match the source post"
        end
        true
      end
    buyer_uids = valid_logs.map { |row| row["uid"].to_i }.uniq.sort
    raise "selected sell sample has no historical buyers" if buyer_uids.empty?

    referenced_uids =
      added_post_rows.map { |row| row["authorid"].to_i }.select(&:positive?) + buyer_uids
    known_uids =
      query(
        "SELECT uid FROM (#{member_union}) members WHERE uid IN (#{csv(referenced_uids)})",
      ).map { |row| row["uid"].to_i }
    member_uids = (manifest.fetch("member_uids") + known_uids).uniq.sort
    placeholder_uids =
      (manifest.fetch("placeholder_uids") + (referenced_uids.uniq - known_uids)).uniq.sort -
        member_uids

    manifest["target_database"] = TARGET_DATABASE
    manifest["selection"][
      "relation_closure"
    ] = "all posts in selected topics, including a source post with a protected attachment; all historical buyers for selected sell blocks; all messages in selected PM threads across shards 0..9; all referenced users"
    manifest["sell_candidate_post_id"] = @candidate_sell_post_id
    manifest["member_uids"] = member_uids
    manifest["placeholder_uids"] = placeholder_uids
    manifest["required_uids"] = (member_uids + placeholder_uids).uniq.sort
    manifest["topic_ids"] = topic_ids
    manifest["post_ids"] = post_ids
    manifest["sell_post_ids"] = sell_post_ids
    manifest["sell_section_ids"] = sections_by_key.keys.sort
    manifest["sell_log_ids"] = valid_logs.map { |row| row["id"].to_i }.sort
    manifest["sell_buyer_uids"] = buyer_uids
    manifest["sell_attachment_aids"] = sections_by_key
      .flat_map do |(pid, section_index), section|
        section[:attachment_aids].map do |aid|
          { "discuz_pid" => pid, "section_index" => section_index, "aid" => aid }
        end
      end
      .sort_by { |item| [item["discuz_pid"], item["section_index"], item["aid"]] }
    manifest["sample_counts"].merge!(
      "member_rows_to_import" => member_uids.length,
      "non_login_placeholders" => placeholder_uids.length,
      "topics" => topic_ids.length,
      "posts" => post_ids.length,
      "sell_posts" => sell_post_ids.length,
      "sell_sections" => sections_by_key.length,
      "sell_purchase_rows" => valid_logs.length,
      "sell_buyers" => buyer_uids.length,
      "sell_section_attachments" => manifest.fetch("sell_attachment_aids").length,
    )
    manifest["generated_at"] = Time.now.utc.iso8601

    output_path =
      File.expand_path(
        ENV.fetch(
          "DISCUZX_SAMPLE_MANIFEST",
          "/Users/daren/discourse-lab/discuz-sample-manifest-sell-20261018.json",
        ),
      )
    unless output_path.start_with?("/Users/daren/discourse-lab/")
      raise "sample manifest must be written under /Users/daren/discourse-lab"
    end
    FileUtils.mkdir_p(File.dirname(output_path), mode: 0o700)
    File.write(output_path, JSON.pretty_generate(manifest) + "\n", mode: "w", perm: 0o600)
    File.chmod(0o600, output_path)

    puts "Wrote relation-closed paid-section sample manifest: #{output_path}"
    %w[
      member_rows_to_import
      non_login_placeholders
      topics
      posts
      sell_posts
      sell_sections
      sell_purchase_rows
      sell_buyers
      sell_section_attachments
    ].each { |key| puts "#{key}=#{manifest.fetch("sample_counts").fetch(key)}" }
  ensure
    @source&.query("COMMIT")
    @source&.close
  end

  private

  def base_manifest_path
    path = File.realpath(ENV.fetch("DISCUZX_SAMPLE_BASE_MANIFEST", BASE_MANIFEST))
    unless path.start_with?("/Users/daren/discourse-lab/") && (File.stat(path).mode & 0o077).zero?
      raise "base sample manifest must be private and under /Users/daren/discourse-lab"
    end
    path
  end

  def selected_topic_id
    forums = query(<<~SQL)
      SELECT f.fid id, f.fup parent_id, d.viewperm, d.formulaperm, d.password forum_password
        FROM bbs.forum_forum AS f
        LEFT JOIN bbs.forum_forumfield AS d ON d.fid = f.fid
    SQL
    medals_enabled =
      query("SELECT COUNT(*) count FROM bbs.forum_medal WHERE available = 1").first[
        "count"
      ].to_i.positive?
    read_restricted =
      DiscuzCategoryPermissions.source_category_read_restrictions(forums, medals_enabled:)

    base_category_ids = csv(@base_category_ids)
    candidates = query(<<~SQL)
      SELECT p.pid, p.tid, p.authorid, p.message, f.fid
        FROM bbs.forum_post AS p
        JOIN bbs.forum_thread AS t ON t.tid = p.tid
        JOIN bbs.forum_forum AS f ON f.fid = t.fid
       WHERE LOCATE('[sell=', LOWER(message)) > 0
         AND LOCATE('[attach]', LOWER(message)) > 0
         AND p.invisible = 0
         AND t.displayorder >= 0
         AND f.status = 1
         AND f.fid IN (#{base_category_ids})
       ORDER BY CRC32(CONCAT('sinofsx-discuz-sell-attachment-v1:', p.pid)), p.pid
       LIMIT 2000
    SQL
    sections_by_pid = {}
    candidates.each do |row|
      next if read_restricted[row["fid"].to_i]

      pid = row["pid"].to_i
      begin
        _sanitized, sections =
          DiscourseDiscuzBbcode::SellTagParser.extract(row["message"], discuz_pid: pid)
      rescue ArgumentError
        next
      end
      protected_sections =
        sections.filter_map do |section|
          aids = section.fetch(:body).scan(%r{\[attach\](\d+)\[/attach\]}i).flatten.map(&:to_i).uniq
          [pid, section.fetch(:section_index)] if aids.any?
        end
      sections_by_pid[pid] = { row: row, keys: protected_sections } if protected_sections.any?
    end
    if sections_by_pid.empty?
      raise "no valid attachment-bearing Discuz sell post in the bounded candidate set"
    end

    logs =
      query(
        "SELECT pid, cid, uid FROM bbs.dc_sell_log " \
          "WHERE pid IN (#{csv(sections_by_pid.keys)}) AND uid > 0 ORDER BY id",
      )
    purchase_counts = Hash.new(0)
    logs.each do |log|
      pid = log["pid"].to_i
      key = [pid, log["cid"].to_i]
      next if sections_by_pid[pid][:keys].count(key).zero?
      purchase_counts[pid] += 1
    end
    selected_pid =
      purchase_counts
        .select { |_pid, count| count.positive? }
        .min_by { |pid, count| [count, pid] }
        &.first
    unless selected_pid
      raise "no attachment-bearing Discuz sell post with historical purchases in the bounded candidate set"
    end

    @candidate_sell_post_id = selected_pid
    sections_by_pid.fetch(selected_pid).fetch(:row).fetch("tid").to_i
  end

  def member_union
    <<~SQL
      SELECT uid FROM bbs.common_member
      UNION
      SELECT uid FROM bbs.common_member_archive
    SQL
  end

  def csv(ids)
    values = ids.map { |id| Integer(id) }.uniq
    values.empty? ? "0" : values.join(",")
  end

  def query(sql)
    @source.query(sql, cache_rows: false).to_a
  end
end

DiscuzSellSampleBuilder.new.run
