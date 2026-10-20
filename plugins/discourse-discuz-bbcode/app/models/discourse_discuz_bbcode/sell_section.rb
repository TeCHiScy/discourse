# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class SellSection < ActiveRecord::Base
    self.table_name = "discuz_sell_sections"

    belongs_to :post
    validates :discuz_pid,
              :section_index,
              :post_id,
              :author_uid,
              :author_user_id,
              :body,
              presence: true
    validates :section_index, numericality: { greater_than_or_equal_to: 0 }
    validates :discuz_pid, uniqueness: { scope: :section_index }

    def protected_aid?(aid)
      Array(attachment_aids).include?(aid.to_i)
    end

    def effective_price
      [price.to_i, SiteSetting.discourse_discuz_bbcode_sell_max_price.to_i].min
    end
  end
end
