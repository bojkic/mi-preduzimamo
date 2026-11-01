# frozen_string_literal: true

require "test_helper"

# Dependency audit 2026-10-21, Stage A item 2: css_parser 3.0.0 -> 3.3.0
# (GHSA-w3mx-4vv9-hjpg, GHSA-84w7-hpvm-rxx2) and msgpack 1.8.0 -> 1.8.5
# (CVE-2026-54522). css_parser runs only inside premailer-rails, which inlines
# CSS into every outgoing HTML mail; msgpack runs only inside bootsnap's YAML
# and JSON compile caches. Both are exercised here through those consumers.
class PatchDependencyBumpsTest < ActiveSupport::TestCase
  class InlineStyleMailer < ApplicationMailer
    default from: "mi@example.test"
    layout false

    def styled
      mail(to: "citizen@example.test", subject: "Stil") do |format| # rubocop:disable Rails/I18nLocaleTexts -- fixture
        format.html do
          render html: <<~HTML.html_safe
            <html><head><style type="text/css">
              p.note { color: #2f5570; margin: 0 0 12px; }
              td { padding: 4px; }
            </style></head>
            <body><table><tr><td><p class="note">Poruka</p></td></tr></table></body></html>
          HTML
        end
      end
    end
  end

  test "the fixed css_parser and msgpack releases are loaded" do
    assert_operator Gem.loaded_specs.fetch("css_parser").version, :>=, Gem::Version.new("3.3.0")
    assert_operator Gem.loaded_specs.fetch("msgpack").version, :>=, Gem::Version.new("1.8.5")
  end

  test "premailer still inlines mail CSS through css_parser" do
    ActionMailer::Base.deliveries.clear
    InlineStyleMailer.styled.deliver_now
    html = ActionMailer::Base.deliveries.last.html_part&.body&.decoded || ActionMailer::Base.deliveries.last.body.decoded

    assert_match(/<p class="note" style="[^"]*color: #2f5570[^"]*margin: 0 0 12px/, html)
    assert_match(/<td style="[^"]*padding: 4px/, html)
  ensure
    ActionMailer::Base.deliveries.clear
  end

  test "css_parser expands shorthands that premailer relies on" do
    parser = CssParser::Parser.new
    parser.load_string!("p { margin: 1px 2px; color: red }")
    declarations = parser.find_by_selector("p").join(" ") # rubocop:disable Rails/DynamicFindBy -- CssParser API

    assert_includes declarations, "margin: 1px 2px"
    assert_includes declarations, "color: red"
  end

  test "msgpack round-trips the types bootsnap's YAML cache registers" do
    require "msgpack"
    factory = MessagePack::Factory.new
    factory.register_type(0x00, Symbol)
    factory.register_type(MessagePack::Timestamp::TYPE, Time,
                          packer: MessagePack::Time::Packer, unpacker: MessagePack::Time::Unpacker)
    time = Time.at(1_761_000_000, 123_456, :usec).utc
    payload = { "key" => :symbol, "list" => [1, 2.5, nil, true, "tekst"], "time" => time }

    assert_equal payload, factory.load(factory.dump(payload))
    assert MessagePack.load(MessagePack.dump("foo"), freeze: true).frozen?
  end
end
