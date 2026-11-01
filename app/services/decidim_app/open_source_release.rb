# frozen_string_literal: true

module DecidimApp
  # Objavu potvrđuje održavalac tek poslije provjera i javnog otvaranja oba repoa.
  class OpenSourceRelease
    REPOSITORY_URL = %r{\Ahttps://github\.com/bojkic/[A-Za-z0-9][A-Za-z0-9_.-]*\z}

    def initialize(environment = ENV)
      @environment = environment
    end

    def repositories
      return {} unless @environment["MI_OPEN_SOURCE_PUBLISHED"] == "true"

      app = @environment["MI_OPEN_SOURCE_APP_URL"].to_s
      engine = @environment["MI_OPEN_SOURCE_ENGINE_URL"].to_s
      return {} unless REPOSITORY_URL.match?(app) && REPOSITORY_URL.match?(engine) && app != engine

      { app: app, engine: engine }
    end

    def published?
      repositories.length == 2
    end
  end
end
