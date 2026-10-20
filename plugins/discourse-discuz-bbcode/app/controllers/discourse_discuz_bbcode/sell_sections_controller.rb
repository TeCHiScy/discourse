# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class SellSectionsController < ::ApplicationController
    requires_plugin "discourse-discuz-bbcode"

    def show
      raise Discourse::NotFound unless SiteSetting.discourse_discuz_bbcode_sell_enabled

      post, section = find_post_and_section!

      response.headers["Cache-Control"] = "private, no-store"
      render json: section_payload(section)
    end

    def purchase
      raise Discourse::NotFound unless SiteSetting.discourse_discuz_bbcode_sell_enabled

      _post, section = find_post_and_section!
      response.headers["Cache-Control"] = "private, no-store"
      SellPurchaseService.purchase!(section: section, buyer: current_user, guardian: guardian)
      render json: section_payload(section)
    rescue SellPurchaseService::PurchaseError => error
      render json: { error: error.code }.merge(error.details), status: error.status
    end

    private

    def find_post_and_section!
      post = Post.find_by(id: strict_positive_integer(params[:post_id]))
      section =
        SellSection.find_by(discuz_pid: valid_discuz_pid, section_index: valid_section_index)
      unless post && section && section.post_id == post.id && guardian.can_see?(post)
        raise Discourse::NotFound
      end

      [post, section]
    end

    def section_payload(section)
      if SellAccess.allowed?(section, current_user, guardian)
        return(
          {
            locked: false,
            html: PrettyText.cook(section.body, user_id: section.author_user_id).to_s,
          }
        )
      end

      balance =
        if current_user
          (
            SellCreditBalance.find_by(
              user_id: current_user.id,
              credit_id: section.credit_id,
            )&.balance || 0
          ).to_i
        end
      price = section.effective_price
      {
        locked: true,
        price: price,
        credit_id: section.credit_id,
        credit_title: section.credit_title,
        credit_unit: section.credit_unit,
        balance: balance,
        tax_percent: SiteSetting.discourse_discuz_bbcode_sell_tax_percent.to_i,
        requires_login: current_user.nil?,
        purchase_enabled:
          SiteSetting.discourse_discuz_bbcode_sell_purchase_enabled &&
            SellAccess.protected_in_source_forum?(section),
        can_purchase:
          current_user.present? && current_user.id != section.author_user_id &&
            SiteSetting.discourse_discuz_bbcode_sell_purchase_enabled &&
            SellAccess.protected_in_source_forum?(section),
      }
    end

    def valid_post_id
      strict_positive_integer(params[:post_id])
    end

    def valid_discuz_pid
      strict_positive_integer(params[:pid])
    end

    def valid_section_index
      value = params[:cid].to_s
      raise Discourse::NotFound unless value.match?(/\A\d+\z/)

      value.to_i
    end

    def strict_positive_integer(value)
      text = value.to_s
      raise Discourse::NotFound unless text.match?(/\A[1-9]\d*\z/)

      text.to_i
    end
  end
end
