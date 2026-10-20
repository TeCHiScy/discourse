# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class SellPurchase < ActiveRecord::Base
    self.table_name = "discuz_sell_purchases"

    belongs_to :user, optional: true

    validates :source_log_id, :discuz_pid, :section_index, :discuz_uid, presence: true
    validates :source_log_id, uniqueness: true
  end
end
