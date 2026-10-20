# frozen_string_literal: true

require_relative "../../../tools/discuz_migration/smilies"

RSpec.describe DiscuzMigration::Smilies do
  let(:smiley_map) { described_class::HIGH_CONFIDENCE_MAP }

  it "converts every reviewed Discuz token to its selected shortcode" do
    expect(smiley_map.size).to eq(32)

    smiley_map.each do |discuz_token, shortcode|
      expect(described_class.convert(discuz_token)).to eq(shortcode)
    end
  end

  it "preserves unreviewed numeric tokens and unwraps named smiley tokens" do
    raw = "{:2_30:} {:2_35:} {:2_40:} {:3_42:} {:3_45:} {:3_47:} {:3_62:} {:3_64:} {:cry:}"

    expect(described_class.convert(raw)).to eq(
      "{:2_30:} {:2_35:} {:2_40:} {:3_42:} {:3_45:} {:3_47:} {:3_62:} {:3_64:} :cry:",
    )
  end

  it "converts Discuz default textual smiley codes" do
    raw = ":'( :‘( :’( :handshake :handshake: :handshakes"

    expect(described_class.convert(raw)).to eq(
      ":cry: :cry: :cry: :handshake: :handshake: :handshakes",
    )
  end

  it "does not convert tokens inside inline or fenced code" do
    raw =
      "Inline `{:2_25:}` `:'(` `:handshake` and code:\n```text\n{:2_25:} :'(
:handshake\n~~~ruby\n{:3_56:}\n~~~\n```\nOutside {:2_25:} :'(
:handshake"

    expect(described_class.convert(raw)).to eq(
      "Inline `{:2_25:}` `:'(` `:handshake` and code:\n```text\n{:2_25:} :'(
:handshake\n~~~ruby\n{:3_56:}\n~~~\n```\nOutside :smile: :cry:
:handshake:",
    )
  end

  it "cooks all selected shortcodes as native Discourse emoji" do
    shortcodes = (smiley_map.values + described_class::TEXT_SMILEY_MAP.values).uniq
    cooked = PrettyText.cook(shortcodes.join(" "))

    expect(Nokogiri::HTML5.fragment(cooked).css("img.emoji").length).to eq(shortcodes.length)
  end
end
