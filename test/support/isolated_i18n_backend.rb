# frozen_string_literal: true

require "i18n"

module MiTestSupport
  # Fixture translations must not lazily import the host locale files. Keep the
  # global load path intact: changing it reloads the previous backend and drops
  # dynamically loaded Faker translations used by later Rails tests.
  class IsolatedI18nBackend < I18n::Backend::Simple
    def load_translations(*filenames)
      super unless filenames.empty?
    end
  end
end
