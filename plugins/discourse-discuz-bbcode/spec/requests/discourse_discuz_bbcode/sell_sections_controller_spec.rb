# frozen_string_literal: true

RSpec.describe DiscourseDiscuzBbcode::SellSectionsController do
  fab!(:author, :user)
  fab!(:buyer, :user)
  fab!(:sell_post) { Fabricate(:post, user: author) }

  let!(:section) do
    DiscourseDiscuzBbcode::SellSection.create!(
      discuz_pid: 7_001_234,
      section_index: 0,
      post_id: sell_post.id,
      author_uid: author.id,
      author_user_id: author.id,
      discuz_fid: 12,
      price: 4,
      credit_id: 2,
      credit_title: "金币",
      credit_unit: "",
      body: "付费正文",
      attachment_aids: [],
    )
  end

  before do
    SiteSetting.discourse_discuz_bbcode_sell_enabled = true
    SiteSetting.discourse_discuz_bbcode_sell_source_configured = true
    SiteSetting.discourse_discuz_bbcode_sell_source_open = true
    SiteSetting.discourse_discuz_bbcode_sell_purchase_enabled = true
    SiteSetting.discourse_discuz_bbcode_sell_tax_percent = 50
    SiteSetting.discourse_discuz_bbcode_sell_max_price = 100
    SiteSetting.discourse_discuz_bbcode_sell_forum_ids = "12"
    SiteSetting.discourse_discuz_bbcode_sell_free_group_ids = "23,24"
    DiscourseDiscuzBbcode::SellCreditBalance.create!(user_id: buyer.id, credit_id: 2, balance: 10)
    DiscourseDiscuzBbcode::SellCreditBalance.create!(user_id: author.id, credit_id: 2, balance: 3)
  end

  def section_url
    "/discuz-sell-sections/#{section.discuz_pid}/#{section.section_index}"
  end

  describe "#show" do
    it "shows the current buyer's currency, price, and balance without revealing the body" do
      sign_in(buyer)

      get section_url, params: { post_id: sell_post.id }, xhr: true

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include(
        "locked" => true,
        "price" => 4,
        "credit_id" => 2,
        "credit_title" => "金币",
        "balance" => 10,
        "can_purchase" => true,
      )
      expect(response.parsed_body.to_json).not_to include("付费正文")
    end

    it "honors Discuz groups configured to view paid sections for free" do
      buyer.custom_fields["discuz_source"] = "discuz_x3.5"
      buyer.custom_fields["discuz_group_id"] = "24"
      buyer.save_custom_fields
      sign_in(buyer)

      get section_url, params: { post_id: sell_post.id }, xhr: true

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include("locked" => false)
      expect(response.parsed_body["html"]).to include("付费正文")
      expect(DiscourseDiscuzBbcode::SellTransaction.count).to eq(0)
    end
  end

  describe "#purchase" do
    it "debits the buyer, credits the author after the Discuz tax, records the sale, and unlocks it" do
      sign_in(buyer)

      post "#{section_url}/purchase", params: { post_id: sell_post.id }, xhr: true

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include("locked" => false)
      expect(response.parsed_body["html"]).to include("付费正文")
      expect(
        DiscourseDiscuzBbcode::SellCreditBalance.find_by!(user_id: buyer.id, credit_id: 2).balance,
      ).to eq(6)
      expect(
        DiscourseDiscuzBbcode::SellCreditBalance.find_by!(user_id: author.id, credit_id: 2).balance,
      ).to eq(5)
      expect(
        DiscourseDiscuzBbcode::SellTransaction.find_by!(
          discuz_pid: section.discuz_pid,
          section_index: section.section_index,
          buyer_user_id: buyer.id,
        ),
      ).to have_attributes(paid_amount: 4, tax_percent: 50, tax_amount: 2, author_income: 2)
    end

    it "does not charge twice if the buyer repeats the purchase request" do
      sign_in(buyer)

      2.times { post "#{section_url}/purchase", params: { post_id: sell_post.id }, xhr: true }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include("locked" => false)
      expect(DiscourseDiscuzBbcode::SellTransaction.count).to eq(1)
      expect(
        DiscourseDiscuzBbcode::SellCreditBalance.find_by!(user_id: buyer.id, credit_id: 2).balance,
      ).to eq(6)
    end

    it "leaves both balances unchanged when the buyer cannot afford the section" do
      sign_in(buyer)
      DiscourseDiscuzBbcode::SellCreditBalance.find_by!(user_id: buyer.id, credit_id: 2).update!(
        balance: 2,
      )

      post "#{section_url}/purchase", params: { post_id: sell_post.id }, xhr: true

      expect(response.status).to eq(422)
      expect(response.parsed_body).to include("error" => "insufficient_credit")
      expect(
        DiscourseDiscuzBbcode::SellCreditBalance.find_by!(user_id: buyer.id, credit_id: 2).balance,
      ).to eq(2)
      expect(
        DiscourseDiscuzBbcode::SellCreditBalance.find_by!(user_id: author.id, credit_id: 2).balance,
      ).to eq(3)
      expect(DiscourseDiscuzBbcode::SellTransaction.count).to eq(0)
    end

    it "does not let the author pay for their own content" do
      sign_in(author)

      post "#{section_url}/purchase", params: { post_id: sell_post.id }, xhr: true

      expect(response.status).to eq(422)
      expect(response.parsed_body).to include("error" => "self_purchase")
    end

    it "keeps content free in forums where Discuz dc_sell was disabled" do
      section.update!(discuz_fid: 99)
      sign_in(buyer)

      post "#{section_url}/purchase", params: { post_id: sell_post.id }, xhr: true

      expect(response.status).to eq(409)
      expect(response.parsed_body).to include("error" => "section_is_free")
      expect(
        DiscourseDiscuzBbcode::SellCreditBalance.find_by!(user_id: buyer.id, credit_id: 2),
      ).to have_attributes(balance: 10)
    end
  end
end
