# encoding: utf-8
# frozen_string_literal: true

#
# Author: Erick Guan <fantasticfears@gmail.com>
#
# This script import the data from latest Discuz! X
# Should work among Discuz! X3.x
# This script is tested only on Simplified Chinese Discuz! X instances
# If you want to import data other than Simplified Chinese, email me.

require "json"
require "php_serialize"
require "mysql2"
require_relative "base"
require_relative "../../tools/discuz_migration/category_permissions"
require_relative "../../tools/discuz_migration/category_eligibility"
require_relative "../../tools/discuz_migration/medals"
require_relative "../../tools/discuz_migration/smilies"

class ImportScripts::DiscuzX < ImportScripts::Base
  DISCUZX_DB = ENV.fetch("DISCUZX_DB", "bbs")
  UCENTER_DB = ENV.fetch("UCENTER_DB", "ucenter")
  DB_TABLE_PREFIX = ENV.fetch("DISCUZX_TABLE_PREFIX", "")
  DB_HOST = ENV.fetch("DISCUZX_DB_HOST", "127.0.0.1")
  DB_PORT = Integer(ENV.fetch("DISCUZX_DB_PORT", "13306"))
  BATCH_SIZE = 1000
  DISCUZ_QUOTE_TAG = %r{\[/?quote(?:=[^\]]*)?\]}i
  DISCUZ_QUOTE_HEADER =
    %r{
    \A[ \t]*
    (?:\[size=[^\]]+\])?\s*
    (?:\[url=[^\]]+\])?\s*
    \[color=[^\]]+\]
    (?<label>[^\[\]]*?发表于[^\[\]]*)
    \[/color\]
    (?:\[/url\])?
    (?:[ \t]*\[url=[^\]]+\][^\[]*\[/url\])?
    (?:\[/size\])?
    [ \t]*(?:\r?\n)?
  }ix
  DISCUZ_SOURCE = "discuz_x3.5"
  ORIGINAL_SITE_PREFIX = ENV.fetch("DISCUZX_ORIGINAL_SITE_PREFIX", "bbs.sinofsx.org")
  NEW_SITE_PREFIX = ENV.fetch("DISCUZX_NEW_SITE_PREFIX", "http://127.0.0.1:3000")
  DISCUZX_BASE_DIR = ENV.fetch("DISCUZX_BASE_DIR", "/Users/daren/discourse-lab/discuz-files")
  AVATAR_DIR = ENV.fetch("DISCUZX_AVATAR_DIR", "uc_server/data/avatar")
  ATTACHMENT_DIR = ENV.fetch("DISCUZX_ATTACHMENT_DIR", "data/attachment/forum")
  AUTHORIZED_EXTENSIONS = %w[jpg jpeg png gif zip rar pdf]
  ALLOWED_TARGET_DATABASES = %w[
    discourse_development
    discourse_migration_sample
    discourse_migration_sample_uid18_20261013
  ].freeze

  def initialize
    super
    @sample_manifest = load_sample_manifest

    unless DB_HOST == "127.0.0.1" && DB_PORT == 13_306 && DISCUZX_DB == "bbs" &&
             UCENTER_DB == "ucenter" && DB_TABLE_PREFIX.empty?
      raise "Discuz source must be the local bbs/ucenter snapshot on 127.0.0.1:13306"
    end
    target_database = ENV.fetch("DISCOURSE_DEV_DB", "discourse_development")
    sample_target_matches =
      (
        if @sample_manifest
          target_database == @sample_manifest.fetch("target_database", "discourse_migration_sample")
        else
          target_database == "discourse_development"
        end
      )
    unless ENV["PGHOST"] == "127.0.0.1" && Integer(ENV.fetch("PGPORT", "0")) == 15_432 &&
             ALLOWED_TARGET_DATABASES.include?(target_database) && sample_target_matches &&
             ActiveRecord::Base.connection.select_value("SELECT current_database()") ==
               target_database
      raise "Discourse target must be an approved local migration database on 127.0.0.1:15432"
    end

    @client =
      Mysql2::Client.new(
        host: DB_HOST,
        port: DB_PORT,
        username: ENV.fetch("DISCUZX_DB_USER"),
        password: ENV.fetch("MYSQL_PWD"),
        database: DISCUZX_DB,
        encoding: "utf8mb4",
        connect_timeout: 5,
        read_timeout: 120,
        write_timeout: 120,
        get_server_public_key: true,
      )
    @client.query("SET SESSION TRANSACTION READ ONLY")
    @first_post_id_by_topic_id = {}
    @deferred_visibility_actions = []
    @source_skip_counts = Hash.new(0)
    @category_access_summary = Hash.new(0)
    @seen_pm_thread_ids = Set.new
    @unimportable_pm_thread_ids = Set.new

    @internal_url_regexps = [
      %r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\\.')}/forum\.php\?mod=viewthread(?:&|&amp;)tid=(?<tid>\d+)(?:[^\[\]\s]*)(?:pid=?(?<pid>\d+))?(?:[^\[\]\s]*)},
      %r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\\.')}/viewthread\.php\?tid=(?<tid>\d+)(?:[^\[\]\s]*)(?:pid=?(?<pid>\d+))?(?:[^\[\]\s]*)},
      %r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\\.')}/forum\.php\?mod=redirect(?:&|&amp;)goto=findpost(?:&|&amp;)pid=(?<pid>\d+)(?:&|&amp;)ptid=(?<tid>\d+)(?:[^\[\]\s]*)},
      %r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\\.')}/redirect\.php\?goto=findpost(?:&|&amp;)pid=(?<pid>\d+)(?:&|&amp;)ptid=(?<tid>\d+)(?:[^\[\]\s]*)},
      %r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\\.')}/forumdisplay\.php\?fid=(?<fid>\d+)(?:[^\[\]\s]*)},
      %r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\\.')}/forum\.php\?mod=forumdisplay(?:&|&amp;)fid=(?<fid>\d+)(?:[^\[\]\s]*)},
      %r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\\.')}/(?<action>index)\.php(?:[^\[\]\s]*)},
      %r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\\.')}/(?<action>stats)\.php(?:[^\[\]\s]*)},
      %r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\\.')}/misc\.php\?mod=(?<mod>stat|ranklist)(?:[^\[\]\s]*)},
    ]
  end

  def execute
    validate_attachment_snapshot! if ENV["DISCUZX_IMPORT_ATTACHMENTS"] == "1"
    validate_sample_source! if @sample_manifest
    stage = ENV.fetch("DISCUZX_IMPORT_STAGE", "all")
    if %w[all identity content categories attachments attachment_metadata medals].exclude?(stage)
      raise "DISCUZX_IMPORT_STAGE must be all, identity, content, categories, attachments, attachment_metadata, or medals"
    end
    raise "sample stages require a sample manifest" if stage != "all" && !@sample_manifest
    if stage == "attachments" && !attachments_enabled?
      raise "attachment stage requires DISCUZX_IMPORT_ATTACHMENTS=1"
    end
    if ENV["DISCUZX_ATTACHMENT_IDS"].present? && %w[attachments attachment_metadata].exclude?(stage)
      raise "DISCUZX_ATTACHMENT_IDS can only be used with an attachment import stage"
    end
    requested_attachment_ids = requested_discuz_attachment_ids if %w[
      attachments
      attachment_metadata
    ].include?(stage)
    if stage == "attachments" && requested_attachment_ids.present?
      validate_requested_attachment_files!(requested_attachment_ids)
    end
    if stage == "attachment_metadata" && requested_attachment_ids.present?
      validate_requested_attachment_metadata!(requested_attachment_ids)
    end

    configure_site_for_discuz_import!

    if stage == "attachments"
      import_attachments
      puts "Sample attachment stage complete; users, categories, topics, and messages were untouched"
      report_source_skips
      return
    end

    if stage == "attachment_metadata"
      import_attachment_metadata
      puts "Sample attachment metadata stage complete; source objects were not read or copied"
      report_source_skips
      return
    end

    if stage == "medals"
      validate_existing_discuz_user_mappings!
      import_discuz_medals
      puts "Sample medal stage complete; other imported records were untouched"
      report_source_skips
      return
    end

    if stage == "categories"
      @skip_updates = true
      import_categories
      prepare_site_for_discuz_import!
      puts "Sample category stage complete; user identities, posts, and messages were untouched"
      report_source_skips
      return
    end

    validate_existing_discuz_user_mappings!
    get_duplicate_email_uids
    import_users
    import_unrepresented_users
    import_categories
    if stage == "identity"
      prepare_site_for_discuz_import!
      puts "Sample identity stage complete; posts, messages, avatars, and attachments were not imported"
      report_source_skips
      return
    end
    import_posts
    import_private_messages
    if ENV["DISCUZX_IMPORT_ATTACHMENTS"] == "1"
      import_attachments
    else
      attachment_filter = " WHERE pid IN (#{sample_id_sql("post_ids")})" if @sample_manifest
      @source_skip_counts["attachments_deferred_until_snapshot"] = mysql_query(
        "SELECT count(*) count FROM #{table_name("forum_attachment")}#{attachment_filter};",
      ).first[
        "count"
      ].to_i
      avatar_filter = " AND uid IN (#{sample_id_sql("member_uids")})" if @sample_manifest
      @source_skip_counts["avatars_deferred_until_snapshot"] = mysql_query(
        "SELECT count(*) count FROM (#{source_member_union}) members WHERE avatarstatus = 1#{avatar_filter}",
      ).first[
        "count"
      ].to_i
      puts "Attachment import deferred until a local read-only attachment snapshot is available"
    end
    import_discuz_medals if stage == "all"
    prepare_site_for_discuz_import!
    report_source_skips
  end

  def validate_existing_discuz_user_mappings!
    import_fields = UserCustomField.where(name: "import_id").pluck(:user_id, :value)
    numeric_import_fields =
      import_fields.select { |_user_id, value| value.to_s.match?(/\A[1-9]\d*\z/) }
    return if numeric_import_fields.empty?

    source_by_user = UserCustomField.where(name: "discuz_source").pluck(:user_id, :value).to_h
    uid_by_user = UserCustomField.where(name: "discuz_uid").pluck(:user_id, :value).to_h
    import_id_by_user = numeric_import_fields.to_h
    invalid_user_ids =
      numeric_import_fields.filter_map do |user_id, import_id|
        if source_by_user[user_id] != DISCUZ_SOURCE || uid_by_user[user_id].to_s != import_id.to_s
          user_id
        end
      end
    invalid_user_ids.concat(
      source_by_user.filter_map do |user_id, source|
        next unless source == DISCUZ_SOURCE
        next if import_id_by_user[user_id].to_s == uid_by_user[user_id].to_s

        user_id
      end,
    )
    invalid_user_ids.uniq!

    if invalid_user_ids.any?
      raise "target contains #{invalid_user_ids.length} imported user mapping(s) without matching Discuz source markers; use a clean migration database before importing"
    end
  end

  def prepare_site_for_discuz_import!
    remove_untouched_general_category!
    configure_default_sidebar_categories!
  end

  def remove_untouched_discourse_seed_content!
    require "seed_data/topics"
    seed_topic_settings = %w[guidelines_topic_id welcome_topic_id admin_quick_start_topic_id]
    original_topic_ids = seed_topic_settings.to_h { |name| [name, SiteSetting.get(name).to_i] }
    safe_seed_topics =
      original_topic_ids.filter_map do |setting_name, topic_id|
        next unless topic_id.positive?

        topic = Topic.find_by(id: topic_id)
        next unless topic && topic.deleted_at.blank?

        posts = Post.with_deleted.where(topic_id: topic_id)
        next if posts.empty?
        next if posts.where.not(user_id: Discourse::SYSTEM_USER_ID).exists?
        next if posts.where.not(last_editor_id: Discourse::SYSTEM_USER_ID).exists?
        next if PostCustomField.exists?(post_id: posts.select(:id), name: "import_id")
        next if TopicCustomField.exists?(topic_id: topic_id, name: "import_id")

        setting_name
      end
    SeedData::Topics.with_default_locale.delete(
      site_setting_names: safe_seed_topics,
      skip_changed: true,
    )

    # Positive IDs tell Discourse seed fixtures these topics were already initialized.
    removed =
      safe_seed_topics.filter do |setting_name|
        !Topic.exists?(id: original_topic_ids.fetch(setting_name))
      end

    puts "Removed #{removed.length} untouched default Discourse topic(s); retained retired IDs to prevent reseeding"
    remove_untouched_default_categories!(original_topic_ids.values)
  end

  def remove_untouched_default_categories!(seed_topic_ids)
    require "seed_data/categories"
    category_settings = { "meta_category_id" => "site-feedback", "staff_category_id" => "staff" }

    removals =
      category_settings.filter_map do |setting_name, expected_slug|
        category_id = SiteSetting.get(setting_name).to_i
        category = Category.find_by(id: category_id) if category_id.positive?
        next unless category

        reasons, chat_channels =
          default_category_removal_check(category, expected_slug, seed_topic_ids)
        if reasons.any?
          raise "refusing to remove default category #{setting_name} (#{category.id}): #{reasons.join("; ")}"
        end

        { setting_name: setting_name, category: category, chat_channels: chat_channels }
      end

    return if removals.empty?

    ActiveRecord::Base.transaction do
      removals.each do |removal|
        category = removal.fetch(:category)
        removal
          .fetch(:chat_channels)
          .each do |channel|
            channel
              .user_chat_channel_memberships
              .where(join_mode: Chat::UserChatChannelMembership.join_modes[:automatic])
              .delete_all
            channel.destroy!
          end
        CategoryFeaturedTopic.where(category_id: category.id).delete_all
        sidebar_ids = SiteSetting.default_navigation_menu_categories.split("|")
        if sidebar_ids.include?(category.id.to_s)
          SiteSetting.default_navigation_menu_categories =
            (sidebar_ids - [category.id.to_s]).join("|")
        end

        category.destroy!
        # Keep the positive ID as a tombstone so core seed data will not recreate this category.
        SiteSetting.set(removal.fetch(:setting_name), category.id)
      end
    end

    removals.each do |removal|
      category = removal.fetch(:category)
      puts "Removed untouched default Discourse category #{removal.fetch(:setting_name)} (#{category.id})"
    end
  end

  def default_category_removal_check(category, expected_slug, seed_topic_ids)
    reasons = []
    reasons << "slug changed to #{category.slug}" unless category.slug == expected_slug
    reasons << "category is not system-owned" unless category.user_id == Discourse::SYSTEM_USER_ID
    if CategoryCustomField.exists?(category_id: category.id, name: "import_id")
      reasons << "category has a Discuz import marker"
    end
    reasons << "category has child categories" if category.has_children?
    unless SeedData::Categories.with_default_locale.send(:unchanged?, category)
      reasons << "category definition was edited"
    end

    allowed_topic_ids = ([category.topic_id] + seed_topic_ids).compact.uniq
    category_topics = Topic.with_deleted.where(category_id: category.id)
    allowed_topic_ids.concat(safe_deleted_default_topic_ids(category_topics, allowed_topic_ids))
    unexpected_topic_ids = category_topics.where.not(id: allowed_topic_ids).pluck(:id)
    if unexpected_topic_ids.any?
      reasons << "contains non-seed topics #{unexpected_topic_ids.join(",")}"
    end

    safe_topic_ids = category_topics.where(id: allowed_topic_ids).pluck(:id)
    posts = Post.with_deleted.where(topic_id: safe_topic_ids)
    if posts.where.not(user_id: Discourse::SYSTEM_USER_ID).exists?
      reasons << "contains non-system posts"
    end
    if posts.where.not(last_editor_id: Discourse::SYSTEM_USER_ID).exists?
      reasons << "contains non-system edits"
    end
    if posts
         .where.not(deleted_by_id: nil)
         .where.not(deleted_by_id: Discourse::SYSTEM_USER_ID)
         .exists?
      reasons << "contains user-deleted posts"
    end
    if PostCustomField.exists?(post_id: posts.select(:id), name: "import_id")
      reasons << "contains Discuz post markers"
    end
    if TopicCustomField.exists?(topic_id: safe_topic_ids, name: "import_id")
      reasons << "contains Discuz topic markers"
    end
    reasons << "has category followers" if CategoryUser.where(category_id: category.id).exists?
    reasons << "has category tags" if category.category_tags.exists?
    unexpected_featured_topics =
      CategoryFeaturedTopic.where(category_id: category.id).where.not(topic_id: allowed_topic_ids)
    reasons << "has non-definition featured topics" if unexpected_featured_topics.exists?

    chat_channels = []
    if defined?(Chat::Channel)
      chat_channels = Chat::Channel.where(chatable_type: "Category", chatable_id: category.id).to_a
      chat_channels.each do |channel|
        chat_content = []
        chat_content << "messages" if channel.chat_messages.with_deleted.exists?
        chat_content << "threads" if channel.threads.exists?
        automatic_memberships =
          channel.user_chat_channel_memberships.where(
            join_mode: Chat::UserChatChannelMembership.join_modes[:automatic],
          )
        if channel
             .user_chat_channel_memberships
             .where.not(id: automatic_memberships.select(:id))
             .exists?
          chat_content << "manual memberships"
        end
        if !untouched_default_category_chat_channel?(channel, category)
          reasons << "chat channel #{channel.id} was edited"
        end
        chat_content << "pinned messages" if channel.pinned_messages.exists?
        chat_content << "archive" if channel.chat_channel_archive.present?
        chat_content << "drafts" if Chat::Draft.where(chat_channel_id: channel.id).exists?
        if Chat::IncomingWebhook.where(chat_channel_id: channel.id).exists?
          chat_content << "webhooks"
        end
        if Chat::ChannelCustomField.where(channel_id: channel.id).exists?
          chat_content << "custom fields"
        end
        chat_content << "last-message reference" if channel.last_message_id.present?
        reasons << "chat channel #{channel.id} has #{chat_content.join(", ")}" if chat_content.any?
      end
    end

    [reasons, chat_channels]
  end

  def untouched_default_category_chat_channel?(channel, category)
    channel.is_a?(Chat::CategoryChannel) && channel.name == category.name &&
      channel.slug == category.slug && channel.description.blank? && channel.status == "open" &&
      channel.auto_join_users? && channel.allow_channel_wide_mentions? &&
      !channel.threading_enabled? && channel.emoji.blank? && channel.deleted_at.blank? &&
      channel.delete_after_seconds.blank?
  end

  def safe_deleted_default_topic_ids(category_topics, known_topic_ids)
    candidates =
      category_topics
        .where.not(id: known_topic_ids)
        .where.not(deleted_at: nil)
        .where(user_id: Discourse::SYSTEM_USER_ID, deleted_by_id: Discourse::SYSTEM_USER_ID)
        .pluck(:id)
    return [] if candidates.empty?

    posts = Post.with_deleted.where(topic_id: candidates)
    posted_topic_ids = posts.distinct.pluck(:topic_id).to_set
    unsafe_topic_ids = Set.new
    unsafe_topic_ids.merge(
      posts.where.not(user_id: Discourse::SYSTEM_USER_ID).distinct.pluck(:topic_id),
    )
    unsafe_topic_ids.merge(
      posts.where.not(last_editor_id: Discourse::SYSTEM_USER_ID).distinct.pluck(:topic_id),
    )
    unsafe_topic_ids.merge(
      posts
        .where.not(deleted_by_id: nil)
        .where.not(deleted_by_id: Discourse::SYSTEM_USER_ID)
        .distinct
        .pluck(:topic_id),
    )

    marker_post_ids =
      PostCustomField.where(name: "import_id", post_id: posts.select(:id)).pluck(:post_id)
    if marker_post_ids.any?
      unsafe_topic_ids.merge(Post.with_deleted.where(id: marker_post_ids).distinct.pluck(:topic_id))
    end
    unsafe_topic_ids.merge(
      TopicCustomField.where(name: "import_id", topic_id: candidates).pluck(:topic_id),
    )

    ((candidates.to_set & posted_topic_ids) - unsafe_topic_ids).to_a
  end

  def configure_default_sidebar_categories!
    if @category_rows_by_id.blank?
      raise "Discuz categories must be imported before configuring the sidebar"
    end

    source_category_ids =
      @category_rows_by_id.values.filter_map do |row|
        next unless DiscuzCategoryEligibility.importable?(row)

        row["id"].to_i
      end
    target_category_ids =
      source_category_ids
        .filter_map { |source_id| category_id_from_imported_category_id(source_id) }
        .uniq

    if target_category_ids.length != source_category_ids.uniq.length
      raise "not all importable Discuz categories have mappings; refusing to configure an incomplete sidebar"
    end

    target_category_ids = Category.where(id: target_category_ids).order(:position, :id).pluck(:id)
    if target_category_ids.length != source_category_ids.uniq.length
      raise "one or more imported Discuz categories are missing from the Discourse database"
    end

    desired_categories = target_category_ids.join("|")
    SiteSetting.default_navigation_menu_categories =
      desired_categories unless SiteSetting.default_navigation_menu_categories == desired_categories

    unless SiteSetting.default_navigation_menu_categories == desired_categories
      raise "failed to configure the default sidebar categories for Discuz import"
    end

    puts "Configured #{target_category_ids.length} imported Discuz categories as default sidebar links"
  end

  def configure_site_for_discuz_import!
    SiteSetting.default_locale = "zh_CN"
    SiteSetting.unicode_usernames = true

    unless SiteSetting.default_locale == "zh_CN" && SiteSetting.unicode_usernames
      raise "Discuz import requires the global zh_CN locale and Unicode usernames setting"
    end

    puts "Enabled required global settings before import: default_locale=zh_CN, unicode_usernames=true"
  end

  def remove_untouched_general_category!
    category_id = SiteSetting.general_category_id.to_i
    return false unless category_id.positive?

    category = Category.find_by(id: category_id)
    return false unless category
    return false if CategoryCustomField.exists?(category_id: category.id, name: "import_id")

    reasons = []
    reasons << "slug is not general" unless category.slug == "general"
    reasons << "has child categories" if category.has_children?
    reasons << "has active topics" if category.topic_count.positive?

    require "seed_data/categories"
    seed_categories = SeedData::Categories.with_default_locale
    reasons << "category definition was edited" unless seed_categories.send(:unchanged?, category)

    non_seed_topic_ids =
      Topic
        .with_deleted
        .where(category_id: category.id)
        .where.not(id: category.topic_id)
        .reject do |topic|
          next false unless topic.deleted_at.present? && topic.user_id == Discourse::SYSTEM_USER_ID

          posts = Post.with_deleted.where(topic_id: topic.id)
          posts.exists? && !posts.where.not(user_id: Discourse::SYSTEM_USER_ID).exists? &&
            !posts.where.not(last_editor_id: Discourse::SYSTEM_USER_ID).exists? &&
            !PostCustomField.exists?(post_id: posts.select(:id), name: "import_id") &&
            !TopicCustomField.exists?(topic_id: topic.id, name: "import_id")
        end
        .map(&:id)
    reasons << "has non-seed topics #{non_seed_topic_ids.join(",")}" if non_seed_topic_ids.any?

    if reasons.any?
      puts "Preserved default category #{category.id} (#{category.name}): #{reasons.join("; ")}"
      return false
    end

    ActiveRecord::Base.transaction do
      category.destroy!
      menu_category_ids = SiteSetting.default_navigation_menu_categories.split("|")
      if menu_category_ids.include?(category_id.to_s)
        SiteSetting.default_navigation_menu_categories =
          (menu_category_ids - [category_id.to_s]).join("|")
      end
    end
    puts "Removed untouched default General category #{category_id}"
    true
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

  def reserved_discuz_email(uid)
    suffix = 0
    loop do
      local_part = "discuz-uid-#{uid}"
      local_part = "#{local_part}-#{suffix}" if suffix.positive?
      email = "#{local_part}@users.invalid"
      return email if UserEmail.find_by_normalized(email).nil?

      suffix += 1
    end
  end

  def validate_attachment_snapshot!
    expanded_root = File.expand_path(DISCUZX_BASE_DIR)
    lab_root = File.expand_path("/Users/daren/discourse-lab")
    real_root = File.realpath(expanded_root)
    unless real_root.start_with?("#{lab_root}/") && File.directory?(real_root)
      raise "attachment import requires a local snapshot under #{lab_root}"
    end
  end

  def attachments_enabled?
    ENV["DISCUZX_IMPORT_ATTACHMENTS"] == "1"
  end

  def snapshot_file(path)
    root = File.realpath(DISCUZX_BASE_DIR)
    candidate = File.expand_path(path, root)
    return unless candidate.start_with?("#{root}/") && File.file?(candidate)

    resolved = File.realpath(candidate)
    resolved if resolved.start_with?("#{root}/")
  rescue Errno::ENOENT
    nil
  end

  def table_name(name = nil)
    qualified_table_name(DISCUZX_DB, "#{DB_TABLE_PREFIX}#{name}")
  end

  def ucenter_table_name(name)
    qualified_table_name(UCENTER_DB, name)
  end

  def qualified_table_name(database, table)
    raise "invalid database identifier" unless database.match?(/\A[a-zA-Z0-9_]+\z/)
    raise "invalid table identifier" unless table.match?(/\A[a-zA-Z0-9_]+\z/)

    "`#{database}`.`#{table}`"
  end

  def load_sample_manifest
    path = ENV["DISCUZX_SAMPLE_MANIFEST"]
    return nil if path.blank?

    lab_root = File.realpath("/Users/daren/discourse-lab")
    expanded = File.expand_path(path)
    real_path = File.realpath(expanded)
    unless real_path.start_with?("#{lab_root}/") && File.file?(real_path)
      raise "sample manifest must be a file under /Users/daren/discourse-lab"
    end
    raise "sample manifest permissions must be 0600" if (File.stat(real_path).mode & 0o077).nonzero?

    manifest = JSON.parse(File.read(real_path))
    raise "unsupported sample manifest version" unless manifest["version"] == 1
    sample_database = manifest.fetch("target_database", "discourse_migration_sample")
    if %w[discourse_migration_sample discourse_migration_sample_uid18_20261013].exclude?(
         sample_database,
       )
      raise "sample manifest target database is not approved"
    end
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

  def sample_ids(key)
    @sample_manifest ? @sample_manifest.fetch(key).map(&:to_i) : []
  end

  def sample_id_sql(key)
    ids = sample_ids(key)
    ids.empty? ? "0" : ids.join(",")
  end

  def validate_sample_source!
    expected = @sample_manifest.fetch("source_counts")
    actual_members =
      mysql_query("SELECT count(*) count FROM (#{source_member_union}) members").first["count"].to_i
    actual_categories =
      mysql_query(
        "SELECT count(*) count FROM #{table_name("forum_forum")} WHERE #{DiscuzCategoryEligibility.sql_condition}",
      ).first[
        "count"
      ].to_i
    actual_threads =
      mysql_query("SELECT count(*) count FROM #{table_name("forum_thread")}").first["count"].to_i
    actual_posts =
      mysql_query("SELECT count(*) count FROM #{table_name("forum_post")}").first["count"].to_i
    unless [actual_members, actual_categories, actual_threads, actual_posts] ==
             [
               expected.fetch("members"),
               expected.fetch("categories"),
               expected.fetch("threads"),
               expected.fetch("posts"),
             ].map(&:to_i)
      raise "sample manifest source counts no longer match this baseline"
    end

    expected
      .fetch("pm_messages_by_shard")
      .each do |table, count|
        shard = table.delete_prefix("pm_messages_")
        raise "invalid PM shard in sample manifest" unless shard.match?(/\A[0-9]\z/)
        actual =
          mysql_query(
            "SELECT count(*) count FROM #{ucenter_table_name("pm_messages_#{shard}")}",
          ).first[
            "count"
          ].to_i
        unless actual == count.to_i
          raise "sample manifest PM source counts no longer match this baseline"
        end
      end
  end

  def source_member_union
    active = table_name("common_member")
    archived = table_name("common_member_archive")

    <<~SQL
      SELECT uid, username, email, groupid, emailstatus, avatarstatus
        FROM #{active}
      UNION ALL
      SELECT archived.uid, archived.username, archived.email,
             archived.groupid, archived.emailstatus, archived.avatarstatus
        FROM #{archived} archived
       WHERE NOT EXISTS (
         SELECT 1 FROM #{active} active WHERE active.uid = archived.uid
       )
    SQL
  end

  # find which group members can be granted as admin
  def get_knowledge_about_group
    group_table = table_name "common_usergroup"
    result =
      mysql_query(
        "SELECT groupid group_id, radminid role_id
             FROM #{group_table};",
      )
    @moderator_group_id = []
    @admin_group_id = []
    #@banned_group_id = [4,5] # 禁止的用户及其帖子均不导入，如果你想导入这些用户和帖子，请把这个数组清空。

    result.each do |group|
      case group["role_id"]
      when 1 # 管理员
        @admin_group_id << group["group_id"]
      when 2,
           3 # 超级版主、版主。如果你不希望原普通版主成为Discourse版主，把3去掉。
        @moderator_group_id << group["group_id"]
      end
    end
  end

  def get_knowledge_about_category_slug
    @category_slug = {}
    results =
      mysql_query(
        "SELECT svalue value
      FROM #{table_name "common_setting"}
      WHERE skey = 'forumkeys'",
      )

    return if results.size < 1
    value = results.first["value"]

    return if value.blank?

    PHP
      .unserialize(value)
      .each do |category_import_id, slug|
        next if slug.blank?
        @category_slug[category_import_id] = slug
      end
  end

  def source_referenced_uid_union
    pm_member_table = ucenter_table_name("pm_members")
    pm_list_table = ucenter_table_name("pm_lists")
    posts_table = table_name("forum_post")
    message_tables = (0..9).map { |shard| ucenter_table_name("pm_messages_#{shard}") }
    pm_authors =
      message_tables.map { |table| "SELECT DISTINCT authorid uid FROM #{table}" }.join("\nUNION\n")

    <<~SQL
      SELECT DISTINCT authorid uid FROM #{posts_table}
      UNION
      SELECT DISTINCT uid FROM #{pm_member_table} WHERE uid > 0
      UNION
      #{pm_authors}
      UNION
      SELECT CAST(SUBSTRING_INDEX(min_max, '_', 1) AS UNSIGNED) uid
        FROM #{pm_list_table}
       WHERE pmtype = 1 AND min_max REGEXP '^[0-9]+_[0-9]+$'
      UNION
      SELECT CAST(SUBSTRING_INDEX(min_max, '_', -1) AS UNSIGNED) uid
        FROM #{pm_list_table}
       WHERE pmtype = 1 AND min_max REGEXP '^[0-9]+_[0-9]+$'
    SQL
  end

  def sample_referenced_uid_union
    post_authors =
      "SELECT DISTINCT authorid uid FROM #{table_name("forum_post")} WHERE authorid > 0 AND tid IN (#{sample_id_sql("topic_ids")})"
    pm_authors =
      (0..9)
        .map do |shard|
          "SELECT DISTINCT authorid uid FROM #{ucenter_table_name("pm_messages_#{shard}")} WHERE authorid > 0 AND plid IN (#{sample_id_sql("pm_thread_ids")})"
        end
        .join("\nUNION\n")
    pm_members =
      "SELECT DISTINCT uid FROM #{ucenter_table_name("pm_members")} WHERE uid > 0 AND plid IN (#{sample_id_sql("pm_thread_ids")})"
    pm_list_table = ucenter_table_name("pm_lists")
    pm_pair_participants = <<~SQL
      SELECT CAST(SUBSTRING_INDEX(min_max, '_', 1) AS UNSIGNED) uid
        FROM #{pm_list_table}
       WHERE pmtype = 1 AND min_max REGEXP '^[0-9]+_[0-9]+$'
         AND plid IN (#{sample_id_sql("pm_thread_ids")})
      UNION
      SELECT CAST(SUBSTRING_INDEX(min_max, '_', -1) AS UNSIGNED) uid
        FROM #{pm_list_table}
       WHERE pmtype = 1 AND min_max REGEXP '^[0-9]+_[0-9]+$'
         AND plid IN (#{sample_id_sql("pm_thread_ids")})
    SQL
    [post_authors, pm_members, pm_authors, pm_pair_participants].join("\nUNION\n")
  end

  def import_unrepresented_users
    puts "", "creating placeholders for referenced UIDs without BBS member rows"

    references = @sample_manifest ? sample_referenced_uid_union : source_referenced_uid_union
    members = source_member_union
    ucenter_members = ucenter_table_name("members")
    results = mysql_query(<<~SQL)
          SELECT refs.uid id, uc.username, uc.email, uc.regdate,
                 uc.password password_hash, uc.salt
            FROM (#{references}) refs
            LEFT JOIN (#{members}) known ON known.uid = refs.uid
            LEFT JOIN #{ucenter_members} uc ON uc.uid = refs.uid
           WHERE known.uid IS NULL AND refs.uid > 0
           ORDER BY refs.uid ASC
        SQL

    return if results.size.zero?

    puts "Creating #{results.size} non-login placeholder account(s) for source references"
    create_users(results, total: results.size) do |user|
      uid = user["id"].to_i
      {
        id: uid,
        email: reserved_discuz_email(uid),
        username: first_exists(user["username"], "discuz_unknown_#{uid}"),
        name: first_exists(user["username"], "Unavailable Discuz account #{uid}"),
        discuz_password_hash: user["password_hash"],
        discuz_password_salt: user["salt"],
        custom_fields: {
          "discuz_missing_bbs_member" => true,
        },
        active: false,
        created_at: user["regdate"] ? Time.zone.at(user["regdate"]) : nil,
      }
    end
  end

  def get_duplicate_email_uids
    member_union = source_member_union
    normalized_email = source_email_comparison_sql("members.email")
    normalized_candidate_email = source_email_comparison_sql("candidates.email")
    duplicate_uids = mysql_query(<<~SQL)
          SELECT members.uid
            FROM (#{member_union}) members
            JOIN (
              SELECT #{normalized_candidate_email} email_key, MIN(uid) retained_uid
                FROM (#{member_union}) candidates
               WHERE email IS NOT NULL AND TRIM(email) <> ''
               GROUP BY email_key
              HAVING COUNT(*) > 1
            ) duplicates ON #{normalized_email} = duplicates.email_key
           WHERE members.uid <> duplicates.retained_uid
        SQL

    @duplicate_email_uids = Set.new(duplicate_uids.map { |row| row["uid"].to_i })
  end

  def import_users
    puts "", "creating users"

    get_knowledge_about_group

    sensitive_user_table = ucenter_table_name("members")
    user_source = "(#{source_member_union})"
    profile_table = table_name("common_member_profile")
    profile_archive_table = table_name("common_member_profile_archive")
    status_table = table_name("common_member_status")
    status_archive_table = table_name("common_member_status_archive")
    forum_table = table_name("common_member_field_forum")
    forum_archive_table = table_name("common_member_field_forum_archive")
    home_table = table_name("common_member_field_home")
    home_archive_table = table_name("common_member_field_home_archive")
    user_sample_filter = " WHERE uid IN (#{sample_id_sql("member_uids")})" if @sample_manifest
    total_count =
      mysql_query("SELECT count(*) count FROM #{user_source} users#{user_sample_filter};").first[
        "count"
      ]

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(<<~SQL).to_a
            SELECT u.uid id, u.username username, u.email email, u.groupid group_id,
                   su.regdate regdate, su.password password_hash, su.salt salt,
                   COALESCE(s.regip, sa.regip) regip,
                   COALESCE(s.lastip, sa.lastip) last_visit_ip,
                   COALESCE(s.lastvisit, sa.lastvisit) last_visit_time,
                   COALESCE(s.lastpost, sa.lastpost) last_posted_at,
                   COALESCE(s.lastsendmail, sa.lastsendmail) last_emailed_at,
                   u.emailstatus email_confirmed, u.avatarstatus avatar_exists,
                   COALESCE(p.site, pa.site) website,
                   COALESCE(p.address, pa.address) address,
                   COALESCE(p.bio, pa.bio) bio,
                   COALESCE(p.realname, pa.realname) realname,
                   COALESCE(p.qq, pa.qq) qq,
                   COALESCE(p.resideprovince, pa.resideprovince) resideprovince,
                   COALESCE(p.residecity, pa.residecity) residecity,
                   COALESCE(p.residedist, pa.residedist) residedist,
                   COALESCE(p.residecommunity, pa.residecommunity) residecommunity,
                   COALESCE(p.birthprovince, pa.birthprovince) birthprovince,
                   COALESCE(p.birthcity, pa.birthcity) birthcity,
                   COALESCE(p.birthdist, pa.birthdist) birthdist,
                   COALESCE(p.birthcommunity, pa.birthcommunity) birthcommunity,
                   COALESCE(h.spacecss, ha.spacecss) spacecss,
                   COALESCE(h.spacenote, ha.spacenote) spacenote,
                   COALESCE(f.customstatus, fa.customstatus) customstatus,
                   COALESCE(f.sightml, fa.sightml) sightml
              FROM #{user_source} u
              LEFT JOIN #{sensitive_user_table} su USING(uid)
              LEFT JOIN #{profile_table} p USING(uid)
              LEFT JOIN #{profile_archive_table} pa USING(uid)
              LEFT JOIN #{status_table} s USING(uid)
              LEFT JOIN #{status_archive_table} sa USING(uid)
              LEFT JOIN #{forum_table} f USING(uid)
              LEFT JOIN #{forum_archive_table} fa USING(uid)
              LEFT JOIN #{home_table} h USING(uid)
              LEFT JOIN #{home_archive_table} ha USING(uid)
             #{"WHERE u.uid IN (#{sample_id_sql("member_uids")})" if @sample_manifest}
             ORDER BY u.uid ASC
             LIMIT #{BATCH_SIZE}
            OFFSET #{offset};
          SQL

      break if results.size < 1

      activation_rows =
        results.map do |user|
          {
            uid: user["id"].to_i,
            email: user["email"].to_s,
            email_confirmed: user["email_confirmed"].to_s.to_i == 1,
          }
        end
      target_email_conflicts = target_email_conflict_keys(results.map { |user| user["email"] })
      create_users(results, total: total_count, offset: offset) do |user|
        uid = user["id"].to_i
        duplicated_email = @duplicate_email_uids.include?(uid)
        source_email = user["email"].to_s.strip
        email_key = normalized_discuz_email(source_email)
        email_conflict =
          !duplicated_email && email_key.present? && target_email_conflicts.include?(email_key)
        email = duplicated_email || email_conflict ? reserved_discuz_email(uid) : source_email
        custom_fields = {}
        custom_fields["discuz_duplicate_email"] = true if duplicated_email
        custom_fields["discuz_email_conflict"] = true if email_conflict
        custom_fields["discuz_original_email"] = source_email if (
          duplicated_email || email_conflict
        ) && source_email.present?
        signature_raw = user["sightml"].to_s.strip
        if signature_raw.present?
          custom_fields["discuz_signature_html"] = PrettyText.cook(signature_raw, user_id: uid).to_s
        end

        {
          id: uid,
          email: email,
          discuz_email_confirmed: user["email_confirmed"].to_s.to_i == 1,
          username: user["username"],
          name: first_exists(user["realname"], user["customstatus"], user["username"]),
          discuz_password_hash: user["password_hash"],
          discuz_password_salt: user["salt"],
          custom_fields: custom_fields,
          active: true,
          # TODO: title: user['customstatus'], # move custom title to name since discourse can't let user custom title https://meta.discourse.org/t/let-users-custom-their-title/37626
          created_at: discuz_timestamp(user["regdate"]),
          registration_ip_address: user["regip"],
          ip_address: user["last_visit_ip"],
          last_seen_at: discuz_timestamp(user["last_visit_time"]),
          last_emailed_at: discuz_timestamp(user["last_emailed_at"]),
          last_posted_at: discuz_timestamp(user["last_posted_at"]),
          moderator: @moderator_group_id.include?(user["group_id"]),
          admin: @admin_group_id.include?(user["group_id"]),
          website:
            (user["website"] && user["website"].include?(".")) ?
              user["website"].strip :
              if user["qq"] && user["qq"].strip == user["qq"].strip.to_i &&
                   user["qq"].strip.to_i > 10_000
                "http://user.qzone.qq.com/" + user["qq"].strip
              else
                nil
              end,
          bio_raw:
            first_exists(
              user["bio"] && CGI.unescapeHTML(user["bio"]),
              user["sightml"],
              user["spacenote"],
            ).strip[
              0,
              3000
            ],
          location:
            first_exists(
              user["address"],
              (
                if user["resideprovince"].present?
                  [
                    user["resideprovince"],
                    user["residecity"],
                    user["residedist"],
                    user["residecommunity"],
                  ]
                else
                  [
                    user["birthprovince"],
                    user["birthcity"],
                    user["birthdist"],
                    user["birthcommunity"],
                  ]
                end
              ).reject { |location| location.blank? }.join(" "),
            ),
          post_create_action:
            lambda do |newmember|
              if user["avatar_exists"] == 1 && newmember.uploaded_avatar_id.blank? &&
                   attachments_enabled?
                path, filename = discuzx_avatar_fullpath(user["id"])
                avatar_path = snapshot_file(path)
                if avatar_path
                  begin
                    upload = create_upload(newmember.id, avatar_path, filename)
                    if !upload.nil? && upload.persisted?
                      newmember.import_mode = false
                      newmember.create_user_avatar
                      newmember.import_mode = true
                      newmember.user_avatar.update(custom_upload_id: upload.id)
                      newmember.update(uploaded_avatar_id: upload.id)
                    else
                      puts "Error: Upload did not persist!"
                    end
                  rescue SystemCallError => err
                    puts "Could not import avatar: #{err.message}"
                  end
                else
                  @source_skip_counts["avatar_file_missing_from_snapshot"] += 1
                end
              end
              if attachments_enabled? && user["spacecss"].present? &&
                   newmember.user_profile.profile_background_upload.blank?
                if matched = user["spacecss"].match(/body\s*{[^}]*url\('?(.+?)'?\)/i)
                  body_background = matched[1].split(ORIGINAL_SITE_PREFIX, 2).last
                end
                if matched = user["spacecss"].match(/#hd\s*{[^}]*url\('?(.+?)'?\)/i)
                  header_background = matched[1].split(ORIGINAL_SITE_PREFIX, 2).last
                end
                if matched = user["spacecss"].match(/.blocktitle\s*{[^}]*url\('?(.+?)'?\)/i)
                  blocktitle_background = matched[1].split(ORIGINAL_SITE_PREFIX, 2).last
                end
                if matched = user["spacecss"].match(/#ct\s*{[^}]*url\('?(.+?)'?\)/i)
                  content_background = matched[1].split(ORIGINAL_SITE_PREFIX, 2).last
                end

                if body_background || header_background || blocktitle_background ||
                     content_background
                  profile_background =
                    first_exists(
                      header_background,
                      body_background,
                      content_background,
                      blocktitle_background,
                    )
                  card_background =
                    first_exists(
                      content_background,
                      body_background,
                      header_background,
                      blocktitle_background,
                    )
                  profile_background_path = snapshot_file(profile_background)
                  upload =
                    profile_background_path &&
                      create_upload(
                        newmember.id,
                        profile_background_path,
                        File.basename(profile_background),
                      )
                  if upload
                    newmember.user_profile.upload_profile_background upload
                  else
                    @source_skip_counts["profile_background_file_missing_from_snapshot"] += 1
                  end
                  card_background_path = snapshot_file(card_background)
                  upload =
                    card_background_path &&
                      create_upload(
                        newmember.id,
                        card_background_path,
                        File.basename(card_background),
                      )
                  if upload
                    newmember.user_profile.upload_card_background upload
                  else
                    @source_skip_counts["card_background_file_missing_from_snapshot"] += 1
                  end
                end
              end

              user_option = newmember.user_option
              if user_option.email_digests
                user_option.update(email_digests: user["email_confirmed"] == 1)
              end
              if newmember.name.present? && newmember.name == newmember.username
                newmember.update(name: "")
              end
            end,
        }
      end
      reconcile_discuz_user_activation!(activation_rows)
    end
  end

  def discuz_timestamp(value)
    return if value.blank? || value.to_i <= 0

    Time.zone.at(value.to_i)
  end

  def create_user(opts, import_id)
    opts = opts.dup
    opts[:custom_fields] = (opts[:custom_fields] || {}).dup
    opts[:custom_fields]["discuz_source"] = DISCUZ_SOURCE
    opts[:custom_fields]["discuz_uid"] = import_id.to_s
    confirm_discuz_email = opts.delete(:discuz_email_confirmed) == true
    source_email = opts[:email].to_s.strip
    password_hash = opts.delete(:discuz_password_hash)
    password_salt = opts.delete(:discuz_password_salt)
    User.transaction do
      user = super(opts, import_id)
      next user unless user&.persisted?

      unless user.custom_fields["discuz_source"] == DISCUZ_SOURCE &&
               user.custom_fields["discuz_uid"].to_s == import_id.to_s
        raise "refusing to attach Discuz identity to an existing unmarked account for UID #{import_id}"
      end

      user.custom_fields["discuz_password_hash"] = password_hash if password_hash.present?
      user.custom_fields["discuz_password_salt"] = password_salt if password_salt.present?
      user.save_custom_fields if password_hash.present? || password_salt.present?

      activate_discuz_user_from_verified_email!(
        user,
        source_uid: import_id,
        source_email: source_email,
        source_email_confirmed: confirm_discuz_email,
      )

      user
    end
  ensure
    password_hash = nil
    password_salt = nil
  end

  def reconcile_discuz_user_activation!(source_users)
    targets =
      source_users.filter_map do |source_user|
        target_user_id = user_id_from_imported_user_id(source_user[:uid])
        [target_user_id, source_user] if target_user_id
      end
    return 0 if targets.empty?

    users_by_id = User.includes(:email_tokens).where(id: targets.map(&:first)).index_by(&:id)
    activated_count = 0
    confirmed_count = 0
    targets.each do |target_user_id, source_user|
      user = users_by_id[target_user_id]
      uid = source_user[:uid].to_s
      next unless user && user.custom_fields["discuz_source"] == DISCUZ_SOURCE
      next unless user.custom_fields["discuz_uid"].to_s == uid
      next unless user.custom_fields["import_id"].to_s == uid
      next if discuz_custom_field_enabled?(user, "discuz_missing_bbs_member")

      if !user.active?
        user.update!(active: true)
        activated_count += 1
      end
      unless source_user[:email_confirmed] && !@duplicate_email_uids.include?(source_user[:uid])
        next
      end

      confirmed_count += 1 if activate_discuz_user_from_verified_email!(
        user,
        source_uid: source_user[:uid],
        source_email: source_user[:email],
        source_email_confirmed: source_user[:email_confirmed],
      )
    end

    if activated_count.positive?
      puts "Reactivated #{activated_count} imported Discuz member account(s)"
    end
    if confirmed_count.positive?
      puts "Confirmed verified Discuz email status for #{confirmed_count} imported account(s)"
    end
    activated_count + confirmed_count
  end

  def activate_discuz_user_from_verified_email!(
    user,
    source_uid:,
    source_email:,
    source_email_confirmed:
  )
    return false unless source_email_confirmed && user&.persisted?

    fields = user.custom_fields
    return false unless fields["discuz_source"] == DISCUZ_SOURCE
    return false unless fields["discuz_uid"].to_s == source_uid.to_s
    return false unless fields["import_id"].to_s == source_uid.to_s
    return false if discuz_custom_field_enabled?(user, "discuz_duplicate_email")
    return false if discuz_custom_field_enabled?(user, "discuz_email_conflict")
    return false if fields["import_email"].present?
    return false if normalized_discuz_email(source_email).blank?
    return false unless user.email == source_email.to_s.strip.downcase
    return false if user.active? && user.email_confirmed?

    user.activate
    true
  end

  def discuz_custom_field_enabled?(user, field_name)
    %w[true t 1].include?(user.custom_fields[field_name].to_s.downcase)
  end

  def normalized_discuz_email(email)
    return if email.blank? || !EmailAddressValidator.valid_value?(email)

    normalized =
      if SiteSetting.normalize_emails?
        UserEmail.normalize(Email.downcase(email.strip))
      else
        Email.downcase(email.strip)
      end
    normalized.presence
  end

  def target_email_conflict_keys(emails)
    normalized = emails.filter_map { |email| normalized_discuz_email(email) }.uniq
    return Set.new if normalized.empty?

    email_column = SiteSetting.normalize_emails? ? "normalized_email" : "email"
    UserEmail
      .where("LOWER(#{email_column}) IN (?)", normalized.map(&:downcase))
      .pluck(email_column)
      .map(&:downcase)
      .to_set
  end

  def import_categories
    puts "", "creating categories"
    remove_untouched_discourse_seed_content!
    DiscuzCategoryEligibility.ensure_site_nesting!

    get_knowledge_about_category_slug

    forums_table = table_name "forum_forum"
    forums_data_table = table_name "forum_forumfield"

    results =
      mysql_query(
        "
          SELECT f.fid id, f.fup parent_id, f.name, f.type type, f.status status, f.displayorder position,
                 d.description description, d.rules rules, d.icon, d.extra extra,
                 d.viewperm, d.formulaperm, d.password forum_password,
                 d.postperm, d.replyperm,
                 EXISTS (
                   SELECT 1 FROM #{table_name("forum_access")} access
                    WHERE access.fid = f.fid AND access.allowview <> 0
                 ) has_user_view_override
            FROM #{forums_table} f
            LEFT JOIN #{forums_data_table} d USING(fid)
           ORDER BY parent_id ASC, id ASC
        ",
      ).to_a

    @category_rows_by_id = results.index_by { |row| row["id"].to_i }
    @source_medals_enabled =
      mysql_query(
        "SELECT COUNT(*) count FROM #{table_name("forum_medal")} WHERE available = 1",
      ).first[
        "count"
      ].to_i.positive?
    @source_category_read_restricted =
      DiscuzCategoryPermissions.source_category_read_restrictions(
        results,
        medals_enabled: @source_medals_enabled,
      )
    @category_effective_parent_ids =
      DiscuzCategoryEligibility.effective_parent_ids(
        results,
        max_nesting: DiscuzCategoryEligibility::MAX_CATEGORY_NESTING,
      )
    @category_display_names = category_display_names(results)
    restrict_excluded_imported_categories!(results)
    max_position = Category.maximum(:position) || 0
    ordered_results = results.sort_by { |row| [category_depth(row, results), row["id"].to_i] }
    create_categories(ordered_results) do |row|
      next unless DiscuzCategoryEligibility.importable?(row)
      extra = PHP.unserialize(row["extra"]) if row["extra"].present?
      color = extra["namecolor"][1, 6] if extra && extra["namecolor"].present?
      read_restricted = @source_category_read_restricted[row["id"].to_i]

      h = {
        id: row["id"],
        name: @category_display_names.fetch(row["id"].to_i),
        description: process_discuz_category_text(row["description"]),
        position: row["position"].to_i + max_position,
        color: color,
        read_restricted: read_restricted,
        skip_category_definition: true,
        custom_fields: {
          "discuz_rules" => process_discuz_category_text(row["rules"]),
        },
        post_create_action:
          lambda do |category|
            if slug = @category_slug[row["id"]]
              category.update(slug: slug)
            end

            if row["icon"].present? && attachments_enabled?
              icon_path = snapshot_file(File.join(ATTACHMENT_DIR, "../common", row["icon"]))
              upload =
                icon_path &&
                  create_upload(Discourse::SYSTEM_USER_ID, icon_path, File.basename(row["icon"]))
              if upload
                category.uploaded_logo_id = upload.id
                # FIXME: I don't know how to get '/shared' by script. May change to Rails.root
                unless color
                  require "miro" unless defined?(Miro::DominantColors)
                  category.color =
                    Miro::DominantColors.new(File.join("/shared", upload.url)).to_hex.first[1, 6]
                end
                category.save!
              else
                @source_skip_counts["category_icon_file_missing_from_snapshot"] += 1
              end
            elsif row["icon"].present?
              @source_skip_counts["category_icons_deferred_until_snapshot"] += 1
            end

            if row["status"] == 0 || row["status"] == 3
              SiteSetting.default_categories_muted = [
                SiteSetting.default_categories_muted,
                category.id,
              ].reject(&:blank?).join("|")
            end
            category
          end,
      }
      if (parent_source_id = @category_effective_parent_ids[row["id"].to_i])
        h[:parent_category_id] = category_id_from_imported_category_id(parent_source_id) ||
          raise("importable Discuz parent #{parent_source_id} has no Discourse mapping")
      end
      h
    end

    reconcile_imported_category_hierarchy(ordered_results)

    category_access_rows =
      results.filter_map do |row|
        next unless DiscuzCategoryEligibility.importable?(row)

        category_id = category_id_from_imported_category_id(row["id"])
        category = Category.find_by(id: category_id) if category_id
        next unless category

        read_restricted = @source_category_read_restricted[row["id"].to_i]
        write_restricted = DiscuzCategoryPermissions.write_restricted?(row)
        [category, row, read_restricted, write_restricted]
      end

    Category.transaction do
      # Close access bottom-up first, then open source-public categories
      # top-down. This keeps every intermediate tree valid and avoids exposing
      # a category before its parent is public.
      category_access_rows
        .sort_by { |_category, row, _read, _write| [-category_depth(row, results), row["id"].to_i] }
        .each do |category, _row, _read, _write|
          category.set_permissions("staff" => :full)
          category.save!
        end

      category_access_rows
        .sort_by { |_category, row, _read, _write| [category_depth(row, results), row["id"].to_i] }
        .each do |category, row, read_restricted, write_restricted|
          apply_category_access_fallback(category, row, read_restricted, write_restricted)
          @category_access_summary[read_restricted ? "restricted_staff_only" : "public"] += 1
          @category_access_summary["public_read_only"] += 1 if !read_restricted && write_restricted
          if row["has_user_view_override"].to_i.positive?
            @category_access_summary["user_view_overrides_deferred"] += 1
          end
        end
    end

    puts "Category access fallback: #{@category_access_summary.sort.map { |name, count| "#{name}=#{count}" }.join(", ")}"
  end

  def reconcile_imported_category_hierarchy(rows)
    reconciled = 0
    deepest_first =
      rows
        .select { |row| DiscuzCategoryEligibility.importable?(row) }
        .sort_by { |row| [-category_depth(row, rows), row["id"].to_i] }

    Category.transaction do
      deepest_first.each do |row|
        category_id = category_id_from_imported_category_id(row["id"].to_i)
        raise "importable Discuz category #{row["id"]} has no Discourse mapping" unless category_id

        category = Category.find_by(id: category_id)
        raise "mapped Discourse category #{category_id} is missing" unless category

        expected_parent_id = imported_category_parent_id(row)

        expected_name = @category_display_names.fetch(row["id"].to_i)
        updates = {}
        updates[:name] = expected_name if category.name != expected_name
        if category.parent_category_id != expected_parent_id
          updates[:parent_category_id] = expected_parent_id
        end
        if updates.any?
          begin
            category.update!(updates)
          rescue ActiveRecord::RecordInvalid => error
            raise(
              "#{error.message} while reconciling Discuz fid=#{row["id"]} " \
                "current_parent=#{category.parent_category_id.inspect} " \
                "expected_parent=#{expected_parent_id.inspect}",
            )
          end
          reconciled += 1
        end
      end
    end

    if reconciled.positive?
      puts "Reconciled names or parent links for #{reconciled} imported Discuz categories"
    end
  end

  def restrict_excluded_imported_categories!(rows)
    excluded_ids =
      rows.reject { |row| DiscuzCategoryEligibility.importable?(row) }.map { |row| row["id"].to_s }
    return if excluded_ids.empty?

    imported_categories =
      CategoryCustomField.where(name: "import_id", value: excluded_ids).pluck(:category_id, :value)
    return if imported_categories.empty?

    Category.transaction do
      imported_categories.each do |category_id, source_id|
        category = Category.find_by(id: category_id)
        next unless category

        category.set_permissions("staff" => :full)
        category.save!
        puts "Restricted excluded Discuz category fid=#{source_id} to staff"
      end
    end
  end

  def category_depth(row, rows)
    rows_by_id = @category_rows_by_id ||= rows.index_by { |category| category["id"].to_i }
    depth = 0
    parent_id = row["parent_id"].to_i
    visited = Set.new
    while parent_id.positive? && !visited.include?(parent_id) && (parent = rows_by_id[parent_id])
      visited.add(parent_id)
      depth += 1
      parent_id = parent["parent_id"].to_i
    end
    depth
  end

  def category_display_names(rows)
    existing_imported_ids = CategoryCustomField.where(name: "import_id").select(:category_id)
    reserved_root_names =
      Category
        .where(parent_category_id: nil)
        .where.not(id: existing_imported_ids)
        .pluck(:name)
        .map { |name| name.to_s.strip[0..49].downcase }
        .to_set
    DiscuzCategoryEligibility.display_names(
      rows,
      effective_parent_ids: @category_effective_parent_ids,
      reserved_root_names: reserved_root_names,
    )
  end

  def imported_category_parent_id(row)
    source_parent_id = @category_effective_parent_ids[row["id"].to_i]
    return nil unless source_parent_id

    category_id_from_imported_category_id(source_parent_id) ||
      raise("importable Discuz parent #{source_parent_id} has no Discourse mapping")
  end

  def apply_category_access_fallback(category, row, read_restricted, write_restricted)
    permissions =
      if read_restricted
        { "staff" => :full }
      elsif write_restricted
        { "everyone" => :readonly, "staff" => :full }
      else
        { "everyone" => :full }
      end
    category.set_permissions(permissions)
    category.save!
    category.custom_fields["discuz_viewperm_configured"] = row["viewperm"].present?
    category.custom_fields["discuz_formulaperm_configured"] = row["formulaperm"].present?
    category.custom_fields["discuz_password_protected"] = row["forum_password"].present?
    category.custom_fields["discuz_postperm_configured"] = row["postperm"].present?
    category.custom_fields["discuz_replyperm_configured"] = row["replyperm"].present?
    category.custom_fields["discuz_user_view_overrides_present"] = row[
      "has_user_view_override"
    ].to_i.positive?
    category.save_custom_fields
  end

  def import_posts
    puts "", "creating topics and posts"

    posts_table = table_name("forum_post")
    topics_table = table_name("forum_thread")
    post_filter = "WHERE p.tid IN (#{sample_id_sql("topic_ids")})" if @sample_manifest
    total_count =
      mysql_query(
        "SELECT count(*) count FROM #{posts_table} p#{post_filter ? " WHERE p.tid IN (#{sample_id_sql("topic_ids")})" : ""}",
      ).first[
        "count"
      ]

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(<<~SQL)
            SELECT p.pid id,
                   p.tid topic_id,
                   t.fid category_id,
                   t.subject title,
                   p.authorid user_id,
                   p.message raw,
                   p.dateline post_time,
                   p.usesig discuz_usesig,
                   p.anonymous discuz_anonymous,
                   p2.pid first_id,
                   p2.invisible first_post_status,
                   EXISTS (
                     SELECT 1 FROM #{table_name("forum_attachment")} attachment
                      WHERE attachment.pid = p.pid
                   ) has_attachment,
                   CHAR_LENGTH(TRIM(COALESCE(p.message, ''))) = 0 blank_message,
                   p.invisible status,
                   t.displayorder thread_status,
                   t.special special
              FROM #{posts_table} p
              LEFT JOIN #{topics_table} t ON t.tid = p.tid
              LEFT JOIN #{posts_table} p2 ON p2.first = 1 AND p2.tid = p.tid
             #{post_filter}
             ORDER BY COALESCE(p2.pid, p.pid) ASC, p.first DESC, p.pid ASC
             LIMIT #{BATCH_SIZE}
            OFFSET #{offset};
          SQL

      break if results.size < 1

      create_posts(results, total: total_count, offset: offset) do |row|
        if row["category_id"].nil?
          @source_skip_counts["post_without_thread"] += 1
          next nil
        end
        if row["first_id"].nil?
          @source_skip_counts["post_without_first_post"] += 1
          next nil
        end

        imported_user_id = user_id_from_imported_user_id(row["user_id"])
        unless imported_user_id
          @source_skip_counts["post_author_unmapped"] += 1
          next nil
        end

        mapped = {
          id: row["id"],
          user_id: imported_user_id,
          raw: process_discuzx_post(row["raw"], row["id"]),
          created_at: Time.zone.at(row["post_time"]),
          tags: row["tags"],
          # Preserve Discuz's per-post signature visibility behavior.
          custom_fields: {
            "discuz_usesig" => row["discuz_usesig"].to_s.to_i == 1,
            "discuz_anonymous" => row["discuz_anonymous"].to_s.to_i == 1,
            "discuz_invisible" => row["status"].to_i,
            "discuz_thread_displayorder" => row["thread_status"].to_i,
          },
        }

        is_first_post = row["id"].to_i == row["first_id"].to_i
        if is_first_post
          mapped[:category] = category_id_from_imported_category_id(row["category_id"])
          unless mapped[:category]
            @source_skip_counts["post_category_unmapped"] += 1
            next nil
          end
          mapped[:title] = CGI.unescapeHTML(row["title"])

          if row["special"] == 1
            poll =
              mysql_query(
                "SELECT multiple, maxchoices FROM #{table_name("forum_poll")} WHERE tid = #{row["topic_id"]}",
              ).first || {}
            options =
              mysql_query(
                "SELECT polloption FROM #{table_name("forum_polloption")} WHERE tid = #{row["topic_id"]} ORDER BY displayorder",
              )
            if options.size.zero?
              puts "WARNING: missing poll options for source topic #{row["topic_id"]}"
            else
              mapped[:raw].prepend(
                "[poll#{poll["multiple"] ? " type=multiple" : ""}#{poll["maxchoices"].to_i > 0 ? " max=#{poll["maxchoices"]}" : ""}]\n" +
                  "#{options.map { |option| "- #{option["polloption"]}" }.join("\n")}\n[/poll]\n",
              )
            end
          end
        else
          parent = topic_lookup_from_imported_post_id(row["first_id"])
          unless parent
            @source_skip_counts["post_parent_unimported"] += 1
            next nil
          end

          mapped[:topic_id] = parent[:topic_id]
          reply_post_import_id = find_post_id_by_quote_number(row["raw"])
          if reply_post_import_id
            post_id = post_id_from_imported_post_id(reply_post_import_id.to_i)
            if (post = Post.find_by(id: post_id))
              if post.topic_id == mapped[:topic_id]
                mapped[:reply_to_post_number] = post.post_number
              else
                puts "Source post #{row["id"]} quotes a post in another topic"
              end
            else
              puts "Source post #{row["id"]} quotes an unavailable imported post"
            end
          end
        end

        if row["status"].to_i != 0 || row["thread_status"].to_i < 0 ||
             row["first_post_status"].to_i != 0 ||
             (
               (row["blank_message"].to_i == 1 || mapped[:raw].blank?) &&
                 row["has_attachment"].to_i != 1
             )
          is_first_post = row["id"].to_i == row["first_id"].to_i
          if existing_post_id = post_id_from_imported_post_id(row["id"].to_s)
            @deferred_visibility_actions << [existing_post_id, is_first_post]
          end
          mapped[:post_create_action] = lambda do |created_post|
            @deferred_visibility_actions << [created_post.id, is_first_post]
          end
        end

        mapped
      end
    end

    apply_deferred_visibility_actions
  end

  def apply_deferred_visibility_actions
    actions = @deferred_visibility_actions.uniq
    first_post_actions, reply_actions = actions.partition { |_post_id, first_post| first_post }

    [first_post_actions, reply_actions].each do |action_group|
      action_group.each_slice(BATCH_SIZE) do |batch|
        Post
          .with_deleted
          .where(id: batch.map(&:first))
          .order(:id)
          .each do |post|
            next if post.deleted_at

            PostDestroyer.new(
              Discourse.system_user,
              post,
              context: "Imported Discuz visibility state",
              skip_staff_log: true,
            ).perform_delete
          end
      end
    end

    puts "Preserved #{actions.length} hidden or deleted Discuz posts in the staff-recoverable trash"
  end

  def report_source_skips
    exclusions = @source_skip_counts.sort_by { |reason, _count| reason }
    return if exclusions.empty?

    puts "Discuz source exclusions:"
    exclusions.each { |reason, count| puts "  #{reason}=#{count}" }
  end

  def import_bookmarks
    puts "", "creating bookmarks"
    favorites_table = table_name "home_favorite"
    posts_table = table_name "forum_post"

    total_count =
      mysql_query("SELECT count(*) count FROM #{favorites_table} WHERE idtype = 'tid'").first[
        "count"
      ]
    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "
        SELECT p.pid post_id, f.uid user_id
          FROM #{favorites_table} f
          JOIN #{posts_table} p ON f.id = p.tid
          WHERE f.idtype = 'tid' AND p.first
             LIMIT #{BATCH_SIZE}
            OFFSET #{offset};",
        )

      break if results.size < 1

      # next if all_records_exist?

      create_bookmarks(results, total: total_count, offset: offset) do |row|
        { user_id: row["user_id"], post_id: row["post_id"] }
      end
    end
  end

  def import_private_messages
    puts "", "creating private messages"

    message_tables = (0..9).map { |shard| ucenter_table_name("pm_messages_#{shard}") }
    message_union =
      message_tables
        .map do |table|
          filter = " WHERE plid IN (#{sample_id_sql("pm_thread_ids")})" if @sample_manifest
          "SELECT pmid id, plid thread_id, authorid user_id, message, dateline created_at FROM #{table}#{filter}"
        end
        .join("\nUNION ALL\n")
    total_count =
      message_tables.sum do |table|
        filter = " WHERE plid IN (#{sample_id_sql("pm_thread_ids")})" if @sample_manifest
        mysql_query("SELECT count(*) count FROM #{table}#{filter}").first["count"].to_i
      end

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(<<~SQL)
            SELECT *
              FROM (#{message_union}) messages
             ORDER BY thread_id ASC, id ASC
             LIMIT #{BATCH_SIZE}
            OFFSET #{offset};
          SQL

      break if results.size < 1

      create_posts(results, total: total_count, offset: offset) do |message|
        thread_id = message["thread_id"].to_i
        import_id = "pm:#{message["id"]}"
        first_message = !@seen_pm_thread_ids.add?(thread_id).nil?

        if @unimportable_pm_thread_ids.include?(thread_id)
          @source_skip_counts["pm_thread_unimportable"] += 1
          next nil
        end

        imported_author_id = user_id_from_imported_user_id(message["user_id"])
        unless imported_author_id
          @source_skip_counts["pm_author_unmapped"] += 1
          @unimportable_pm_thread_ids.add(thread_id) if first_message
          next nil
        end

        mapped = {
          id: import_id,
          user_id: imported_author_id,
          raw: process_discuzx_post(message["message"], message["id"]),
          created_at: Time.zone.at(message["created_at"]),
        }

        if first_message
          pm_thread =
            mysql_query(
              "SELECT subject, pmtype, min_max FROM #{ucenter_table_name("pm_lists")} WHERE plid = #{thread_id};",
            ).first
          unless pm_thread
            @source_skip_counts["pm_thread_metadata_missing"] += 1
            @unimportable_pm_thread_ids.add(thread_id)
            next nil
          end

          member_uids =
            mysql_query(
              "SELECT uid FROM #{ucenter_table_name("pm_members")} WHERE plid = #{thread_id};",
            ).map { |row| row["uid"].to_i }.uniq
          if pm_thread["pmtype"].to_i == 1
            pair = pm_thread["min_max"].to_s.split("_", -1)
            unless pair.length == 2 && pair.all? { |uid| uid.match?(/\A[1-9][0-9]*\z/) } &&
                     pair.map(&:to_i).include?(message["user_id"].to_i)
              @source_skip_counts["pm_one_to_one_pair_invalid"] += 1
              @unimportable_pm_thread_ids.add(thread_id)
              next nil
            end
            member_uids |= pair.map(&:to_i)
          end
          if member_uids.empty?
            @source_skip_counts["pm_participants_missing"] += 1
            @unimportable_pm_thread_ids.add(thread_id)
            next nil
          end

          participants = member_uids.map { |uid| [uid, user_id_from_imported_user_id(uid)] }
          if participants.any? { |_uid, discourse_user_id| discourse_user_id.nil? }
            @source_skip_counts["pm_participant_unmapped"] += 1
            @unimportable_pm_thread_ids.add(thread_id)
            next nil
          end

          targets =
            participants
              .filter_map do |uid, discourse_user_id|
                next if uid == message["user_id"].to_i

                User.find_by(id: discourse_user_id)&.username
              end
              .uniq
          if targets.empty?
            @source_skip_counts["pm_without_recipient"] += 1
            @unimportable_pm_thread_ids.add(thread_id)
            next nil
          end

          mapped[:title] = pm_thread["subject"]
          mapped[:archetype] = Archetype.private_message
          mapped[:target_usernames] = targets
          @first_post_id_by_topic_id[thread_id] = import_id
        else
          parent = topic_lookup_from_imported_post_id(@first_post_id_by_topic_id[thread_id])
          unless parent
            @source_skip_counts["pm_parent_unimported"] += 1
            next nil
          end

          mapped[:topic_id] = parent[:topic_id]
        end

        mapped
      end
    end
  end

  def process_and_upload_inline_images(raw)
    inline_image_regex = %r{\[img\]([\s\S]*?)\[/img\]}

    s = raw.dup

    s.gsub!(inline_image_regex) do |d|
      matches = inline_image_regex.match(d)
      data = matches[1]

      upload, filename = upload_inline_image data
      upload ? html_for_upload(upload, filename) : nil
    end
  end

  def process_discuz_category_text(raw)
    return "" if raw.blank?

    text = process_discuzx_post(raw, nil)
    if @bbcode_to_md
      text =
        begin
          text.bbcode_to_md(false)
        rescue StandardError
          text
        end
    end
    text
  end

  def process_discuzx_post(raw, import_id)
    # raw = process_and_upload_inline_images(raw)
    s = raw.dup

    # Strip the quote
    # [quote] quotation includes the topic which is the same as reply to in Discourse
    # We get the pid to find the post number the post reply to. So it can be stripped
    s =
      s.gsub(
        %r{\[b\]回复 \[url=forum.php\?mod=redirect&goto=findpost&pid=\d+&ptid=\d+\].* 的帖子\[/url\]\[/b\]}i,
        "",
      ).strip
    s =
      s.gsub(
        %r{\[b\]回复 \[url=https?://#{ORIGINAL_SITE_PREFIX}/redirect.php\?goto=findpost&pid=\d+&ptid=\d+\].*?\[/url\].*?\[/b\]}i,
        "",
      ).strip

    s = convert_discuz_quotes(s, import_id)

    # truncate line space, preventing line starting with many blanks to be parsed as code blocks
    s.gsub!(/^ {4,}/, "   ")

    # TODO: Much better to use bbcode-to-md gem
    # Convert image bbcode with width and height
    s.gsub!(
      %r{\[img[^\]]*\]https?://#{ORIGINAL_SITE_PREFIX}/(.*)\[/img\]}i,
      '[x-attach]\1[/x-attach]',
    ) # don't convert attachment
    s.gsub!(
      %r{<img[^>]*src="https?://#{ORIGINAL_SITE_PREFIX}/(.*)".*?>}i,
      '[x-attach]\1[/x-attach]',
    ) # don't convert attachment
    s.gsub!(
      %r{\[img[^\]]*\]https?://www\.touhou\.cc/blog/(.*)\[/img\]}i,
      '[x-attach]../blog/\1[/x-attach]',
    ) # 私货
    s.gsub!(
      %r{\[img[^\]]*\]https?://www\.touhou\.cc/ucenter/avatar.php\?uid=(\d+)[^\]]*\[/img\]}i,
    ) { "[x-attach]#{discuzx_avatar_fullpath($1, false)[0]}[/x-attach]" } # 私货
    s.gsub!(%r{\[img=(\d+),(\d+)\]([^\]]*)\[/img\]}i, '<img width="\1" height="\2" src="\3">')
    s.gsub!(%r{\[img\]([^\]]*)\[/img\]}i, '<img src="\1">')

    s.gsub!(
      %r{\[qq\]([^\]]*)\[/qq\]}i,
      '<a href="http://wpa.qq.com/msgrd?V=3&Uin=\1&Site=[Discuz!]&from=discuz&Menu=yes" target="_blank"><!--<img src="static/image/common/qq_big.gif" border="0">-->QQ 交谈</a>',
    )

    s.gsub!(%r{\[email\]([^\]]*)\[/email\]}i, '[url=mailto:\1]\1[/url]') # bbcode-to-md can convert it
    s.gsub!(%r{\[s\]([^\]]*)\[/s\]}i, '<s>\1</s>')
    s.gsub!(%r{\[sup\]([^\]]*)\[/sup\]}i, '<sup>\1</sup>')
    s.gsub!(%r{\[sub\]([^\]]*)\[/sub\]}i, '<sub>\1</sub>')
    s.gsub!(/\[hr\]/i, "\n---\n")

    # remove the media tag
    s.gsub!(%r{\[/?media[^\]]*\]}i, "\n")
    s.gsub!(%r{\[/?flash[^\]]*\]}i, "\n")
    s.gsub!(%r{\[/?audio[^\]]*\]}i, "\n")
    s.gsub!(%r{\[/?video[^\]]*\]}i, "\n")

    # Remove the font, p and backcolor tag
    # Discourse doesn't support the font tag
    s.gsub!(/\[font=[^\]]*?\]/i, "")
    s.gsub!(%r{\[/font\]}i, "")
    s.gsub!(/\[p=[^\]]*?\]/i, "")
    s.gsub!(%r{\[/p\]}i, "")
    s.gsub!(/\[backcolor=[^\]]*?\]/i, "")
    s.gsub!(%r{\[/backcolor\]}i, "")

    # Remove the size tag
    # I really have no idea what is this
    s.gsub!(/\[size=[^\]]*?\]/i, "")
    s.gsub!(%r{\[/size\]}i, "")

    # Remove the color tag
    s.gsub!(/\[color=[^\]]*?\]/i, "")
    s.gsub!(%r{\[/color\]}i, "")

    # Remove the hide tag
    s.gsub!(%r{\[/?hide\]}i, "")
    s.gsub!(%r{\[/?free[^\]]*\]}i, "\n")

    # Remove the align tag
    # still don't know what it is
    s.gsub!(/\[align=[^\]]*?\]/i, "\n")
    s.gsub!(%r{\[/align\]}i, "\n")
    s.gsub!(/\[float=[^\]]*?\]/i, "\n")
    s.gsub!(%r{\[/float\]}i, "\n")

    # Convert code
    s.gsub!(%r{\[/?code\]}i, "\n```\n")

    # The edit notice should be removed
    # example: 本帖最后由 Helloworld 于 2015-1-28 22:05 编辑
    s.gsub!(%r{\[i=s\] 本帖最后由[\s\S]*?编辑 \[/i\]}, "")

    # Convert reviewed Discuz smileys and preserve unreviewed numeric tokens.
    s = DiscuzMigration::Smilies.convert(s)

    # Replace internal forum links that aren't in the <!-- l --> format
    # convert list tags to ul and list=1 tags to ol
    # (basically, we're only missing list=a here...)
    s.gsub!(%r{\[list\](.*?)\[/list:u\]}m, '[ul]\1[/ul]')
    s.gsub!(%r{\[list=1\](.*?)\[/list:o\]}m, '[ol]\1[/ol]')
    # convert *-tags to li-tags so bbcode-to-md can do its magic on phpBB's lists:
    s.gsub!(%r{\[\*\](.*?)\[/\*:m\]}, '[li]\1[/li]')

    # Discuz can create PM out of a post, which will generates like
    # [url=http://example.com/forum.php?mod=redirect&goto=findpost&pid=111&ptid=11][b]关于您在“主题名称”的帖子[/b][/url]
    s.gsub!(pm_url_regexp) { |discuzx_link| replace_internal_link(discuzx_link, $1, nil, nil, nil) }

    # [url][b]text[/b][/url] to **[url]text[/url]**
    s.gsub!(%r{(\[url=[^\[\]]*?\])\[b\](\S*)\[/b\](\[/url\])}, '**\1\2\3**')

    @internal_url_regexps.each do |internal_url_regexp|
      s.gsub!(internal_url_regexp) do |discuzx_link|
        replace_internal_link(
          discuzx_link,
          begin
            $~[:tid].to_i
          rescue StandardError
            nil
          end,
          begin
            $~[:pid].to_i
          rescue StandardError
            nil
          end,
          begin
            $~[:fid].to_i
          rescue StandardError
            nil
          end,
          begin
            $~[:action]
          rescue StandardError
            nil
          end,
        )
      end
    end

    # @someone without the url
    s.gsub!(%r{@\[url=[^\[\]]*?\](\S*)\[/url\]}i, '@\1')

    s.scan(%r{http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\.')}/[^\[\]\s]*}) do |link|
      puts "WARNING: post #{import_id} can't replace internal url #{link}"
    end

    s.strip
  end

  def replace_internal_link(
    discuzx_link,
    import_topic_id,
    import_post_id,
    import_category_id,
    action
  )
    if import_post_id
      post_id = post_id_from_imported_post_id import_post_id
      if post_id
        post = Post.find post_id
        return post.full_url if post
      end
    end

    if import_topic_id
      results =
        mysql_query(
          "SELECT pid
                               FROM #{table_name "forum_post"}
                              WHERE tid = #{import_topic_id} AND first
                              LIMIT 1",
        )

      return discuzx_link if results.size.zero?

      linked_post_id = results.first["pid"]
      lookup = topic_lookup_from_imported_post_id(linked_post_id)

      if lookup
        return "#{NEW_SITE_PREFIX}#{lookup[:url]}"
      else
        return discuzx_link
      end
    end

    if import_category_id
      category_id = category_id_from_imported_category_id import_category_id
      if category_id
        category = Category.find category_id
        return category.url if category
      end
    end

    case action
    when "index"
      return "#{NEW_SITE_PREFIX}/"
    when "stat", "stats", "ranklist"
      return "#{NEW_SITE_PREFIX}/users"
    end

    discuzx_link
  end

  def pm_url_regexp
    @pm_url_regexp ||=
      Regexp.new(
        "http(?:s)?://#{ORIGINAL_SITE_PREFIX.gsub(".", '\.')}/forum\\.php\\?mod=redirect&goto=findpost&pid=\\d+&ptid=(\\d+)",
      )
  end

  # This step is done separately because it can take multiple attempts to get right (because of
  # missing files, wrong paths, authorized extensions, etc.).
  def import_attachments
    setting = AUTHORIZED_EXTENSIONS.join("|")
    SiteSetting.authorized_extensions = setting if setting != SiteSetting.authorized_extensions

    attachment_regex = %r{\[attach\](\d+)\[/attach\]}
    attachment_link_regex = %r{\[x-attach\](.+)\[/x-attach\]}
    requested_attachment_ids = requested_discuz_attachment_ids

    current_count = 0
    total_count =
      mysql_query("SELECT count(*) count FROM #{table_name "forum_post"};").first["count"]

    success_count = 0
    fail_count = 0

    puts "", "Importing attachments...", ""

    Post.find_each do |post|
      next unless post.custom_fields["import_id"] == post.custom_fields["import_id"].to_i.to_s

      user = post.user

      current_count += 1
      print_status current_count, total_count

      new_raw = post.raw.dup

      inline_attachments = []

      new_raw.gsub!(attachment_regex) do |s|
        attachment_id = $1.to_i
        if requested_attachment_ids.present? && !requested_attachment_ids.include?(attachment_id)
          next s
        end

        inline_attachments.push attachment_id

        upload, filename = find_upload(user, post, attachment_id)
        unless upload
          fail_count += 1
          next s
        end

        html_for_upload(upload, filename)
      end
      new_raw.gsub!(attachment_link_regex) do |s|
        next s if requested_attachment_ids.present?

        attachment_file = $1

        filename = File.basename(attachment_file)
        path = snapshot_file(attachment_file)
        upload = create_upload(user.id, path, filename) if path
        unless upload
          fail_count += 1
          next s
        end

        html_for_upload(upload, filename)
      end

      sql =
        "SELECT aid
          FROM #{table_name "forum_attachment"}
          WHERE pid = #{post.custom_fields["import_id"]}"
      sql = "#{sql} AND aid NOT IN (#{inline_attachments.join(",")})" if !inline_attachments.empty?
      if requested_attachment_ids.present?
        sql = "#{sql} AND aid IN (#{requested_attachment_ids.join(",")})"
      end

      results = mysql_query(sql)

      results.each do |attachment|
        attachment_id = attachment["aid"]
        upload, filename = find_upload(user, post, attachment_id)
        unless upload
          fail_count += 1
          next
        end
        html = html_for_upload(upload, filename)
        if new_raw.exclude? html
          new_raw << "\n"
          new_raw << html
        end
      end

      if new_raw != post.raw
        PostRevisor.new(post).revise!(
          post.user,
          { raw: new_raw },
          bypass_bump: true,
          edit_reason: "从 Discuz 中导入附件",
        )
      end

      success_count += 1
    end

    puts "", ""
    puts "succeeded: #{success_count}"
    puts "   failed: #{fail_count}" if fail_count > 0
    puts ""
  end

  def requested_discuz_attachment_ids
    raw_ids = ENV["DISCUZX_ATTACHMENT_IDS"].to_s.strip
    return [] if raw_ids.blank?

    ids = raw_ids.split(",").map(&:strip)
    unless ids.all? { |id| id.match?(/\A[1-9]\d*\z/) } && ids.uniq.length == ids.length
      raise "DISCUZX_ATTACHMENT_IDS must be a comma-separated list of unique positive integers"
    end

    ids.map(&:to_i)
  end

  def validate_requested_attachment_files!(requested_ids)
    id_sql = requested_ids.join(",")
    attachment_rows =
      mysql_query(
        "SELECT aid, tableid FROM #{table_name("forum_attachment")} WHERE aid IN (#{id_sql})",
      ).to_a
    found_ids = attachment_rows.map { |row| row["aid"].to_i }.to_set
    missing_source_ids = requested_ids.to_set - found_ids
    if missing_source_ids.any?
      raise "#{missing_source_ids.length} requested Discuz attachment ID(s) are absent from the source snapshot"
    end

    partition_rows =
      attachment_rows
        .group_by { |row| row["tableid"].to_i }
        .flat_map do |table_id, rows|
          partition_ids = rows.map { |row| row["aid"].to_i }
          mysql_query(
            "SELECT aid, attachment, filesize FROM #{table_name("forum_attachment_#{table_id}")} " \
              "WHERE aid IN (#{partition_ids.join(",")})",
          ).to_a
        end
    valid_file_ids =
      partition_rows
        .filter_map do |row|
          path = snapshot_file(File.join(ATTACHMENT_DIR, row["attachment"].to_s))
          next unless path && File.size(path) == row["filesize"].to_i

          row["aid"].to_i
        end
        .to_set
    missing_or_mismatched_file_ids = requested_ids.to_set - valid_file_ids
    if missing_or_mismatched_file_ids.any?
      raise "#{missing_or_mismatched_file_ids.length} requested attachment file(s) are missing or have a size mismatch; no attachments were imported"
    end
  end

  def validate_requested_attachment_metadata!(requested_ids)
    id_sql = requested_ids.join(",")
    source_rows =
      mysql_query(
        "SELECT aid, pid FROM #{table_name("forum_attachment")} WHERE aid IN (#{id_sql})",
      ).to_a
    found_ids = source_rows.map { |row| row["aid"].to_i }.to_set
    missing_ids = requested_ids.to_set - found_ids
    if missing_ids.any?
      raise "#{missing_ids.length} requested Discuz attachment ID(s) are absent from the source snapshot"
    end

    sample_post_ids = @sample_manifest.fetch("post_ids").map(&:to_i).to_set
    outside_sample = source_rows.count { |row| !sample_post_ids.include?(row["pid"].to_i) }
    if outside_sample.positive?
      raise "#{outside_sample} requested attachment(s) are outside the relation-closed sample post set"
    end
  end

  def import_attachment_metadata
    requested_ids = requested_discuz_attachment_ids.to_set
    requested_ids = nil if requested_ids.empty?
    sample_post_ids = @sample_manifest.fetch("post_ids").map(&:to_s).to_set
    imported_users = UserCustomField.where(name: "import_id").pluck(:value, :user_id).to_h
    current_count = 0
    imported_count = 0
    total_count =
      mysql_query(
        "SELECT count(*) count FROM #{table_name("forum_post")} WHERE pid IN (#{sample_id_sql("post_ids")});",
      ).first[
        "count"
      ].to_i

    puts "", "Importing Discuz attachment metadata...", ""

    Post.unscoped.find_each do |post|
      source_post_id = post.custom_fields["import_id"].to_s
      next unless source_post_id.match?(/\A[1-9]\d*\z/) && sample_post_ids.include?(source_post_id)

      current_count += 1
      if current_count % 100 == 0 || current_count == total_count
        print_status current_count, total_count
      end

      sql =
        "SELECT aid, tableid FROM #{table_name("forum_attachment")} " \
          "WHERE pid = #{source_post_id}"
      sql = "#{sql} AND aid IN (#{requested_ids.to_a.sort.join(",")})" if requested_ids
      index_rows = mysql_query(sql).to_a
      next if index_rows.empty?

      source_rows =
        index_rows
          .group_by { |row| row["tableid"].to_i }
          .flat_map do |table_id, rows|
            aid_sql = rows.map { |row| row["aid"].to_i }.join(",")
            mysql_query(
              "SELECT aid, pid, tid, uid, dateline, filename, attachment, filesize, remote, " \
                "isimage, thumb, readperm, price " \
                "FROM #{table_name("forum_attachment_#{table_id}")} WHERE aid IN (#{aid_sql})",
            ).to_a
          end
      if source_rows.length != index_rows.length
        raise "source attachment metadata is incomplete for Discuz post #{source_post_id}"
      end

      topic_prices =
        mysql_query(
          "SELECT tid, price FROM #{table_name("forum_thread")} " \
            "WHERE tid IN (#{source_rows.map { |row| row["tid"].to_i }.uniq.join(",")})",
        ).to_a.to_h { |row| [row["tid"].to_i, row["price"].to_i] }

      source_rows.each do |row|
        unless row["pid"].to_i == source_post_id.to_i
          raise "Discuz attachment #{row["aid"]} points to a different source post"
        end

        relative_path = row["attachment"].to_s
        path_parts = relative_path.split("/", -1)
        if relative_path.blank? || relative_path.start_with?("/") || relative_path.include?("\\") ||
             path_parts.any? { |part| part.blank? || part == "." || part == ".." }
          raise "Discuz attachment #{row["aid"]} has an invalid object path"
        end

        filename = row["filename"].to_s.presence || File.basename(relative_path)
        attachment = DiscourseDiscuzBbcode::Attachment.find_or_initialize_by(aid: row["aid"].to_i)
        if attachment.persisted? && attachment.discuz_pid.to_i != source_post_id.to_i
          raise "Discuz attachment #{row["aid"]} is already mapped to another source post"
        end

        attachment.assign_attributes(
          discuz_pid: row["pid"].to_i,
          discuz_tid: row["tid"].to_i,
          discuz_uid: row["uid"].to_i,
          post_id: post.id,
          user_id: imported_users[row["uid"].to_s],
          object_key: "forum/#{relative_path}",
          filename: filename,
          filesize: row["filesize"].to_i,
          is_image: row["isimage"].to_i == 1,
          has_thumbnail: row["thumb"].to_i == 1,
          is_remote: row["remote"].to_i == 1,
          readperm: row["readperm"].to_i,
          attachment_price: row["price"].to_i,
          topic_price: topic_prices.fetch(row["tid"].to_i, 0),
          uploaded_at: row["dateline"].to_i,
        )
        attachment.save!
        imported_count += 1
      end
    end

    puts "", "", "metadata rows imported or refreshed: #{imported_count}", ""
  end

  def import_discuz_medals
    source_uids =
      if @sample_manifest
        @sample_manifest.fetch("member_uids").map(&:to_i)
      else
        mysql_query(
          "SELECT uid FROM (#{source_member_union}) source_members ORDER BY uid",
        ).map { |row| row["uid"].to_i }
      end
    source_uids = source_uids.uniq.sort
    users_by_uid = imported_discuz_users_by_uid!(source_uids)

    definitions =
      mysql_query(
        "SELECT medalid, name, description, image, available " \
          "FROM #{table_name("forum_medal")} ORDER BY medalid",
      ).to_a
    definition_by_id = definitions.index_by { |row| row["medalid"].to_i }

    source_memberships = {}
    expired_assignment_count = 0
    malformed_token_count = 0
    source_uids.each_slice(1_000) do |uid_batch|
      next if uid_batch.empty?

      mysql_query(
        "SELECT uid, medals FROM #{table_name("common_member_field_forum")} " \
          "WHERE uid IN (#{uid_batch.join(",")})",
      ).each do |row|
        parsed =
          DiscuzMigration::Medals.parse_memberships(row["medals"], now_epoch: Time.current.to_i)
        source_memberships[row["uid"].to_i] = parsed[:assignments]
        expired_assignment_count += parsed[:expired_count]
        malformed_token_count += parsed[:malformed_count]
      end
    end

    expected_pairs = Set.new
    unavailable_assignment_count = 0
    undefined_assignment_count = 0
    source_memberships.each do |uid, assignments|
      assignments.each do |assignment|
        definition = definition_by_id[assignment[:medalid]]
        if definition.nil?
          undefined_assignment_count += 1
        elsif definition["available"].to_i != 1
          unavailable_assignment_count += 1
        else
          expected_pairs << [uid, assignment[:medalid]]
        end
      end
    end

    award_dates = {}
    pairs_by_uid = expected_pairs.group_by(&:first)
    pairs_by_uid
      .keys
      .sort
      .each_slice(1_000) do |uid_batch|
        batch_pairs = uid_batch.flat_map { |uid| pairs_by_uid.fetch(uid) }
        medal_ids = batch_pairs.map(&:last).uniq.sort
        next if medal_ids.empty?

        mysql_query(
          "SELECT uid, medalid, MAX(dateline) dateline FROM #{table_name("forum_medallog")} " \
            "WHERE uid IN (#{uid_batch.join(",")}) AND medalid IN (#{medal_ids.join(",")}) " \
            "AND type IN (0, 1) GROUP BY uid, medalid",
        ).each do |row|
          award_dates[[row["uid"].to_i, row["medalid"].to_i]] = discuz_timestamp(row["dateline"])
        end
      end

    mappings_by_id = {}
    imported_count = 0
    revoked_count = 0
    fallback_date_count = 0
    affected_user_ids = Set.new

    ActiveRecord::Base.transaction do
      SiteSetting.enable_badges = true

      definitions.each do |definition|
        mapping = sync_discuz_medal_definition!(definition)
        mappings_by_id[mapping.discuz_medalid.to_i] = mapping
      end

      known_ids = definition_by_id.keys
      retired_mappings = DiscourseDiscuzMedals::MedalMapping.includes(:badge)
      retired_mappings = retired_mappings.where.not(discuz_medalid: known_ids) if known_ids.present?
      retired_mappings.each do |mapping|
        mapping.update!(source_available: false)
        mapping.badge.update!(enabled: false) if mapping.badge.enabled?
        mappings_by_id[mapping.discuz_medalid.to_i] = mapping
      end

      tracked_grants =
        source_uids
          .each_slice(1_000)
          .flat_map do |uid_batch|
            DiscourseDiscuzMedals::UserMedalGrant.where(discuz_uid: uid_batch).to_a
          end
      tracked_by_pair =
        tracked_grants.index_by { |grant| [grant.discuz_uid.to_i, grant.discuz_medalid.to_i] }

      (tracked_by_pair.keys.to_set - expected_pairs).each do |pair|
        grant = tracked_by_pair.fetch(pair)
        user_badge =
          UserBadge.find_by(user_id: grant.user_id, badge_id: grant.badge_id, post_id: nil)
        if user_badge
          UserBadge.where(id: user_badge.id).delete_all
          affected_user_ids << grant.user_id.to_i
        end
        grant.destroy!
        revoked_count += 1
      end

      expected_pairs.each do |uid, medalid|
        mapping = mappings_by_id.fetch(medalid)
        unless mapping.source_available
          raise "Discuz medal #{medalid} is not enabled in source but appears active"
        end

        user = users_by_uid.fetch(uid)
        tracked = tracked_by_pair[[uid, medalid]]
        if tracked && (tracked.user_id.to_i != user.id || tracked.badge_id.to_i != mapping.badge_id)
          raise "Discuz medal mapping changed for UID #{uid}, medal #{medalid}"
        end

        user_badge = UserBadge.find_by(user_id: user.id, badge_id: mapping.badge_id, post_id: nil)
        if user_badge && !tracked
          raise "Discuz medal badge already exists without importer ownership for UID #{uid}, medal #{medalid}"
        end
        if user_badge.nil? && UserBadge.exists?(user_id: user.id, badge_id: mapping.badge_id)
          raise "Discuz medal badge has an unexpected post-specific grant for UID #{uid}, medal #{medalid}"
        end

        source_awarded_at = award_dates[[uid, medalid]]
        granted_at = source_awarded_at || user.created_at || Time.current
        fallback_date_count += 1 if source_awarded_at.nil?
        if user_badge.nil?
          now = Time.current
          UserBadge.insert_all!(
            [
              {
                badge_id: mapping.badge_id,
                user_id: user.id,
                granted_by_id: Discourse.system_user.id,
                granted_at: granted_at,
                post_id: nil,
                seq: 0,
                created_at: now,
              },
            ],
          )
          affected_user_ids << user.id
        elsif user_badge.granted_at.to_i != granted_at.to_i
          user_badge.update_columns(granted_at: granted_at)
          affected_user_ids << user.id
        end

        grant =
          tracked ||
            DiscourseDiscuzMedals::UserMedalGrant.new(discuz_uid: uid, discuz_medalid: medalid)
        grant.assign_attributes(
          user_id: user.id,
          badge_id: mapping.badge_id,
          source_expiration_at:
            source_memberships.fetch(uid).find { |assignment| assignment[:medalid] == medalid }[
              :expiration
            ],
          source_awarded_at: source_awarded_at,
        )
        grant.save!
        imported_count += 1 unless tracked
      end
    end

    badge_ids = mappings_by_id.values.map(&:badge_id).uniq
    badge_grant_counts = UserBadge.where(badge_id: badge_ids).group(:badge_id).count
    Badge
      .where(id: badge_ids)
      .find_each do |badge|
        expected_count = badge_grant_counts.fetch(badge.id, 0)
        badge.update_columns(grant_count: expected_count) if badge.grant_count != expected_count
      end
    unless affected_user_ids.empty?
      UserStat.update_distinct_badge_count(affected_user_ids.to_a)
      UserBadge.update_featured_ranks!(affected_user_ids.to_a)
    end

    @source_skip_counts["medal_expired_assignments"] += expired_assignment_count
    @source_skip_counts["medal_unavailable_assignments"] += unavailable_assignment_count
    @source_skip_counts["medal_assignments_without_definition"] += undefined_assignment_count
    @source_skip_counts["medal_malformed_membership_tokens"] += malformed_token_count

    puts "Discuz medal definitions synchronized: #{definitions.length}"
    puts "Current active Discuz medal awards reconciled: #{expected_pairs.length}"
    puts "New awards: #{imported_count}; revoked or expired awards: #{revoked_count}"
    puts "Awards without a source grant log, using account creation date: #{fallback_date_count}"
  end

  def imported_discuz_users_by_uid!(source_uids)
    imported_by_uid = Hash.new { |hash, uid| hash[uid] = [] }
    source_uids.each_slice(1_000) do |uid_batch|
      UserCustomField
        .where(name: "import_id", value: uid_batch.map(&:to_s))
        .pluck(:value, :user_id)
        .each { |value, user_id| imported_by_uid[value.to_i] << user_id.to_i }
    end

    duplicate_uids = imported_by_uid.select { |_uid, user_ids| user_ids.uniq.length != 1 }
    missing_uids = source_uids - imported_by_uid.keys
    unless duplicate_uids.empty? && missing_uids.empty?
      raise "Discuz medal stage requires one imported user per source UID (missing=#{missing_uids.length}, ambiguous=#{duplicate_uids.length})"
    end

    user_ids = imported_by_uid.values.flatten.uniq
    fields = { source: {}, uid: {} }
    user_ids.each_slice(1_000) do |user_id_batch|
      UserCustomField
        .where(user_id: user_id_batch, name: %w[discuz_source discuz_uid])
        .pluck(:user_id, :name, :value)
        .each do |user_id, name, value|
          fields[:source][user_id.to_i] = value if name == "discuz_source"
          fields[:uid][user_id.to_i] = value.to_s if name == "discuz_uid"
        end
    end

    mismatched_uids =
      source_uids.count do |uid|
        user_id = imported_by_uid.fetch(uid).first
        fields[:source][user_id] != DISCUZ_SOURCE || fields[:uid][user_id] != uid.to_s
      end
    if mismatched_uids.positive?
      raise "Discuz medal stage found #{mismatched_uids} users without matching source UID markers"
    end

    User.where(id: user_ids).index_by { |user| fields[:uid].fetch(user.id).to_i }
  end

  def sync_discuz_medal_definition!(definition)
    medalid = definition["medalid"].to_i
    source_name = definition["name"].to_s.presence || "Discuz 勋章 #{medalid}"
    badge_name = DiscuzMigration::Medals.badge_name(medalid, source_name)
    mapping = DiscourseDiscuzMedals::MedalMapping.find_by(discuz_medalid: medalid)
    badge = mapping&.badge

    raise "Discuz medal #{medalid} points to a missing Discourse badge" if mapping && badge.nil?
    if badge.nil? && Badge.exists?(name: badge_name)
      raise "Discuz medal badge name collides with an existing native badge: #{badge_name}"
    end
    badge ||= Badge.new
    badge.assign_attributes(
      name: badge_name,
      description: definition["description"].to_s.truncate(500),
      badge_type_id: BadgeType::Bronze,
      badge_grouping_id: BadgeGrouping::Community,
      icon: "certificate",
      enabled: definition["available"].to_i == 1,
      listable: true,
      allow_title: false,
      multiple_grant: false,
      auto_revoke: false,
      trigger: Badge::Trigger::None,
      show_posts: true,
      show_in_post_header: true,
    )
    badge.save!

    mapping ||= DiscourseDiscuzMedals::MedalMapping.new(discuz_medalid: medalid)
    mapping.assign_attributes(
      badge_id: badge.id,
      source_name: source_name,
      source_description: definition["description"].to_s,
      source_image: definition["image"].to_s,
      source_available: definition["available"].to_i == 1,
    )
    mapping.save!
    mapping
  end

  # Create the full path to the discuz avatar specified from user id
  def discuzx_avatar_fullpath(user_id, absolute = true)
    padded_id = user_id.to_s.rjust(9, "0")

    part_1 = padded_id[0..2]
    part_2 = padded_id[3..4]
    part_3 = padded_id[5..6]
    part_4 = padded_id[-2..-1]
    file_name = "#{part_4}_avatar_big.jpg"

    if absolute
      [File.join(DISCUZX_BASE_DIR, AVATAR_DIR, part_1, part_2, part_3, file_name), file_name]
    else
      [File.join(AVATAR_DIR, part_1, part_2, part_3, file_name), file_name]
    end
  end

  # post id is in the Discuz quote attribution URL
  def find_post_id_by_quote_number(raw)
    raw
      .scan(/\[url=([^\]]+)\]/i)
      .each do |(url)|
        normalized_url = url.gsub(/&amp;/i, "&")
        path, query = normalized_url.split("?", 2)
        next unless query
        unless path.match?(
                 %r{\A(?:https?://#{Regexp.escape(ORIGINAL_SITE_PREFIX)})?/?(?:forum\.php|redirect\.php)\z}i,
               )
          next
        end

        parameters =
          query
            .split("&")
            .each_with_object({}) do |parameter, values|
              key, value = parameter.split("=", 2)
              values[key] = value
            end
        next unless parameters["goto"] == "findpost"
        next unless parameters["pid"].to_s.match?(/\A\d+\z/)
        next unless parameters["ptid"].to_s.match?(/\A\d+\z/)

        return parameters["pid"]
      end

    nil
  end

  def convert_discuz_quotes(raw, import_id)
    root = { children: [] }
    stack = [root]
    cursor = 0

    while (match = DISCUZ_QUOTE_TAG.match(raw, cursor))
      stack.last[:children] << raw[cursor...match.begin(0)] if match.begin(0) > cursor
      tag = match[0]

      if tag.match?(%r{\A\[/quote\]\z}i)
        if stack.length > 1
          stack.pop[:closed] = true
        else
          stack.last[:children] << tag
        end
      else
        quote = { open_tag: tag, children: [], closed: false }
        stack.last[:children] << quote
        stack << quote
      end

      cursor = match.end(0)
    end

    stack.last[:children] << raw[cursor..] if cursor < raw.length
    render_discuz_quote_children(root[:children], import_id)
  end

  def render_discuz_quote_children(children, import_id)
    children
      .map do |child|
        if child.is_a?(Hash)
          render_discuz_quote(child, import_id)
        else
          child
        end
      end
      .join
  end

  def render_discuz_quote(quote, import_id)
    inner = render_discuz_quote_children(quote[:children], import_id)
    return "#{quote[:open_tag]}#{inner}" unless quote[:closed]
    return "#{quote[:open_tag]}#{inner}[/quote]" unless quote[:open_tag].casecmp?("[quote]")

    attribution = extract_discuz_quote_attribution(inner)
    body = attribution[:body].strip
    post_import_id = attribution[:post_import_id]

    if post_import_id
      post_id = post_id_from_imported_post_id(post_import_id.to_i)
      post = Post.find_by(id: post_id) if post_id

      if post
        quote_header =
          "[quote=\"#{post.user.username}, post: #{post.post_number}, topic: #{post.topic_id}\"]"
        return "#{quote_header}\n#{body}\n[/quote]"
      end

      puts "post #{import_id} quote source pid #{post_import_id} is not imported; preserving a static quote"
    end

    static_discuz_quote(attribution[:label], body)
  end

  def extract_discuz_quote_attribution(inner)
    match = DISCUZ_QUOTE_HEADER.match(inner)
    return { body: inner, label: nil, post_import_id: nil } unless match

    label = match[:label].gsub(/\s+/, " ").strip
    author, timestamp = label.split(/\s*发表于\s*/, 2)
    normalized_label = [author&.strip, timestamp&.strip].compact.reject(&:empty?).join(" 发表于 ")

    {
      body: inner[match.end(0)..].to_s,
      label: normalized_label.presence,
      post_import_id: find_post_id_by_quote_number(match[0]),
    }
  end

  def static_discuz_quote(label, body)
    quote_header =
      if label.present?
        safe_label = label.tr(",[]\"", "，［］”")
        "[quote=\"#{safe_label}\"]"
      else
        "[quote]"
      end

    "#{quote_header}\n#{body}\n[/quote]"
  end

  # for some reason, discuz inlined some png file
  # the corresponding image stored is broken in a way
  def upload_inline_image(data)
    return unless data

    puts "Creating inline image"

    encoded_photo = data["data:image/png;base64,".length..-1]
    if encoded_photo
      raw_file = Base64.decode64(encoded_photo)
    else
      puts "Error parsed inline photo", data[0..20]
      return
    end

    real_filename = "#{SecureRandom.hex}.png"
    filename = Tempfile.new(%w[inline .png])
    begin
      filename.binmode
      filename.write(raw_file)
      filename.rewind

      upload = create_upload(Discourse::SYSTEM_USER_ID, filename, real_filename)
    ensure
      begin
        filename.close
      rescue StandardError
        nil
      end
      begin
        filename.unlink
      rescue StandardError
        nil
      end
    end

    if upload.nil? || !upload.valid?
      puts "Upload not valid :("
      puts upload.errors.inspect if upload
      return nil
    end

    [upload, real_filename]
  end

  # find the uploaded file and real name from the db
  def find_upload(user, post, upload_id)
    attachment_table = table_name "forum_attachment"
    # search for table id
    sql =
      "SELECT a.pid post_id,
                  a.aid upload_id,
                  a.tableid table_id
             FROM #{attachment_table} a
            WHERE a.pid = #{post.custom_fields["import_id"]}
              AND a.aid = #{upload_id};"
    results = mysql_query(sql)

    unless (meta_data = results.first)
      puts "Couldn't find forum_attachment record meta data for post.id = #{post.id}, import_id = #{post.custom_fields["import_id"]}"
      return nil
    end

    # search for uploaded file meta data
    sql =
      "SELECT a.pid post_id,
                  a.aid upload_id,
                  a.tid topic_id,
                  a.uid user_id,
                  a.dateline uploaded_time,
                  a.filename real_filename,
                  a.attachment attachment_path,
                  a.remote is_remote,
                  a.description description,
                  a.isimage is_image,
                  a.thumb is_thumb
             FROM #{attachment_table}_#{meta_data["table_id"]} a
            WHERE a.aid = #{upload_id};"
    results = mysql_query(sql)

    unless (row = results.first)
      puts "Couldn't find attachment record for post.id = #{post.id}, import_id = #{post.custom_fields["import_id"]}"
      return nil
    end

    filename = snapshot_file(File.join(ATTACHMENT_DIR, row["attachment_path"]))
    unless filename
      @source_skip_counts["attachment_file_missing_from_snapshot"] += 1
      return nil
    end
    real_filename = row["real_filename"]
    real_filename.prepend SecureRandom.hex if real_filename[0] == "."
    upload = create_upload(user.id, filename, real_filename)

    if upload.nil? || !upload.valid?
      puts "Upload not valid :("
      puts upload.errors.inspect if upload
      return nil
    end

    [upload, real_filename]
  rescue Mysql2::Error => e
    puts "SQL Error"
    puts e.message
    puts sql
    nil
  end

  def first_exists(*items)
    items.find { |item| item.present? } || ""
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end
end

ImportScripts::DiscuzX.new.perform if $PROGRAM_NAME == __FILE__
