# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class SellCreditBalance < ActiveRecord::Base
    self.table_name = "discuz_sell_credit_balances"

    belongs_to :user

    validates :credit_id,
              numericality: {
                only_integer: true,
                greater_than_or_equal_to: 1,
                less_than_or_equal_to: 8,
              },
              uniqueness: {
                scope: :user_id,
              }
    validates :balance, numericality: { only_integer: true }
  end
end
