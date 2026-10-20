# frozen_string_literal: true

require_relative "../../../script/import_scripts/discuz_x"

RSpec.describe ImportScripts::DiscuzX do
  let(:importer) { described_class.allocate }
  let(:source_user) { Fabricate(:user, username: "discuz_quote_author") }
  let(:source_topic) { Fabricate(:topic, user: source_user) }
  let(:source_post) { Fabricate(:post, topic: source_topic, user: source_user) }

  before do
    importer.instance_variable_set(:@internal_url_regexps, [])
    allow(importer).to receive(:post_id_from_imported_post_id) do |import_id|
      import_id.to_i == 481 ? source_post.id : nil
    end
  end

  it "converts a mapped desktop quote to Discourse quote metadata" do
    raw = <<~BBCode
      [quote][size=2][url=forum.php?mod=redirect&goto=findpost&pid=481&ptid=73][color=#999999]discuz_quote_author 发表于 2017-9-3 17:04[/color][/url][/size]
      好好好好好好好好多年前的东西了
      [/quote]
    BBCode

    converted = importer.process_discuzx_post(raw, 9001)
    expected_header =
      "[quote=\"#{source_user.username}, post: #{source_post.post_number}, topic: #{source_topic.id}\"]"

    expect(converted).to include(expected_header)
    expect(converted).to include("好好好好好好好好多年前的东西了")
    expect(converted).not_to include("pid=481")
    expect(converted).not_to include("发表于")

    quote =
      Nokogiri::HTML5.fragment(PrettyText.cook(converted, topic_id: source_topic.id + 100)).at_css(
        "aside.quote",
      )
    expect(quote["data-username"]).to eq(source_user.username)
    expect(quote["data-post"]).to eq(source_post.post_number.to_s)
    expect(quote["data-topic"]).to eq(source_topic.id.to_s)
  end

  it "keeps a static quote with its author and timestamp when the source post is missing" do
    allow(importer).to receive(:post_id_from_imported_post_id).and_return(nil)
    raw = <<~BBCode
      [quote][size=2][url=forum.php?mod=redirect&goto=findpost&pid=481&ptid=73][color=#999999]zsyfairytale 发表于 2017-9-3 17:04[/color][/url][/size]
      好好好好好好好好多年前的东西了
      [/quote]
    BBCode

    converted = importer.process_discuzx_post(raw, 9002)

    expect(converted).to include('[quote="zsyfairytale 发表于 2017-9-3 17:04"]')
    expect(converted).to include("好好好好好好好好多年前的东西了")
    expect(converted).not_to include("bbs.sinofsx.org")
    expect(converted).not_to include("pid=481")

    quote = Nokogiri::HTML5.fragment(PrettyText.cook(converted)).at_css("aside.quote")
    expect(quote["data-username"]).to eq("zsyfairytale 发表于 2017-9-3 17:04")
    expect(quote["data-post"]).to be_nil
  end

  it "keeps the mobile attribution and excerpt as a static quote" do
    raw = <<~BBCode
      [quote][color=#999999]mobile_author 发表于 2017-9-3 17:04[/color]
      [color=#999999]移动端引用摘录[/color][/quote]
    BBCode

    converted = importer.process_discuzx_post(raw, 9003)

    expect(converted).to include('[quote="mobile_author 发表于 2017-9-3 17:04"]')
    expect(converted).to include("移动端引用摘录")
    expect(converted).not_to include("[color=")
  end

  it "converts nested quotes independently without swallowing adjacent quote blocks" do
    inner_user = Fabricate(:user, username: "inner_quote_author")
    inner_topic = Fabricate(:topic, user: inner_user)
    inner_post = Fabricate(:post, topic: inner_topic, user: inner_user)
    allow(importer).to receive(:post_id_from_imported_post_id) do |import_id|
      { 481 => source_post.id, 482 => inner_post.id }[import_id.to_i]
    end
    raw = <<~BBCode
      [quote][size=2][url=forum.php?mod=redirect&goto=findpost&pid=481&ptid=73][color=#999999]outer_author 发表于 2017-9-3 17:04[/color][/url][/size]
      outer excerpt
      [quote][size=2][url=forum.php?mod=redirect&goto=findpost&pid=482&ptid=74][color=#999999]inner_author 发表于 2017-9-3 17:05[/color][/url][/size]
      inner excerpt[/quote]
      [/quote]
      [quote][color=#999999]mobile_author 发表于 2017-9-3 17:06[/color]
      [color=#999999]separate quote[/color][/quote]
    BBCode

    converted = importer.process_discuzx_post(raw, 9004)

    expect(converted.scan('[quote="').length).to eq(3)
    expect(converted).to include("outer excerpt", "inner excerpt", "separate quote")
    expect(converted).to include("inner_quote_author, post: #{inner_post.post_number}")

    cooked_quotes =
      Nokogiri::HTML5.fragment(PrettyText.cook(converted, topic_id: source_topic.id + 100)).css(
        "aside.quote",
      )
    expect(cooked_quotes.length).to eq(3)
  end
end
