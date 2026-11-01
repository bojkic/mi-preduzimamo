# frozen_string_literal: true

module DecidimApp
  # "Režim lansiranja": while the neighbourhood race runs (6.9.–14.10.2026
  # 20:00, host config in decidim_bih_race.rb) the header, quick actions,
  # bottom nav, main menu and hero push three actions — register, ask Milica,
  # report a problem. It switches itself off at the freeze, no deploy needed.
  # An operator can force it with Setting(launch, mode) = on|off, which takes
  # effect on the next request — the answer is memoized per request, never at
  # boot.
  module LaunchMode
    SETTING_NAMESPACE = "launch"
    SETTING_KEY = "mode"
    ZONE = "Europe/Sarajevo"

    module_function

    # Cached per request (spec 6.1) in DecidimApp::Current, which the Rails
    # executor resets after every request and every job. A single render asks
    # this six or more times and each miss is a Setting query. Passing `now:`
    # explicitly — which only tests do — bypasses the memo in both directions,
    # so a test can walk the clock without seeding or clearing it.
    def active?(organization, now: nil)
      return within_window?(organization, now) if now

      cache = (DecidimApp::Current.launch_mode_by_org ||= {})
      key = cache_key_for(organization)
      return cache[key] if cache.has_key?(key)

      cache[key] = within_window?(organization, Time.current)
    end

    def race_archived?(organization)
      organization.present? && Decidim::Bih::Race::Edition.for(organization)&.finalized_at.present?
    end

    def within_window?(organization, now)
      return false if race_archived?(organization)

      forced = forced_mode(organization)
      return forced == "on" if forced

      from = parse(Decidim::Bih.race_window_from)
      to = parse(Decidim::Bih.race_window_to)
      return false if from.nil? || to.nil?

      now >= from && now <= to
    end

    # Key on the id, not the record: two AR instances of the same organization
    # loaded in one request must share the answer. nil (no organization) is a
    # legitimate key — it answers "off" just as consistently.
    def cache_key_for(organization)
      organization.respond_to?(:id) ? organization.id : organization
    end

    def forced_mode(organization)
      return nil if organization.blank? || !Decidim::Bih::Setting.table_available?

      value = Decidim::Bih::Setting.namespace_for(organization, SETTING_NAMESPACE)[SETTING_KEY].to_s
      value.presence_in(%w(on off))
    rescue StandardError
      nil
    end

    def parse(raw)
      return nil if raw.blank?
      return raw if raw.respond_to?(:utc)

      ActiveSupport::TimeZone[ZONE].parse(raw.to_s)
    end
  end
end
