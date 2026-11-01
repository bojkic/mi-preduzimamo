# frozen_string_literal: true

require "test_helper"
require "stringio"

module DecidimApp
  # Phone numbers must never reach the SQL log, including at debug level.
  #
  # Rails snapshots ActiveRecord::Base.filter_attributes from
  # config.filter_parameters before initializers populate it, so without the
  # after_initialize re-sync in config/application.rb the global filter is
  # empty and ActiveRecord::LogSubscriber prints raw bind parameters.
  class PhoneLogRedactionTest < ActiveSupport::TestCase
    BUSINESS_PHONE = "38765123456"
    LINKAGE_PHONE = "38766111222"

    test "the global ActiveRecord attribute filter actually redacts a phone" do
      # Assert BEHAVIOUR, not representation. Decidim compiles
      # config.filter_parameters into a single Regexp, so the list contains
      # /(?i:phone)/ rather than the symbol :phone — and which form is present
      # varies with boot order. What must hold is that the filter redacts.
      assert_predicate ActiveRecord::Base.filter_attributes, :any?,
                       "ActiveRecord::Base.filter_attributes must be re-synced from config.filter_parameters"

      filtered = ActiveRecord::Base.inspection_filter.filter_param("phone", BUSINESS_PHONE)

      assert_not_equal BUSINESS_PHONE, filtered,
                       "the global inspection filter must redact phone-named attributes"
    end

    test "phone numbers are redacted in SQL logs for Viber Business Messages contacts" do
      log = capture_sql_log do
        Decidim::Bih::Viber::BusinessContact.where(phone: BUSINESS_PHONE).to_a
      end

      assert_not_includes log, BUSINESS_PHONE
    end

    test "phone numbers are redacted in SQL logs for Viber linkages" do
      log = capture_sql_log do
        Decidim::Bih::Viber::Linkage.where(phone: LINKAGE_PHONE).to_a
      end

      assert_not_includes log, LINKAGE_PHONE
    end

    private

    # Attaches a debug-level logger so the assertion covers the operational
    # case that actually leaks: someone raising the log level to troubleshoot.
    def capture_sql_log
      io = StringIO.new
      original = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = ActiveSupport::Logger.new(io).tap { |logger| logger.level = Logger::DEBUG }
      yield
      io.string
    ensure
      ActiveRecord::Base.logger = original
    end
  end
end
