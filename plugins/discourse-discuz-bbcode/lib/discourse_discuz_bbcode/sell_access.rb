# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class SellAccess
    DISCUZ_SOURCE = "discuz_x3.5"

    def self.allowed?(section, user, guardian)
      return true if guardian.is_staff?
      return true unless protected_in_source_forum?(section)
      return false unless user && user.id.positive?

      return true if user.id == section.author_user_id
      return true if free_discuz_group?(user)

      historical_purchase?(section, user) || online_purchase?(section, user)
    end

    def self.historical_purchase?(section, user)
      SellPurchase.exists?(
        discuz_pid: section.discuz_pid,
        section_index: section.section_index,
        user_id: user.id,
      )
    end

    def self.online_purchase?(section, user)
      SellTransaction.exists?(
        discuz_pid: section.discuz_pid,
        section_index: section.section_index,
        buyer_user_id: user.id,
      )
    end

    def self.protected_in_source_forum?(section)
      return true unless SiteSetting.discourse_discuz_bbcode_sell_source_configured
      return false unless SiteSetting.discourse_discuz_bbcode_sell_source_open

      forum_ids = parse_ids(SiteSetting.discourse_discuz_bbcode_sell_forum_ids)
      forum_ids.include?(section.discuz_fid.to_i)
    end

    def self.free_discuz_group?(user)
      return false unless user.custom_fields["discuz_source"] == DISCUZ_SOURCE

      free_group_ids = parse_ids(SiteSetting.discourse_discuz_bbcode_sell_free_group_ids)
      free_group_ids.include?(user.custom_fields["discuz_group_id"].to_i)
    end

    def self.parse_ids(value)
      value
        .to_s
        .split(",")
        .filter_map do |item|
          item = item.strip
          item.to_i if item.match?(/\A\d+\z/)
        end
    end
  end
end
