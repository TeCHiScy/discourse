# frozen_string_literal: true

module DiscuzMigration
  module Medals
    MAX_BADGE_NAME_LENGTH = 100

    def self.parse_memberships(serialized, now_epoch: Time.now.to_i)
      active_by_id = {}
      expired_count = 0
      malformed_count = 0

      serialized
        .to_s
        .split("\t")
        .each do |token|
          parts = token.strip.split("|", -1)
          medal_id = parts[0].to_s.strip
          expiration = parts[1].to_s.strip
          valid_expiration = expiration.empty? || expiration.match?(/\A\d+\z/)

          unless parts.length <= 2 && medal_id.match?(/\A[1-9]\d*\z/) && valid_expiration
            malformed_count += 1
            next
          end

          expiration_epoch = expiration.empty? ? 0 : expiration.to_i
          if expiration_epoch.positive? && expiration_epoch <= now_epoch
            expired_count += 1
            next
          end

          id = medal_id.to_i
          previous = active_by_id[id]
          if previous.nil? || previous[:expiration].positive? && expiration_epoch.zero? ||
               expiration_epoch > previous[:expiration]
            active_by_id[id] = { medalid: id, expiration: expiration_epoch }
          end
        end

      {
        assignments: active_by_id.values.sort_by { |assignment| assignment[:medalid] },
        expired_count: expired_count,
        malformed_count: malformed_count,
      }
    end

    def self.badge_name(medalid, source_name)
      suffix = " · DZ#{medalid}"
      base = source_name.to_s.presence || "Discuz 勋章 #{medalid}"
      available_length = MAX_BADGE_NAME_LENGTH - suffix.length
      "#{base.truncate(available_length, omission: "")}#{suffix}"
    end
  end
end
