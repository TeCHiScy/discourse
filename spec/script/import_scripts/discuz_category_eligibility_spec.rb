# frozen_string_literal: true

require_relative "../../../tools/discuz_migration/category_eligibility"

RSpec.describe DiscuzCategoryEligibility do
  it "sets the site to the three-level category limit" do
    allow(SiteSetting).to receive(:max_category_nesting=)
    allow(SiteSetting).to receive(:max_category_nesting).and_return(3)

    described_class.ensure_site_nesting!

    expect(SiteSetting).to have_received(:max_category_nesting=).with(3)
  end

  let(:rows) do
    [
      { "id" => 40, "parent_id" => 0, "name" => "Flight Center", "status" => 1 },
      { "id" => 104, "parent_id" => 40, "name" => "Airline A", "status" => 1 },
      { "id" => 105, "parent_id" => 104, "name" => "Company records", "status" => 1 },
      { "id" => 106, "parent_id" => 40, "name" => "Airline B", "status" => 1 },
      { "id" => 107, "parent_id" => 106, "name" => "Company records", "status" => 1 },
    ]
  end

  it "keeps same-named forums under their distinct third-level parents" do
    parents =
      described_class.effective_parent_ids(rows, max_nesting: described_class::MAX_CATEGORY_NESTING)
    names =
      described_class.display_names(
        rows,
        effective_parent_ids: parents,
        reserved_root_names: Set.new,
      )

    expect(parents[105]).to eq(104)
    expect(parents[107]).to eq(106)
    expect(names.values_at(105, 107)).to eq(["Company records", "Company records"])
  end
end
