# frozen_string_literal: true

require "test_helper"

module DecidimApp
  # Guards the fix in config/initializers/filter_parameter_logging.rb for an
  # initializer-ordering trap in Rails 7.2: the framework's own
  # `active_record.set_filter_attributes` railtie does
  #
  #     self.filter_attributes += Rails.application.config.filter_parameters
  #
  # and that railtie runs BEFORE any config/initializers/*.rb file (this one
  # included) and before other engines' initializers that also contribute to
  # config.filter_parameters. So it snapshots the list before it is fully
  # populated, and `ActiveRecord::Base.filter_attributes` silently ends up
  # missing everything — verified directly on this app: `config
  # .filter_parameters` correctly included `:phone`, but
  # `ActiveRecord::Base.filter_attributes` was `[]`.
  #
  # That matters specifically because `ActiveRecord::LogSubscriber#filter`
  # (activerecord-7.2.3.2/lib/active_record/log_subscriber.rb) hardcodes
  # `ActiveRecord::Base.inspection_filter` — built from the GLOBAL
  # `ActiveRecord::Base.filter_attributes` — to redact SQL bind-parameter
  # values at debug log level. It does NOT consult any per-model
  # `self.filter_attributes = [...]` override (see
  # Decidim::Bih::CitizenPhoneRecord#phone,
  # Decidim::Bih::Goodwill::RewardFulfillment#entry_code): those only redact
  # that model's own #inspect output, and do nothing for bind-parameter SQL
  # logging.
  #
  # This is an integration-style test: it exercises the state produced by
  # this process's boot (it does not re-run app initialization mid-test). If
  # the `Rails.application.config.after_initialize` re-sync block is removed
  # from filter_parameter_logging.rb, the NEXT full boot of this suite runs
  # without it, `ActiveRecord::Base.filter_attributes` reverts to whatever
  # the railtie captured early (typically far short of the full list), and
  # the second test below starts failing: the raw value resurfaces in the
  # captured SQL log instead of being replaced with `[FILTERED]`.
  #
  # The write below uses Decidim::Bih::LoginToken#phone rather than
  # decidim_bih_citizen_phones.phone / reward_fulfillments.entry_code
  # directly: those two tables' engine migrations have not landed in this
  # shared dev/test database yet (separate, in-flight work), whereas
  # LoginToken's nullable `phone` column (populated with the raw number for
  # "verify"-purpose tokens, per its own comments) already exists and is
  # matched by the exact same `:phone` entry in config.filter_parameters.
  #
  # Deliberately NOT Decidim::User: it is `has_paper_trail`-tracked, and
  # PaperTrail's own `versions.object_changes` column serializes the whole
  # changeset — including the raw email — into one JSON blob under a column
  # named "object_changes", not "email". filter_attributes matches by
  # *column name*, so that leak is real but is a separate, PaperTrail-level
  # concern; it would fail this test for a reason unrelated to the fix here.
  # LoginToken carries no such secondary audit trail, so a leak in this test
  # can only mean the mechanism under test — the after_initialize re-sync
  # feeding ActiveRecord::Base.filter_attributes, consumed by the global
  # LogSubscriber#filter path — is broken.
  class SqlBindFilterAttributesTest < ActiveSupport::TestCase
    setup do
      @organization = create_organization
      @user = FactoryBot.create(:user, :confirmed, organization: @organization)
    end

    # Declared here rather than derived from config.filter_parameters, because
    # that list cannot be compared against filter_attributes after boot.
    # Rails 7.1+ `config.precompile_filter_parameters` REPLACES
    # config.filter_parameters with a precompiled form — a single
    # Regexp.union of every key, plus any Procs — in its own
    # after_initialize. So by the time a test reads it, the individual
    # symbols this app and its engines registered are gone, collapsed into
    # one /(?i:passw)|(?i:email)|.../ entry that filter_attributes (correctly)
    # does not contain. Asserting list containment therefore compares the
    # symbol list against its own compiled union and always fails, while
    # proving nothing about redaction. Assert the keys we actually rely on.
    FILTERED_KEYS = [:passw, :email, :secret, :token, :_key, :crypt, :salt,
                     :certificate, :otp, :ssn, :address, :phone,
                     :mobile_phone_number, :entry_code].freeze

    test "attribute and request filters do not share a mutable array" do
      assert_not_same Rails.application.config.filter_parameters, ActiveRecord::Base.filter_attributes
      before = ActiveRecord::Base.filter_attributes.dup
      marker = "synthetic_upgrade_filter_probe"
      Rails.application.config.filter_parameters << marker
      assert_equal before, ActiveRecord::Base.filter_attributes
    ensure
      Rails.application.config.filter_parameters.delete(marker)
    end

    test "ActiveRecord::Base.filter_attributes was re-synced from config.filter_parameters after boot" do
      assert ActiveRecord::Base.filter_attributes.present?,
             "ActiveRecord::Base.filter_attributes is empty — the re-sync in config/application.rb did not run. " \
             "Rails 7.2's active_record.set_filter_attributes railtie snapshots config.filter_parameters before " \
             "app initializers populate it, so without the re-sync this is [] and debug-level SQL bind logging " \
             "prints raw values."

      # Assert the GUARANTEE, not the representation. Two things make list
      # membership the wrong assertion here:
      #   * Rails 7.1+ config.precompile_filter_parameters collapses the list
      #     into a single Regexp.union, so the symbols registered by this app
      #     and its engines are not individually present afterwards.
      #   * The re-sync assigns whatever config.filter_parameters holds at
      #     after_initialize time, which is that compiled form.
      # Both are correct behaviour and both redact. Asking the filter itself
      # whether it redacts a key is true under either representation.
      filter = ActiveRecord::Base.inspection_filter

      FILTERED_KEYS.each do |key|
        assert_equal "[FILTERED]", filter.filter_param(key.to_s, "secret-value"),
                     "#{key.inspect} is registered in config/initializers/filter_parameter_logging.rb " \
                     "but ActiveRecord::Base.inspection_filter does not redact it — the re-sync regressed"
      end
    end

    test "a raw phone number is redacted from debug-level SQL bind-parameter logs, not just #inspect" do
      raw_phone = "+387#{rand(60_000_000..69_999_999)}"

      log = capture_sql_debug_log do
        Decidim::Bih::LoginToken.issue!(user: @user, purpose: "verify", phone: raw_phone)
      end

      assert_includes log, "[FILTERED]",
                      "expected the SQL bind-parameter log to contain a [FILTERED] marker for :phone"
      assert_not_includes log, raw_phone,
                          "the raw phone number leaked into the SQL bind-parameter log — filter_attributes regressed"
    end

    private

    # Mirrors Decidim::Bih::ConfigTest#capture_logs, but swaps
    # ActiveRecord::Base.logger specifically rather than Rails.logger:
    # ActiveRecord::LogSubscriber reads its logger via
    # `ActiveRecord::Base.logger` directly, so that is the one that has to be
    # at DEBUG level and captured for a bind-parameter log line to be emitted
    # at all.
    def capture_sql_debug_log
      io = StringIO.new
      original_logger = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = Logger.new(io, level: Logger::DEBUG)
      yield
      io.string
    ensure
      ActiveRecord::Base.logger = original_logger
    end
  end
end
