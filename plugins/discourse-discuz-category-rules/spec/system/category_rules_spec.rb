# frozen_string_literal: true

RSpec.describe "Discuz Category Rules" do
  fab!(:admin)
  fab!(:category)

  let(:category_page) { PageObjects::Pages::Category.new }
  let(:form) { PageObjects::Components::FormKit.new(".form-kit") }

  before { sign_in(admin) }

  it "can edit and display category rules" do
    category_page.visit_settings(category)
    form.field("custom_fields.discuz_rules").fill_in("Follow **local flight rules**.")
    category_page.save_settings

    category.reload
    expect(category.custom_fields["discuz_rules"]).to eq("Follow **local flight rules**.")

    visit "/c/#{category.slug}/#{category.id}"
    expect(page).to have_css(".discuz-category-rules__content strong", text: "local flight rules")
  end
end
