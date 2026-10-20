#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "mysql2"
require "time"
require_relative "category_eligibility"

class DiscuzSampleBuilder
  SHARDS = (0..9).to_a.freeze
  USER_HASH_MODULUS = 397
  TOPIC_HASH_LIMIT = 300
  PM_THREADS_PER_SHARD = 5
  EDGE_TOPICS_PER_KIND = 15

  def initialize
    @host = ENV.fetch("DISCUZX_DB_HOST", "127.0.0.1")
    @port = Integer(ENV.fetch("DISCUZX_DB_PORT", "13306"))
    unless @host == "127.0.0.1" && @port == 13_306
      raise "source MySQL must be loopback 127.0.0.1:13306"
    end

    @bbs = "bbs"
    @uc = "ucenter"
    @extra_member_uids =
      ENV
        .fetch("DISCUZX_SAMPLE_EXTRA_MEMBER_UIDS", "")
        .split(",")
        .reject(&:empty?)
        .map { |uid| Integer(uid, 10) }
        .uniq
        .sort
    if @extra_member_uids.any?(&:negative?) || @extra_member_uids.include?(0)
      raise "explicit sample member UIDs must be positive"
    end
    @sample_target_database =
      ENV.fetch("DISCUZX_SAMPLE_TARGET_DATABASE", "discourse_migration_sample")
    case @sample_target_database
    when "discourse_migration_sample", "discourse_migration_sample_uid18_20261013",
         "discourse_migration_sell_sample_20261018", "discourse_migration_sell_preview_20261018",
         "discourse_migration_sell_public_preview_20261018"
    else
      raise "sample target database is not approved"
    end
    @source =
      Mysql2::Client.new(
        host: @host,
        port: @port,
        username: ENV.fetch("DISCUZX_DB_USER"),
        password: ENV.fetch("MYSQL_PWD"),
        database: @bbs,
        encoding: "utf8mb4",
        connect_timeout: 5,
        read_timeout: 120,
        get_server_public_key: true,
      )
    @source.query("SET SESSION TRANSACTION READ ONLY")
    @source.query("START TRANSACTION READ ONLY")
  end

  def run
    user_seed_ids = sample_users
    topic_ids = sample_topics
    pm_thread_ids = sample_pm_threads
    post_rows =
      query("SELECT pid id, authorid uid FROM bbs.forum_post WHERE tid IN (#{csv(topic_ids)})")
    pm_rows = selected_pm_rows(pm_thread_ids)
    pm_member_rows =
      query(
        "SELECT plid thread_id, uid FROM ucenter.pm_members WHERE plid IN (#{csv(pm_thread_ids)})",
      )
    pm_list_rows =
      query(
        "SELECT plid thread_id, pmtype, min_max FROM ucenter.pm_lists WHERE plid IN (#{csv(pm_thread_ids)})",
      )
    unless pm_list_rows.map { |row| row["thread_id"].to_i }.to_set == pm_thread_ids.to_set
      raise "selected PM threads are missing pm_lists metadata"
    end
    pm_declared_participant_uids =
      pm_list_rows
        .select { |row| row["pmtype"].to_i == 1 }
        .flat_map do |row|
          pair = row["min_max"].to_s.split("_", -1)
          unless pair.length == 2 && pair.all? { |uid| uid.match?(/\A[1-9][0-9]*\z/) }
            raise "one-to-one PM thread has invalid declared participants"
          end
          pair.map(&:to_i)
        end
        .uniq
        .sort

    referenced_uids =
      (post_rows + pm_rows + pm_member_rows)
        .filter_map do |row|
          value = row["uid"] || row["authorid"]
          value.to_i if value && value.to_i.positive?
        end
        .to_set
    referenced_uids.merge(pm_declared_participant_uids)
    known_member_ids =
      query("SELECT uid FROM (#{member_union}) members WHERE uid IN (#{csv(referenced_uids.to_a)})")
        .map { |row| row["uid"].to_i }
        .to_set
    member_ids = (user_seed_ids.to_set | known_member_ids).to_a.sort
    placeholder_ids = (referenced_uids - known_member_ids).to_a.sort

    pm_ids = pm_rows.map { |row| row["id"].to_i }
    duplicate_pm_ids = pm_ids.length - pm_ids.uniq.length
    raise "selected PM message IDs collide across shards" if duplicate_pm_ids.positive?

    category_ids = query(<<~SQL).map { |row| row["id"].to_i }.sort
      SELECT fid id FROM bbs.forum_forum
       WHERE #{DiscuzCategoryEligibility.sql_condition}
    SQL
    source_counts = source_counts_snapshot
    shard_counts =
      SHARDS.to_h do |shard|
        count =
          query(
            "SELECT COUNT(*) count FROM ucenter.pm_messages_#{shard} WHERE plid IN (#{csv(pm_thread_ids)})",
          ).first[
            "count"
          ].to_i
        [shard.to_s, count]
      end
    unless shard_counts.values.sum == pm_rows.length
      raise "PM shard counts do not match selected PM message rows"
    end

    manifest = {
      version: 1,
      generated_at: Time.now.utc.iso8601,
      selection: {
        seed: "sinofsx-discuz-rehearsal-v1",
        user_hash_modulus: USER_HASH_MODULUS,
        topic_hash_limit: TOPIC_HASH_LIMIT,
        pm_threads_per_shard: PM_THREADS_PER_SHARD,
        edge_topics_per_kind: EDGE_TOPICS_PER_KIND,
        explicit_member_uids: @extra_member_uids,
        relation_closure:
          "all posts in selected topics; all messages in selected PM threads across shards 0..9; all referenced users and PM participants, including both pm_lists.min_max users for one-to-one PM threads",
      },
      target_database: @sample_target_database,
      source_counts: source_counts,
      member_uids: member_ids,
      seed_member_uids: user_seed_ids,
      pm_declared_participant_uids: pm_declared_participant_uids,
      placeholder_uids: placeholder_ids,
      required_uids: (member_ids | placeholder_ids).sort,
      category_ids: category_ids,
      topic_ids: topic_ids,
      post_ids: post_rows.map { |row| row["id"].to_i }.uniq.sort,
      pm_thread_ids: pm_thread_ids,
      pm_message_ids: pm_ids.uniq.sort,
      pm_shard_message_counts: shard_counts,
      sample_counts: {
        member_rows_to_import: member_ids.length,
        non_login_placeholders: placeholder_ids.length,
        categories: category_ids.length,
        topics: topic_ids.length,
        posts: post_rows.length,
        pm_threads: pm_thread_ids.length,
        pm_messages: pm_rows.length,
        pm_declared_pair_participants: pm_declared_participant_uids.length,
        pm_threads_with_shard_zero_messages: pm_rows.any? { |row| row["shard"].to_i.zero? },
      },
    }

    output =
      File.expand_path(
        ENV.fetch(
          "DISCUZX_SAMPLE_MANIFEST",
          "/Users/daren/discourse-lab/discuz-sample-manifest.json",
        ),
      )
    lab_root = File.realpath("/Users/daren/discourse-lab")
    unless output.start_with?("#{lab_root}/")
      raise "sample manifest must be written under /Users/daren/discourse-lab"
    end
    FileUtils.mkdir_p(File.dirname(output), mode: 0o700)
    File.write(output, JSON.pretty_generate(manifest) + "\n", mode: "w", perm: 0o600)
    File.chmod(0o600, output)

    puts "Wrote relation-closed sample manifest: #{output}"
    manifest[:sample_counts].each { |key, value| puts "#{key}=#{value}" }
    puts "pm_shard_message_counts=#{shard_counts.sort.to_h}"
  ensure
    @source&.query("COMMIT")
    @source&.close
  end

  private

  def member_union
    <<~SQL
      SELECT uid, username, email, groupid, emailstatus, avatarstatus
        FROM bbs.common_member
      UNION ALL
      SELECT archived.uid, archived.username, archived.email,
             archived.groupid, archived.emailstatus, archived.avatarstatus
        FROM bbs.common_member_archive archived
       WHERE NOT EXISTS (SELECT 1 FROM bbs.common_member active WHERE active.uid = archived.uid)
    SQL
  end

  def sample_users
    ids = query(<<~SQL).map { |row| row["uid"].to_i }
      SELECT uid FROM (#{member_union}) members
       WHERE MOD(CRC32(CONCAT('sinofsx-discuz-user-v1:', uid)), #{USER_HASH_MODULUS}) = 0
      UNION
      SELECT MIN(uid) uid FROM (#{member_union}) members GROUP BY groupid
    SQL
    unless @extra_member_uids.empty?
      existing_ids =
        query(
          "SELECT uid FROM (#{member_union}) members WHERE uid IN (#{csv(@extra_member_uids)})",
        ).map { |row| row["uid"].to_i }
      missing_ids = @extra_member_uids - existing_ids
      raise "explicit sample member UID is absent from the source snapshot" if missing_ids.any?
    end

    (ids + @extra_member_uids).uniq.sort
  end

  def sample_topics
    eligible = <<~SQL
      SELECT t.tid, t.fid FROM bbs.forum_thread t
      JOIN bbs.forum_forum f ON f.fid = t.fid
      WHERE #{DiscuzCategoryEligibility.sql_condition("f")}
        AND EXISTS (SELECT 1 FROM bbs.forum_post first_post WHERE first_post.tid = t.tid AND first_post.first = 1)
    SQL
    ids = query(<<~SQL).map { |row| row["tid"].to_i }
      SELECT tid FROM (#{eligible}) eligible_topics
       ORDER BY CRC32(CONCAT('sinofsx-discuz-topic-v1:', tid)), tid
       LIMIT #{TOPIC_HASH_LIMIT}
    SQL

    edge_queries = {
      "hidden_threads" => <<~SQL,
        SELECT DISTINCT t.tid FROM bbs.forum_thread t
        JOIN bbs.forum_forum f ON f.fid = t.fid
        JOIN bbs.forum_post p ON p.tid = t.tid
        WHERE #{DiscuzCategoryEligibility.sql_condition("f")}
          AND (t.displayorder < 0 OR p.invisible <> 0)
        ORDER BY CRC32(CONCAT('sinofsx-discuz-hidden-v1:', t.tid)), t.tid
        LIMIT #{EDGE_TOPICS_PER_KIND}
      SQL
      "poll_threads" => <<~SQL,
        SELECT t.tid FROM bbs.forum_thread t
        JOIN bbs.forum_forum f ON f.fid = t.fid
        WHERE #{DiscuzCategoryEligibility.sql_condition("f")} AND t.special = 1
        ORDER BY CRC32(CONCAT('sinofsx-discuz-poll-v1:', t.tid)), t.tid
        LIMIT #{EDGE_TOPICS_PER_KIND}
      SQL
      "attachment_threads" => <<~SQL,
        SELECT DISTINCT t.tid FROM bbs.forum_thread t
        JOIN bbs.forum_forum f ON f.fid = t.fid
        JOIN bbs.forum_post p ON p.tid = t.tid
        JOIN bbs.forum_attachment a ON a.pid = p.pid
        WHERE #{DiscuzCategoryEligibility.sql_condition("f")}
        ORDER BY CRC32(CONCAT('sinofsx-discuz-attachment-v1:', t.tid)), t.tid
        LIMIT #{EDGE_TOPICS_PER_KIND}
      SQL
    }
    edge_queries.each_value { |sql| ids.concat(query(sql).map { |row| row["tid"].to_i }) }
    ids.uniq.sort
  end

  def sample_pm_threads
    ids = SHARDS.flat_map { |shard| query(<<~SQL).map { |row| row["plid"].to_i } }
        SELECT DISTINCT plid FROM ucenter.pm_messages_#{shard}
         ORDER BY CRC32(CONCAT('sinofsx-discuz-pm-v1-#{shard}:', plid)), plid
         LIMIT #{PM_THREADS_PER_SHARD}
      SQL
    ids.uniq.sort
  end

  def selected_pm_rows(thread_ids)
    SHARDS.flat_map do |shard|
      query(
        "SELECT pmid id, plid thread_id, authorid uid, #{shard} shard FROM ucenter.pm_messages_#{shard} WHERE plid IN (#{csv(thread_ids)})",
      )
    end
  end

  def source_counts_snapshot
    pm_counts =
      SHARDS.to_h do |shard|
        [
          "pm_messages_#{shard}",
          query("SELECT COUNT(*) count FROM ucenter.pm_messages_#{shard}").first["count"].to_i,
        ]
      end
    {
      members: query("SELECT COUNT(*) count FROM (#{member_union}) members").first["count"].to_i,
      categories:
        query(
          "SELECT COUNT(*) count FROM bbs.forum_forum WHERE #{DiscuzCategoryEligibility.sql_condition}",
        ).first[
          "count"
        ].to_i,
      threads: query("SELECT COUNT(*) count FROM bbs.forum_thread").first["count"].to_i,
      posts: query("SELECT COUNT(*) count FROM bbs.forum_post").first["count"].to_i,
      pm_messages_by_shard: pm_counts,
    }
  end

  def csv(ids)
    values = ids.map { |id| Integer(id) }.uniq
    values.empty? ? "0" : values.join(",")
  end

  def query(sql)
    @source.query(sql, cache_rows: false).to_a
  end
end

DiscuzSampleBuilder.new.run
