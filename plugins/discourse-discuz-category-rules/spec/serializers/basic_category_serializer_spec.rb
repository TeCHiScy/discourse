# frozen_string_literal: true

describe BasicCategorySerializer do
  fab!(:category)

  it "serializes category rules as cooked HTML" do
    category.custom_fields["discuz_rules"] = "Follow **local flight rules**."
    category.save_custom_fields(true)

    serialized = BasicCategorySerializer.new(category, root: false).as_json

    expect(serialized[:discuz_rules_html]).to include("<strong>local flight rules</strong>")
  end

  it "omits cooked rules when the category has no rules" do
    serialized = BasicCategorySerializer.new(category, root: false).as_json

    expect(serialized[:discuz_rules_html]).to be_nil
  end
end
