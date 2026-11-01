# frozen_string_literal: true

require "test_helper"
require_relative "../support/native_milica_provider"
require_relative "../support/synthetic_read_port_data"

class MilicaV1ConversationTest < ActionDispatch::IntegrationTest
  include NativeMilicaProvider
  include SyntheticReadPortData
  include ::Devise::Test::IntegrationHelpers

  Dialogue = Decidim::Bih::Concierge::Dialogue
  XHR = { "X-Requested-With" => "XMLHttpRequest", "Content-Type" => "application/json" }.freeze
  FLAG_KEYS = %w(DECIDIM_CONCIERGE_ORG_HOST MILICA_DIALOGUE_ENABLED MILICA_DIALOGUE_AUDIENCE MILICA_DIALOGUE_COHORT_USER_IDS
                 MILICA_CONVERSATION_MODEL MILICA_COMPOSITION_ENABLED MILICA_CONVERSATIONAL_WRITES_ENABLED).freeze

  setup do
    @previous_env = FLAG_KEYS.index_with { |key| ENV.fetch(key, nil) }
    @organization = create_organization
    host! @organization.host
    ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @organization.host
    ENV["MILICA_DIALOGUE_ENABLED"] = "true"
    ENV["MILICA_DIALOGUE_AUDIENCE"] = "public"
    ENV["MILICA_DIALOGUE_COHORT_USER_IDS"] = ""
    ENV["MILICA_COMPOSITION_ENABLED"] = "false"
    ENV["MILICA_CONVERSATIONAL_WRITES_ENABLED"] = "false"
    ENV.delete("MILICA_CONVERSATION_MODEL")
    install_native_provider
    @client = @native_provider
    # Parallel conversation suites must not compete for the same global lease.
    # Keep the real admission behavior with a private key for this test.
    @admission = Dialogue::AdmissionControl.new(key: "milica:conversation-test:#{SecureRandom.hex(16)}")
    @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-synthetic-field", name: { sr: "Izmišljeno polje" }, boundary: {})
    @now = Time.utc(2040, 9, 16, 8)
    install_synthetic_read_port_data(day: @now.to_date)
    aliases = File.join(@synthetic_service_root, "conversation-place-aliases.yml")
    File.write(aliases, YAML.dump("revision" => "synthetic-v1-conversation", "inflections" => { "izmisljeno polje" => ["Izmišljenom polju"] }))
    swap_service_constant(DecidimApp::Bijeljina::PlaceAliasRegistry, :CONFIG_PATH, aliases)
    sources = DecidimApp::Bijeljina::CityServiceSources
    rows = sources::SOURCES.map { |row| row[:key] == "water_service" ? row.merge(source_url: "https://water.example.invalid/source") : row }
    swap_service_constant(sources, :SOURCES, rows.freeze)
    travel_to(@now)
    reset_concierges
    Rails.cache.clear
  end

  teardown do
    uninstall_native_provider
    restore_synthetic_service_directory
    @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    reset_concierges
    travel_back
  end

  test "report guidance remains portable through a native public-source followup" do
    @client.queue_public("read_platform_guidance", { subject: "reports" }) { |_| "Prijavu popuni ovdje: https://#{@organization.host}/biceriseno/prijave/new" }
    assert_no_difference -> { Decidim::Bih::Report.count } do
      with_model do
        first = chat("Pišem ti preko Facebook Messengera. Kako da prijavim rupu na putu?")
        assert_includes first.fetch("reply"), "https://#{@organization.host}/biceriseno/prijave/new"
        second = chat("Ne vidim dugme. Napiši link ovdje.")
        assert_includes second.fetch("reply"), "https://#{@organization.host}/biceriseno/prijave/new"
      end
    end
    assert_equal 2, @client.calls.size
    assert_includes JSON.generate(@client.calls.first[:contents]), "Kako da prijavim"
  end

  test "reporting journey keeps intent through place and street correction without writes or transferred draft" do
    @client.queue_protected("prepare_report", { description: "Smeće nije odvezeno" })
    @client.queue_protected("prepare_report", { area_query: "Izmišljeno polje" })
    @client.queue_protected("prepare_report", { address: "Izmišljena breza" })
    assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::Bih::KomsilukPost.count }] do
      with_model do
        first = chat("Smeće nije odvezeno, hoću prijaviti")
        assert_includes first.fetch("reply"), "U kojem naselju"
        second = chat("U Izmišljenom polju")
        assert_includes second.fetch("reply"), Decidim::Bih::Engine.routes.url_helpers.new_report_path
        assert_includes second.fetch("reply"), "Ništa još nije poslano"
        third = chat("Ne ta ulica, Izmišljena breza")
        assert_includes third.fetch("reply"), "razgovor ih ne prenosi automatski"
        assert_not_includes third.fetch("reply"), "lat="
      end
    end
    assert_equal 3, @client.calls.size
    hint = @client.calls.last.fetch(:system_instruction)
    assert_includes hint, '"active_task":"report_problem"'
    assert_not_includes JSON.generate(@client.calls.last.fetch(:contents)), "Smeće nije odvezeno"
  end

  test "parking registration and explicit continuation use real destinations without claiming account creation" do
    @client.queue_public("read_parking_tariffs", { zone: "white" })
    @client.queue_protected("account_action", { action: "registration" })
    assert_no_difference -> { Decidim::User.count } do
      with_model do
        first = chat("Koliko košta parking?")
        assert first.fetch("reply").present?
        registration = chat("Kako da se registrujem?")
        # A citizen with no account is sent to the host's configured
        # registration path, never to the browser return ticket: when that
        # ticket is gone (a later tap, another device) the handoff resolves to
        # /users/sign_in, which is the login form. See
        # RegistrationPort::WEB_HANDOFF_STEPS.
        assert_includes registration.fetch("reply"), Decidim::Bih.registration_path
        assert_not_includes registration.fetch("reply"), DecidimApp::Bijeljina::Milica::RegistrationPort::WEB_HANDOFF_PATH
        assert_not_includes registration.fetch("reply"), "/users/sign_up"
        assert_includes registration.fetch("reply"), I18n.t("decidim.bih.dialogue.handoff_register", locale: :sr, url: Decidim::Bih.registration_path)
        # This remains the same browser conversation; no completed account or
        # automatic transfer across a later sign-in boundary is asserted.
        assert_not_includes registration.fetch("reply"), "Nalog je kreiran"
        @client.queue_public("read_parking_tariffs", { zone: "white" })
        resumed = chat("nastavi")
        assert resumed.fetch("reply").present?
        assert_not_includes resumed.fetch("reply"), "Novi nalog"
      end
    end
    assert_equal 5, @client.calls.size
  end

  test "assigned citizen can start a komsiluk change after checking status without changing the profile in chat" do
    actor = FactoryBot.create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
    profile.assign_komsiluk!(@area, source: "dropdown")
    original_profile = profile.reload.attributes
    sign_in actor
    assert_no_difference [-> { Decidim::Bih::CitizenProfile.count }, -> { Decidim::User.count }, -> { Decidim::Bih::Report.count }] do
      with_model do
        @client.queue_protected("read_own_information", { kind: "area" })
        current = chat("Da li sam izabrao svoj komšiluk?").fetch("reply")
        assert_includes current, "Izmišljeno polje"
        assert_includes current, Decidim::Bih.public_path("komsiluk")
        assert_not_includes current, I18n.t("decidim.bih.dialogue.account_observed", locale: :sr, url: Decidim::Bih.public_path("moj-nalog"))

        @client.queue_protected("account_action", { action: "change_area" })
        change = chat("Želim promijeniti moj komšiluk.").fetch("reply")
        assert_includes change, Decidim::Bih.public_path("komsiluk")
        assert_not_includes change, Decidim::Bih.public_path("moj-nalog")
        assert_not_includes change, I18n.t("decidim.bih.dialogue.account_observed", locale: :sr, url: Decidim::Bih.public_path("moj-nalog"))
        assert_not_includes change, I18n.t("decidim.bih.dialogue.resume_offer", locale: :sr)
      end
    end
    assert_equal original_profile, profile.reload.attributes
    assert_equal 2, @client.calls.length
  end

  test "invitation and komsiluk questions are answered from the citizen's own rows without composing private data or writing" do
    actor = FactoryBot.create(:user, :confirmed, organization: @organization)
    other = FactoryBot.create(:user, :confirmed, organization: @organization)
    Decidim::Bih::Goodwill::Reward.create!(
      organization: @organization, key: Decidim::Bih.launch_invitation_reward_key, title: { "sr" => "Pozivnica" },
      cost: 20, stock: 310, deducts_points: false, auto_issue_at_threshold: true, expires_at: @now + 7.days
    )
    invitation = create_invitation(actor, "MI-AAAAA-22222")
    create_invitation(other, "MI-BBBBB-33333")
    sign_in actor

    counters = [-> { Decidim::Bih::Goodwill::RewardFulfillment.count }, -> { Decidim::Bih::Goodwill::RewardFulfillmentEvent.count },
                -> { Decidim::Bih::Goodwill::Transaction.count }, -> { Decidim::Bih::CitizenProfile.count }]
    assert_no_difference counters do
      with_model do
        @client.queue_protected("read_own_information", { kind: "invitation" })
        reply = chat("Imam li pozivnicu za lansiranje?").fetch("reply")
        assert_includes reply, "MI-AAAAA-22222"
        assert_not_includes reply, "MI-BBBBB-33333"
        assert_includes reply, Decidim::Bih.public_path("zajednistvo")

        @client.queue_protected("read_own_information", { kind: "area" })

        komsiluk = chat("Koji je moj komšiluk?").fetch("reply")
        assert_includes komsiluk, I18n.t("decidim.bih.dialogue.handoff_choose_area", locale: :sr, url: Decidim::Bih.public_path("komsiluk"))
        assert_not_includes komsiluk, "MI-AAAAA-22222"
      end
    end
    assert_equal 2, @client.calls.size
    assert_equal "reserved", invitation.reload.status
    assert_nil invitation.attendance_confirmed_at
  end

  test "an anonymous visitor asking about the invitation is handed to sign-in with a fresh protected proposal" do
    with_model do
      @client.queue_protected("read_own_information", { kind: "invitation" })
      reply = chat("Jesam li pozvan na 17.9?").fetch("reply")
      assert_includes reply, I18n.t("decidim.bih.dialogue.handoff_sign_in", locale: :sr, url: "/users/sign_in")
      assert_not_includes reply, "MI-"
    end
    assert_equal 1, @client.calls.size
  end

  test "water place and tomorrow use real scoped reviewed events and retain source evidence" do
    create_water_event("Danas provjeren prekid", @now + 1.hour, @now + 2.hours, "today")
    create_water_event("Sutra provjeren prekid", @now + 25.hours, @now + 26.hours, "tomorrow")
    @client.queue_final(text: "U kojem naselju želiš provjeru vode?")
    queue_water("2040-09-16")
    queue_water("2040-09-17")
    with_model do
      assert_includes chat("Ima li najavljenog prekida vode?").fetch("reply"), "U kojem naselju"
      assert_includes chat("U Izmišljenom polju").fetch("reply"), "Danas provjeren prekid"
      tomorrow = chat("A sutra?").fetch("reply")
      assert_includes tomorrow, "Sutra provjeren prekid"
      assert_not_includes tomorrow, "Danas provjeren prekid"
      assert_includes JSON.generate(@client.calls.last[:contents]), "2040-09-17"
      assert_includes @client.calls[3][:system_instruction], "timezone: Europe/Sarajevo"
    end
    assert_equal 5, @client.calls.size
    assert_includes JSON.generate(@client.calls[3][:contents]), "Izmišljenom polju"
  end

  test "out of coverage model date is not rewritten or represented as a reviewed service result" do
    create_water_event("Danas provjeren prekid", @now + 1.hour, @now + 2.hours, "today")
    queue_water("2099-01-01")
    with_model do
      reply = chat("Provjeri vodu u Izmišljenom polju za 1.1.2099.").fetch("reply")
      assert_not_includes reply, "Danas provjeren prekid"
      assert_includes reply, "nemam dovoljno potvrđenih podataka"
    end
    assert_equal 2, @client.calls.size
    envelope = @client.calls.last[:contents].last.dig("parts", 0, "functionResponse", "response")
    assert_empty envelope.fetch("evidence")
  end

  test "current short citation handles deliver through HTTP while a prior turn handle cannot be reused" do
    create_water_event("Pregledan prekid vode", @now + 1.hour, @now + 2.hours, "current-citation")
    first_handle = nil
    @client.queue_public("read_service_events", { topic: "water", area_query: "Izmišljeno polje", date: "2040-09-16" }) do |envelope|
      record = envelope.fetch("evidence").first
      first_handle = record.fetch("id")
      assert_match(/\Ae[0-9a-f]{8}_\d+\z/, first_handle)
      assert_not record.has_key?("document_id")
      source_fact = record.fetch("facts").fetch("source_fact")
      assert_empty source_fact.keys & %w(id source_id document_id revision)
      assert_includes record.fetch("text"), "Pregledan prekid vode"
      assert_not source_fact.has_key?("text"), "duplicate nested text is omitted from the model projection"
      assert_equal record.fetch("source_url"), source_fact.fetch("source_url")
      record.fetch("text")
    end
    with_model do
      assert_includes chat("Ima li vode u Izmišljenom polju danas?").fetch("reply"), "Pregledan prekid vode"
      @client.queue_protected("read_service_events", { topic: "water", area_query: "Izmišljeno polje", date: "2040-09-16" })
      @client.responses << lambda { |contents:, **|
        fresh = contents.last["parts"].first["functionResponse"]["response"]["evidence"].first.fetch("id")
        assert_not_equal first_handle, fresh
        @client.final(text: "Stari dokaz je prihvaćen", kind: "answer", ids: [first_handle])
      }
      @client.responses << lambda { |tool_mode:, tools:, **|
        assert_equal "NONE", tool_mode
        assert_empty tools
        @client.final(text: "Stari dokaz je prihvaćen", kind: "answer", ids: [first_handle])
      }
      assert_not_includes chat("Provjeri još jednom isti prekid.").fetch("reply"), "Stari dokaz je prihvaćen"
    end
    assert_equal 5, @client.calls.size, "one bounded repair cannot make a prior-turn citation current"
  end

  test "native provider failures do not retry or replay stale evidence and valid followups recover" do
    create_water_event("Danas provjeren prekid", @now + 1.hour, @now + 2.hours, "today")
    create_water_event("Sutra provjeren prekid", @now + 25.hours, @now + 26.hours, "tomorrow")
    queue_water("2040-09-16")
    @client.responses << ->(**) { @client.final(text: "Fabricated", kind: "answer", ids: ["forged-record"]) }
    @client.responses << lambda { |tool_mode:, tools:, **|
      assert_equal "NONE", tool_mode
      assert_empty tools
      @client.final(text: "Fabricated repair", kind: "answer", ids: ["forged-record"])
    }
    queue_water("2040-09-17")
    @client.queue_error
    queue_water("2040-09-16")
    with_model do
      assert_includes chat("Ima li vode u Izmišljenom polju danas?").fetch("reply"), "Danas provjeren prekid"
      malformed = chat("A sutra?").fetch("reply")
      assert_not_includes malformed, "Fabricated"
      assert_not_includes malformed, "Danas provjeren prekid"
      assert_equal 4, @client.calls.size
      assert_includes chat("A sutra?").fetch("reply"), "Sutra provjeren prekid"
      failed = chat("A danas?").fetch("reply")
      assert_not_includes failed, "Sutra provjeren prekid"
      assert_not_includes failed, "Synthetic"
      assert_equal 7, @client.calls.size
      assert_includes chat("A danas?").fetch("reply"), "Danas provjeren prekid"
    end
    assert_equal 9, @client.calls.size
  end

  test "source and disagreement followups refresh public evidence without writing" do
    event = create_water_event("Provjeren prekid", @now + 1.hour, @now + 2.hours, "evidence")
    3.times { queue_water("2040-09-16") }
    assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::Bih::CitizenProfile.count }] do
      with_model do
        assert_includes chat("Ima li vode u Izmišljenom polju danas?").fetch("reply"), "Provjeren prekid"
        event.update!(title: "Ažuriran javni prekid")
        assert_includes chat("Odakle ti to?").fetch("reply"), "Ažuriran javni prekid"
        assert_includes chat("Nije tako kod mene.").fetch("reply"), "Ažuriran javni prekid"
      end
    end
    assert_equal 6, @client.calls.size
  end

  test "anonymous neighborhood read is access checked and lamp report retains chosen place" do
    @client.queue_protected("read_own_information", { kind: "neighborhood" })
    @client.queue_protected("read_own_information", { kind: "neighborhood" })
    @client.queue_protected("prepare_report", { description: "Pokvarena lampa", area_query: "Izmišljeno polje" })
    assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::Bih::CitizenProfile.count }, -> { Decidim::Bih::KomsilukPost.count }] do
      with_model do
        assert_includes chat("Želim vidjeti objave članova komšiluka").fetch("reply"), "Sam izbor mjesta ne dodjeljuje pristup"
        assert_includes chat("Objave članova u Izmišljenom polju").fetch("reply"), "Sam izbor mjesta ne dodjeljuje pristup"
        lamp = chat("Želim prijaviti pokvarenu lampu").fetch("reply")
        assert_includes lamp, "Ništa još nije poslano"
        assert_not_includes lamp, "U kojem naselju"
      end
    end
  end

  test "retrieved private board facts never enter a subsequent native model prompt" do
    actor = FactoryBot.create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
    profile.assign_komsiluk!(@area, source: "dropdown")
    title = "Privatni dogovor članova dvorišta"
    Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @area, category: "general", title:, body: "Privatni sadržaj table")
    sign_in actor
    @client.queue_protected("read_own_information", { kind: "neighborhood" })
    @client.queue_public("read_parking_tariffs", { zone: "white" })
    with_model do
      assert_includes chat("Šta ima na tabli u Izmišljenom polju?").fetch("reply"), title
      chat("A parking?")
    end
    prompt = JSON.generate(@client.calls.last.fetch(:contents))
    assert_not_includes prompt, title
    assert_not_includes prompt, "Privatni sadržaj table"
    assert_not_includes prompt, "komsiluk_post:"
  end

  test "revoked board assignment prevents retained evidence disclosure with a fresh protected proposal" do
    actor = FactoryBot.create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
    profile.assign_komsiluk!(@area, source: "dropdown")
    title = "Samo za članove"
    Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @area, category: "general", title:, body: "Privatno")
    sign_in actor
    @client.queue_protected("read_own_information", { kind: "neighborhood" })

    with_model do
      assert_includes chat("Šta ima na tabli u Izmišljenom polju?").fetch("reply"), title
      profile.destroy!
      assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::Bih::CitizenProfile.count }, -> { Decidim::Bih::KomsilukPost.count }] do
        @client.queue_protected("read_own_information", { kind: "neighborhood" })
        response = chat("Odakle ti to?").fetch("reply")

        assert_not_includes response, title
        assert_not_includes response, "Komšiluk board"
      end
    end
    assert_equal 2, @client.calls.size
  end

  test "assigned member reads their neighborhood board without a typed area" do
    actor = FactoryBot.create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
    profile.assign_komsiluk!(@area, source: "dropdown")
    title = "Dodijeljena ploča"
    Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @area, category: "general", title:, body: "Samo za članove")
    sign_in actor
    @client.queue_protected("read_own_information", { kind: "neighborhood" })

    with_model { assert_includes chat("Objave članova na tabli mog komšiluka").fetch("reply"), title }

    assert_equal 1, @client.calls.size
  end

  test "vague neighborhood activity stays public even when a native proposal requests member posts" do
    actor = FactoryBot.create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
    profile.assign_komsiluk!(@area, source: "dropdown")
    title = "Private title must not answer vague activity"
    Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @area, category: "general", title:, body: "Private member content")
    sign_in actor
    @client.queue_protected("read_own_information", { kind: "neighborhood" })

    with_model do
      reply = chat("Šta ima u mom komšiluku?").fetch("reply")
      assert_includes reply, "Pregled obuhvata samo dostupne javne aktivnosti"
      assert_not_includes reply, title
      assert_not_includes reply, "Private member content"
    end
    assert_equal 1, @client.calls.size
  end

  test "missing retained board post cannot be disclosed on an exact source followup" do
    actor = FactoryBot.create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
    profile.assign_komsiluk!(@area, source: "dropdown")
    title = "Obrisana ploča"
    post = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @area, category: "general", title:, body: "Nije više dostupno")
    sign_in actor
    @client.queue_protected("read_own_information", { kind: "neighborhood" })

    with_model do
      assert_includes chat("Šta ima na tabli u Izmišljenom polju?").fetch("reply"), title
      post.destroy!
      assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::Bih::CitizenProfile.count }, -> { Decidim::Bih::KomsilukPost.count }] do
        @client.queue_protected("read_own_information", { kind: "neighborhood" })
        reply = chat("Odakle ti to?").fetch("reply")

        assert_not_includes reply, title
        assert_not_includes reply, "Komšiluk board"
      end
    end
    assert_equal 2, @client.calls.size
  end

  test "board query failure on an exact followup does not disclose retained member evidence" do
    actor = FactoryBot.create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
    profile.assign_komsiluk!(@area, source: "dropdown")
    title = "Nedostupna ploča"
    post = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @area, category: "general", title:, body: "Privatni sadržaj")
    sign_in actor
    @client.queue_protected("read_own_information", { kind: "neighborhood" })
    source_failure = Class.new(StandardError)

    assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::Bih::CitizenProfile.count }, -> { Decidim::Bih::KomsilukPost.count }] do
      with_model do
        assert_includes chat("Šta ima na tabli u Izmišljenom polju?").fetch("reply"), title
        Decidim::Bih::KomsilukPost.stub(:where, ->(*) { raise source_failure, "fixture source unavailable" }) do
          @client.queue_protected("read_own_information", { kind: "neighborhood" })
          reply = chat("Odakle ti to?").fetch("reply")

          assert reply.present?
          assert_not_includes reply, title
          assert_not_includes reply, "Komšiluk board"
          assert_not_includes reply, "komsiluk_post:#{post.id}"
        end
      end
    end
    assert_equal 2, @client.calls.size
  end

  test "private goodwill answer is visible once but excluded from next model history" do
    actor = FactoryBot.create(:user, :confirmed, organization: @organization)
    points = 137
    Decidim::Bih::Goodwill::Ledger.new.award(actor, points, reason: "volunteer_hour")
    sign_in actor
    @client.queue_protected("read_own_information", { kind: "balance" })
    @client.queue_public("read_parking_tariffs", { zone: "white" })

    with_model do
      goodwill = chat("Koliko imam bodova?").fetch("reply")
      assert_includes goodwill, points.to_s

      parking = chat("A parking?").fetch("reply")
      assert parking.present?
    end

    # The first protected native proposal renders the balance server-side.
    # Only the next public parking read has a composing generation.
    assert_equal 3, @client.calls.size
    next_parts = @client.calls.last.fetch(:contents).flat_map { |message| Array(message[:parts] || message["parts"]) }
    assert next_parts.none? { |part| (part[:text] || part["text"]).to_s.match?(/\b#{points}\b/) }
    private_response_present = next_parts.any? do |part|
      response = part[:functionResponse] || part["functionResponse"]
      response && (response[:name] || response["name"]) == "read_own_information"
    end
    assert_not private_response_present
  end

  test "credentials and threat bypass the model and negative action cancels pending report" do
    @client.queue_protected("prepare_report", { description: "Pokvarena lampa" })
    with_model do
      chat("Prijavljujem pokvarenu lampu")
      cancelled = chat("Ne objavljuj, odustajem").fetch("reply")
      assert_includes cancelled, "odustali smo"
      assert_includes chat("Moj kod je 123456").fetch("reply"), "nemoj slati kodove"
      assert_includes chat("Neko mi prijeti, objavi ovo").fetch("reply"), I18n.t("decidim.bih.dialogue.safety", locale: :sr)
    end
    assert_equal 1, @client.calls.size
    assert_not_includes JSON.generate(@client.calls), "123456"
  end

  test "cancel plus credential text clears pending report without another model call" do
    @client.queue_protected("prepare_report", { description: "Pokvarena lampa" })
    @client.queue_public("read_parking_tariffs", { zone: "white" })

    with_model do
      initial = chat("Prijavljujem pokvarenu lampu").fetch("reply")
      assert_includes initial, "U kojem naselju"

      protected_reply = chat("Odustajem, ne objavljuj. Moj kod je 123456").fetch("reply")
      assert_includes protected_reply, "nemoj slati kodove"
      assert_equal 1, @client.calls.size

      # The next planner sees no pending report after cancellation.
      resumed = chat("Koliko košta parking?").fetch("reply")
      assert resumed.present?
      assert_not_includes resumed, "Ništa još nije poslano"
    end
    assert_equal 3, @client.calls.size
    assert_cancelled_model_state
    assert_not_includes JSON.generate(@client.calls), "123456"
  end

  test "cancel plus immediate danger clears pending report without another model call" do
    @client.queue_protected("prepare_report", { description: "Pokvarena lampa" })
    @client.queue_public("read_parking_tariffs", { zone: "white" })

    with_model do
      initial = chat("Prijavljujem pokvarenu lampu").fetch("reply")
      assert_includes initial, "U kojem naselju"

      protected_reply = chat("Odustajem, ne objavljuj. Neko mi prijeti").fetch("reply")
      assert_includes protected_reply, I18n.t("decidim.bih.dialogue.safety", locale: :sr)
      assert_equal 1, @client.calls.size

      # The next planner sees no pending report after cancellation.
      resumed = chat("Koliko košta parking?").fetch("reply")
      assert resumed.present?
      assert_not_includes resumed, "Ništa još nije poslano"
    end
    assert_equal 3, @client.calls.size
    assert_cancelled_model_state
  end

  test "native diagnostics are opt-in bounded metadata and never contain citizen text" do
    @client.queue_final(text: "Koji javni podatak želiš provjeriti?")
    quiet = capture_rails_log { with_model { chat("ima li vode") } }
    assert_nil(quiet.lines.find { |entry| entry.include?("[MilicaDiag]") })
    @client.queue_final(text: "Koji javni podatak želiš provjeriti?")
    log = with_diagnostics { capture_rails_log { with_model { chat("ima li vode") } } }
    lines = log.lines.select { |entry| entry.include?("[MilicaDiag]") }
    assert_equal 1, lines.size
    parsed = JSON.parse(lines.first.strip.sub(/\A.*\[MilicaDiag\] /, ""))
    assert_kind_of Integer, parsed.fetch("ms")
    assert_not_includes lines.first, "vode"
    assert_not_includes lines.first, "synthetic-native-signature"
    assert_operator lines.first.bytesize, :<, 1500
  end

  test "clarification and courtesy use native finals while a greeting stays local without action chips" do
    ["Nema otvorenog zadatka. Šta želiš provjeriti?", "Nema na čemu."].each { |text| @client.queue_final(text:) }
    with_model do
      assert_includes chat("nastavi").fetch("reply"), "Nema otvorenog"
      assert_includes chat("hvala ti puno").fetch("reply"), "Nema na čemu"
      greeting = chat("zdravo")
      assert_includes greeting.fetch("reply"), "Ćao"
      assert_empty greeting.fetch("quick_replies")
    end
    assert_equal 2, @client.calls.size
  end

  private

  def queue_water(date)
    @client.queue_public("read_service_events", { topic: "water", area_query: "Izmišljeno polje", date: }) do |envelope|
      envelope.fetch("evidence").map { |record| record.fetch("text") }.join("\n")
    end
  end

  def assert_cancelled_model_state
    prompt = @client.calls[-2].fetch(:system_instruction)
    assert_not_includes prompt, '"active_task":"report_problem"'
    assert_not_includes prompt, '"pending_slot":"area_query"'
  end

  def with_model
    Dialogue::AdmissionControl.stub(:new, @admission) do
      yield
    end
  end

  # The provider copy falls back to the context copy until the locale key
  # lands with the courtesy package; the assertion is on the key, not the text.
  def provider_unavailable_copy
    fallback = I18n.t("decidim.bih.dialogue.context_unavailable", locale: :sr, raise: true)
    I18n.t("decidim.bih.dialogue.provider_unavailable", locale: :sr, default: fallback)
  end

  def chat(message)
    post "/biceriseno/chat", params: { message: }.to_json, headers: XHR
    assert_response :ok
    response.parsed_body
  end

  def with_diagnostics
    previous = ENV.fetch("MILICA_DIAGNOSTIC", nil)
    ENV["MILICA_DIAGNOSTIC"] = "1"
    yield
  ensure
    previous.nil? ? ENV.delete("MILICA_DIAGNOSTIC") : ENV["MILICA_DIAGNOSTIC"] = previous
  end

  def capture_rails_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    if Rails.logger.respond_to?(:broadcast_to)
      Rails.logger.broadcast_to(logger)
      begin
        yield
      ensure
        Rails.logger.stop_broadcasting_to(logger)
      end
    else
      previous = Rails.logger
      Rails.logger = logger
      begin
        yield
      ensure
        Rails.logger = previous
      end
    end
    io.string
  end

  def reset_concierges
    DecidimApp::Bijeljina::WebConcierge.reset!
    DecidimApp::Bijeljina::Concierge.reset!
    Decidim::Bih::Config.reset!
  end

  def create_invitation(user, code)
    Decidim::Bih::Goodwill::RewardFulfillment.create!(
      organization: @organization, user:, ledger_transaction: nil, reward_key: Decidim::Bih.launch_invitation_reward_key,
      cost: 20, status: "reserved", auto_issued: true, entry_code: code, issued_at: @now, confirmation_deadline_at: @now + 72.hours
    )
  end

  def create_water_event(title, starts_at, ends_at, fingerprint)
    source = DecidimApp::Bijeljina::CityServiceSources.find("water_service")
    DecidimApp::Bijeljina::CityServiceEvent.create!(
      organization: @organization, source_key: "water_service", source_label: "Vodovod", source_fingerprint: fingerprint,
      source_url: source.fetch(:source_url), event_type: "planned_interruption", severity: "service_outage", targeting_level: "komsiluk",
      affected_area_slugs: [@area.slug], title:, summary: "Provjereno servisno obavještenje", starts_at:, ends_at:,
      fetched_at: @now - 60, state: "published", parser_version: "test"
    )
  end
end
