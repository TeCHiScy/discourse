# frozen_string_literal: true

module Jobs
  module DiscourseDiscuzMedals
    class ExpireGrants < ::Jobs::Scheduled
      every 1.day

      def execute(_args)
        expired_grants =
          ::DiscourseDiscuzMedals::UserMedalGrant.where(
            "source_expiration_at > 0 AND source_expiration_at <= ?",
            Time.current.to_i,
          )
        return unless expired_grants.exists?

        user_ids = Set.new
        badge_ids = Set.new

        ActiveRecord::Base.transaction do
          expired_grants.find_each do |grant|
            UserBadge.where(
              user_id: grant.user_id,
              badge_id: grant.badge_id,
              post_id: nil,
            ).delete_all
            user_ids << grant.user_id.to_i
            badge_ids << grant.badge_id.to_i
            grant.destroy!
          end
        end

        badge_grant_counts = UserBadge.where(badge_id: badge_ids.to_a).group(:badge_id).count
        Badge
          .where(id: badge_ids.to_a)
          .find_each do |badge|
            expected_count = badge_grant_counts.fetch(badge.id, 0)
            badge.update_columns(grant_count: expected_count) if badge.grant_count != expected_count
          end
        unless user_ids.empty?
          UserStat.update_distinct_badge_count(user_ids.to_a)
          UserBadge.update_featured_ranks!(user_ids.to_a)
        end
      end
    end
  end
end
