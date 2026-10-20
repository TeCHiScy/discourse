# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class SellTransaction < ActiveRecord::Base
    self.table_name = "discuz_sell_transactions"

    belongs_to :buyer, class_name: "User"
    belongs_to :author, class_name: "User"

    validates :discuz_pid,
              :section_index,
              :buyer_user_id,
              :author_user_id,
              :credit_id,
              :paid_amount,
              :tax_percent,
              :tax_amount,
              :author_income,
              presence: true
    validates :buyer_user_id, uniqueness: { scope: %i[discuz_pid section_index] }
  end
end
