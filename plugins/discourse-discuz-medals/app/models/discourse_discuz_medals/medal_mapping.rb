# frozen_string_literal: true

module ::DiscourseDiscuzMedals
  class MedalMapping < ActiveRecord::Base
    self.table_name = "discuz_medal_mappings"

    belongs_to :badge, inverse_of: :discuz_medal_mapping

    validates :discuz_medalid,
              numericality: {
                only_integer: true,
                greater_than: 0,
              },
              uniqueness: true
    validates :source_name, presence: true
  end
end
