# frozen_string_literal: true

module ::DiscourseDiscuzMedals
  class UserMedalGrant < ActiveRecord::Base
    self.table_name = "discuz_user_medal_grants"

    belongs_to :user
    belongs_to :badge

    validates :discuz_uid,
              :discuz_medalid,
              :user_id,
              numericality: {
                only_integer: true,
                greater_than: 0,
              }
    validates :discuz_medalid, uniqueness: { scope: :discuz_uid }
  end
end
