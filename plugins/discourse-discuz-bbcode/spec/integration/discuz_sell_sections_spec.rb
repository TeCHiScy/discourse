# frozen_string_literal: true

RSpec.describe "Discuz paid-content sections" do
  let(:parser) { DiscourseDiscuzBbcode::SellTagParser }

  it "extracts each protected body and leaves a source marker in order" do
    raw = "公开前文\n[sell=12,2]第一段[/sell]\n中间内容\n[sell=30,3][attach]659910[/attach][/sell]\n公开后文"

    sanitized, sections = parser.extract(raw, discuz_pid: 403_024)

    expect(sanitized).to eq(
      "公开前文\n[discuzsell]403024:0[/discuzsell]\n中间内容\n" \
        "[discuzsell]403024:1[/discuzsell]\n公开后文",
    )
    expect(sections.map { |section| section.slice(:section_index, :price, :credit_id) }).to eq(
      [
        { section_index: 0, price: 12, credit_id: 2 },
        { section_index: 1, price: 30, credit_id: 3 },
      ],
    )
    expect(sections.last.fetch(:body)).to eq("[attach]659910[/attach]")
    expect(sanitized).not_to include("第一段", "659910")
  end

  it "rejects malformed, nested, and unclosed sections instead of leaking them" do
    [
      "[sell=abc,1]bad[/sell]",
      "[sell=1,1]outer [sell=2,2]inner[/sell][/sell]",
      "[sell=1,1]unclosed",
      "[sell=bad,1]broken[sell=2,2]later[/sell]",
    ].each do |raw|
      expect { parser.extract(raw, discuz_pid: 403_024) }.to raise_error(ArgumentError)
    end
  end

  it "renders a marker as an inline plugin node that can be hydrated after page load" do
    SiteSetting.discourse_discuz_bbcode_sell_enabled = true
    SiteSetting.discourse_discuz_bbcode_attachments_enabled = true
    attachment_html = PrettyText.cook("[attach]659910[/attach]")
    cooked_html = PrettyText.cook("公开前文\n[discuzsell]403024:0[/discuzsell]\n公开后文")

    expect(attachment_html).to include('<span data-discuz-attachment="true" data-aid="659910">')
    expect(cooked_html).to include(
      '<span data-discuz-sell-section="true" data-pid="403024" data-cid="0">',
    )
  end
end
