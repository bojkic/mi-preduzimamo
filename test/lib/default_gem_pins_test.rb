# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "resolv"
require "socket"
require "zlib"

# Dependency audit 2026-10-21, Stage A. Older Ruby 3.3 default resolv/zlib
# releases have 2026 advisories; the Gemfile retains fixed version pins. These
# tests verify the activated versions and paths, including safe default gems
# supplied by the patched interpreter, and that the disposable-email MX check
# (Resolv: account email change and Decidim's registration/admin forms) still
# works end to end through the real resolv message code, against a stub DNS
# server on loopback so no test ever leaves the box.
class DefaultGemPinsTest < ActiveSupport::TestCase
  # Answers MX questions from a fixed table; every other question gets an empty
  # NOERROR answer. Records each question so tests can prove DNS was consulted.
  class StubDnsServer
    attr_reader :questions

    def initialize(mx_table)
      @mx_table = mx_table
      @questions = Thread::Queue.new
      @socket = UDPSocket.new
      @socket.bind("127.0.0.1", 0)
      @thread = Thread.new { serve }
    end

    def port
      @socket.addr[1]
    end

    def stop
      @socket.close
      @thread.join(2)
    end

    def asked
      list = []
      list << @questions.pop until @questions.empty?
      list
    end

    private

    def serve
      loop do
        data, (_family, client_port, _name, client_host) = @socket.recvfrom(512)
        @socket.send(answer(Resolv::DNS::Message.decode(data)).encode, 0, client_host, client_port)
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def answer(query)
      reply = Resolv::DNS::Message.new(query.id)
      reply.qr = 1
      reply.opcode = query.opcode
      reply.aa = 1
      reply.rd = query.rd
      reply.rcode = Resolv::DNS::RCode::NoError
      query.each_question do |name, type|
        reply.add_question(name, type)
        @questions << [name.to_s.downcase, type]
        next unless type == Resolv::DNS::Resource::IN::MX

        Array(@mx_table[name.to_s.downcase]).each do |exchange|
          reply.add_answer(name, 300, Resolv::DNS::Resource::IN::MX.new(10, Resolv::DNS::Name.create("#{exchange}.")))
        end
      end
      reply
    end
  end

  MX_TABLE = {
    "clean-mail.test" => ["mx1.clean-mail.test"],
    # The domain itself is not on the disposable list; only its MX host is.
    "laundered-mail.test" => ["mx.mailinator.com"]
  }.freeze

  setup do
    ValidEmail2::Dns.clear_cache
    @dns = StubDnsServer.new(MX_TABLE)
  end

  teardown do
    @dns&.stop
    ValidEmail2::Dns.clear_cache
  end

  test "Bundler activates fixed resolv and zlib from the selected runtime or pinned gems" do
    assert_operator Gem::Version.new(Resolv::VERSION), :>=, Gem::Version.new("0.3.2")
    assert_operator Gem.loaded_specs.fetch("resolv").version, :>=, Gem::Version.new("0.3.2")
    resolv_file = $LOADED_FEATURES.find { |path| path.end_with?("/resolv.rb") }
    spec = Gem.loaded_specs.fetch("resolv")
    assert_equal spec.version, Gem::Version.new(Resolv::VERSION)
    expected_file = if spec.default_gem?
                      File.join(RbConfig::CONFIG.fetch("rubylibdir"), "resolv.rb")
                    else
                      File.join(spec.full_gem_path, "lib/resolv.rb")
                    end
    assert_equal File.realpath(expected_file), File.realpath(resolv_file), "resolv must load from the activated fixed release"

    assert_operator Gem::Version.new(Zlib::VERSION), :>=, Gem::Version.new("3.1.2")
    assert_operator Gem.loaded_specs.fetch("zlib").version, :>=, Gem::Version.new("3.1.2")
    assert_equal "pinned", Zlib::GzipReader.new(StringIO.new(gzip("pinned"))).read
  end

  test "the disposable check flags a domain whose MX host is disposable" do
    with_stub_resolver do
      assert ValidEmail2.disposable_emails.include?("mailinator.com")
      laundered = ValidEmail2::Address.new("citizen@laundered-mail.test")
      clean = ValidEmail2::Address.new("citizen@clean-mail.test")

      assert_predicate laundered, :disposable?
      assert_not_predicate clean, :disposable?
    end
    asked = @dns.asked
    assert_includes asked, ["laundered-mail.test", Resolv::DNS::Resource::IN::MX]
    assert_includes asked, ["clean-mail.test", Resolv::DNS::Resource::IN::MX]
  end

  test "the account form rejects an email change to a disposable-MX domain and accepts a clean one" do
    organization = create_organization
    user = create(:user, :confirmed, organization:, password: "decidim123456789", nickname: "pin_#{SecureRandom.hex(3)}")

    with_stub_resolver do
      rejected = account_form(user, "novi@laundered-mail.test")
      rejected.valid?
      assert_not_empty rejected.errors[:email], "a disposable MX host must invalidate the email"

      accepted = account_form(user, "novi@clean-mail.test")
      accepted.valid?
      assert_empty accepted.errors[:email]
    end
    assert_includes @dns.asked.map(&:first), "laundered-mail.test"
  end

  private

  def with_stub_resolver(&)
    config = { nameserver_port: [["127.0.0.1", @dns.port]], search: [], ndots: 1 }
    Resolv::DNS::Config.stub(:default_config_hash, config, &)
  end

  def account_form(user, email)
    Decidim::AccountForm.from_params(
      name: user.name,
      nickname: user.nickname,
      email:,
      old_password: "decidim123456789",
      locale: "sr"
    ).with_context(current_organization: user.organization, current_user: user)
  end

  def gzip(text)
    io = StringIO.new
    writer = Zlib::GzipWriter.new(io)
    writer.write(text)
    writer.finish
    io.string
  end
end
