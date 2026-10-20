# frozen_string_literal: true

RSpec.describe "Discuz BBCode tables" do
  it "renders explicit rows and merged cells while dropping unsupported widths" do
    cooked_html = PrettyText.cook(<<~BBCode)
        [table=98%]
        [tr]
        [td=4,1,98%]活动限制快查表[/td]
        [/tr]
        [/table]
      BBCode

    expect(cooked_html).to match_html <<~HTML
      <div class="md-table">
        <table>
          <tbody>
            <tr><td colspan="4">活动限制快查表</td></tr>
          </tbody>
        </table>
      </div>
    HTML
  end

  it "renders supported inline BBCode inside cells" do
    cooked_html = PrettyText.cook(<<~BBCode)
        [table]
        [tr]
        [td][b]加粗[/b] [url=https://example.com]链接[/url][/td]
        [/tr]
        [/table]
      BBCode

    expect(cooked_html).to include("<span class=\"bbcode-b\">加粗</span>")
    expect(cooked_html).to include('<a href="https://example.com"')
    expect(cooked_html).to include("链接</a>")
  end

  it "supports the legacy pipe-separated table syntax" do
    cooked_html = PrettyText.cook(<<~BBCode)
        [table]
        左侧\\|文字|右侧
        第二行|单元格
        [/table]
      BBCode

    expect(cooked_html).to match_html <<~HTML
      <div class="md-table">
        <table>
          <tbody>
            <tr><td>左侧|文字</td><td>右侧</td></tr>
            <tr><td>第二行</td><td>单元格</td></tr>
          </tbody>
        </table>
      </div>
    HTML
  end

  it "leaves malformed table structure readable" do
    cooked_html = PrettyText.cook("[table]\n[td]孤立单元格[/td]\n[/table]")

    expect(cooked_html).to include("孤立单元格")
    expect(cooked_html).not_to include("<table")
  end

  it "can be disabled without rewriting the raw BBCode" do
    SiteSetting.discourse_discuz_bbcode_tables_enabled = false
    cooked_html = PrettyText.cook("[table]\n[tr]\n[td]文字[/td]\n[/tr]\n[/table]")

    expect(cooked_html).to include("[table]")
    expect(cooked_html).not_to include("<table")
  end
end
