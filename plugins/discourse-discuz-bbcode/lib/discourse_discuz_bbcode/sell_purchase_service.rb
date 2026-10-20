# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class SellPurchaseService
    class PurchaseError < StandardError
      attr_reader :code, :status, :details

      def initialize(code, status: 422, details: {})
        @code = code
        @status = status
        @details = details
        super(code)
      end
    end

    def self.purchase!(section:, buyer:, guardian:)
      new(section: section, buyer: buyer, guardian: guardian).purchase!
    end

    def initialize(section:, buyer:, guardian:)
      @section = section
      @buyer = buyer
      @guardian = guardian
    end

    def purchase!
      raise PurchaseError.new("login_required", status: 401) unless @buyer
      raise PurchaseError.new("self_purchase") if @buyer.id == @section.author_user_id
      unless SiteSetting.discourse_discuz_bbcode_sell_purchase_enabled
        raise PurchaseError.new("purchase_disabled", status: 403)
      end
      unless SellAccess.protected_in_source_forum?(@section)
        raise PurchaseError.new("section_is_free", status: 409)
      end

      transaction = nil

      ActiveRecord::Base.transaction do
        user_ids = [@buyer.id, @section.author_user_id].sort
        locked_user_ids = User.where(id: user_ids).order(:id).lock.pluck(:id)
        unless locked_user_ids == user_ids
          raise PurchaseError.new("account_unavailable", status: 404)
        end

        next if SellAccess.allowed?(@section, @buyer, @guardian)

        existing_purchase =
          SellTransaction.find_by(
            discuz_pid: @section.discuz_pid,
            section_index: @section.section_index,
            buyer_user_id: @buyer.id,
          )
        next if existing_purchase || SellAccess.historical_purchase?(@section, @buyer)

        price = @section.effective_price
        raise PurchaseError.new("invalid_price", status: 422) if price.negative?

        buyer_balance = balance_for(@buyer.id, @section.credit_id)
        author_balance = balance_for(@section.author_user_id, @section.credit_id)
        available = buyer_balance.balance.to_i
        if available < price
          raise PurchaseError.new(
                  "insufficient_credit",
                  status: 422,
                  details: {
                    required: price,
                    available: available,
                    credit_id: @section.credit_id,
                  },
                )
        end

        tax_percent = SiteSetting.discourse_discuz_bbcode_sell_tax_percent.to_i
        unless tax_percent.between?(0, 100)
          raise PurchaseError.new("invalid_tax_configuration", status: 503)
        end
        tax_amount = (price * tax_percent) / 100
        author_income = price - tax_amount

        buyer_balance.update!(balance: available - price)
        author_balance.update!(balance: author_balance.balance.to_i + author_income)
        transaction =
          SellTransaction.create!(
            discuz_pid: @section.discuz_pid,
            section_index: @section.section_index,
            buyer_user_id: @buyer.id,
            author_user_id: @section.author_user_id,
            credit_id: @section.credit_id,
            paid_amount: price,
            tax_percent: tax_percent,
            tax_amount: tax_amount,
            author_income: author_income,
          )
      end

      transaction
    rescue ActiveRecord::RecordNotUnique
      # A parallel request may have completed the purchase while this request waited.
      nil
    end

    private

    def balance_for(user_id, credit_id)
      SellCreditBalance.find_or_create_by!(user_id: user_id, credit_id: credit_id) do |balance|
        balance.balance = 0
      end
    end
  end
end
