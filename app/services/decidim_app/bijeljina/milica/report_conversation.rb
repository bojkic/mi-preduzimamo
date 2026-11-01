# frozen_string_literal: true

require "securerandom"
require_relative "report_conversation_store"
require_relative "chat_photo_intake"

module DecidimApp
  module Bijeljina
    module Milica
      # The LLM can suggest a description/place, but cannot submit anything.
      # A scoped, expiring preview and an exact citizen command own that effect.
      class ReportConversation
        CONFIRMATION = /\A(?:posalji prijavu|submit report) ([a-f0-9]{12})\z/
        TYPED_CONFIRMATION = /\A(?:potvrdi prijavu(?: da)?|confirm report yes)\z/
        AGREEMENT = /\A(?:da|moze|u redu|potvrdi|potvrdujem|posalji|posalji prijavu|yes|confirm|submit|submit report)[.!]?\z/
        CANCEL_COMMAND = "odustani"
        UNSPECIFIED_PLACES = ["ovdje", "ovde", "tu", "here", "my location", "moja lokacija", "mojoj lokaciji",
                              "trenutna lokacija", "na ulici", "ulica", "u mom komsiluku", "moj komsiluk"].freeze

        # +typed_confirmation+ adapts the preview to a channel with no buttons
        # (Viber BM, WhatsApp, Messenger, Instagram): the citizen confirms by
        # replying with the exact short phrase the preview prints. The draft
        # remains sender-scoped and expiring; the same guarded submission owns
        # the write and receipt.
        def initialize(store: ReportConversationStore.new, submission: nil, state_store: nil, typed_confirmation: false)
          @store = store
          @submission = submission
          @state_store = state_store
          @typed_confirmation = typed_confirmation
        end

        # Keep immediate controls visibly before model work and draft creation.
        # The emergency answer comes FIRST, before the draft store is touched
        # at all: this boundary used to take the draft lease and only then ask
        # whether the citizen was in danger, so a busy or unavailable store
        # turned "gori mi kuća" into "pokušaj ponovo". Nothing about the draft
        # can be more urgent than that answer.
        def call(message:, context:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          emergency = emergency_turn(message.text.to_s, context:)
          return emergency if emergency

          @store.synchronize(context:) do |lease|
            pending = @store.read(context:)
            offer_photo(message:, context:, pending:)
            folded = Decidim::Bih::Text.fold(message.text.to_s)
            confirmation = CONFIRMATION.match(folded)
            return confirm(message:, context:, pending:, lease:, code: confirmation[1]) if confirmation

            if @typed_confirmation && TYPED_CONFIRMATION.match?(folded)
              return [reply(t("expired")), nil] unless pending

              return confirm(message:, context:, pending:, lease:, code: pending.fetch("code"))
            end
            return cached_receipt(pending) if pending&.fetch("reference", nil) && AGREEMENT.match?(folded)
            return [preview_reply(pending), nil] if pending && AGREEMENT.match?(folded)
            if pending && (courtesy = Decidim::Bih::Concierge::Dialogue::Courtesy.kind(message.text.to_s))
              # "Hvala" or a greeting after the preview is not a correction:
              # answer it and show the unexpired preview with its buttons again.
              return [courtesy_preview_reply(pending, courtesy), nil]
            end

            # Any correction, topic switch, cancellation or failed new turn
            # invalidates the previous button BEFORE further model work.
            @store.clear(context:, lease:) if pending
            reply, outcome = yield
            return [reply, outcome] unless report_ready?(outcome)

            described = danger_card(outcome.state.fetch("entities")["description"], locale: outcome.state.fetch("locale"))
            return safety_turn(described) if described

            draft = build_draft(outcome:, message:, context:)
            return [self.reply(t("ask_place", locale: outcome.state.fetch("locale"))), outcome] unless draft

            @store.write(context:, draft:, lease:)
            [preview_reply(draft), outcome]
          end
        rescue ReportConversationStore::Busy
          [reply(t("busy")), nil]
        rescue StandardError => e
          # A failure must never retry an effect via the legacy responder.
          Rails.logger.warn("[MilicaReportConversation] #{e.class.name}") if defined?(Rails) && Rails.respond_to?(:logger)
          [reply(t("unavailable")), nil]
        end

        private

        def report_ready?(outcome)
          outcome && outcome.respond_to?(:state) && outcome.state.is_a?(Hash) &&
            outcome.state["active_task"] == "report_problem" &&
            outcome.state["pending_slot"].nil? && outcome.resolution == "handoff" &&
            outcome.state["report_handoff_offered"] == true
        end

        def build_draft(outcome:, message:, context:)
          entities = outcome.state.fetch("entities")
          description = bounded_text(entities["description"], 1000)
          address = draft_address(entities, message)
          latitude, longitude = message_coordinates(message)
          # Editing a preview requires a newly confirmed place. In particular,
          # never resurrect saved GPS after a refusal, new report or correction.
          return unless description && (address || !latitude.nil?)

          draft = {
            "id" => SecureRandom.hex(24), "code" => SecureRandom.hex(6),
            "organization_id" => context.organization_id, "actor_id" => context.actor_id,
            "conversation_key" => context.conversation_key,
            "state_version" => outcome.state.fetch("version") + 1,
            "disclosure_version" => submission_class::DISCLOSURE_VERSION,
            "description" => description, "address" => address,
            "latitude" => latitude, "longitude" => longitude,
            "possible_duplicates" => outcome.respond_to?(:fact_ids) && outcome.fact_ids.any?,
            "locale" => outcome.state.fetch("locale"),
            "expires_at" => context.now.to_f + ReportConversationStore::TTL
          }
          # A photo that arrived before this preview belongs to the draft the
          # citizen is about to confirm, not to the turn it came in on.
          ChatPhotoIntake.new.rebind(context:, draft_id: draft.fetch("id"))
          draft
        end

        def draft_address(entities, message)
          address = %w(address street area_query).filter_map { |key| bounded_text(entities[key], 300) }.first
          address = nil if address && UNSPECIFIED_PLACES.include?(Decidim::Bih::Text.fold(address))
          preserve_named_street_number(address, message.text.to_s)
        end

        def message_coordinates(message)
          coordinates(message.respond_to?(:dialogue_location) ? message.dialogue_location : nil)
        end

        def consented_current_location?(location)
          (location["consent"] == true || location[:consent] == true) &&
            (location["purpose"] || location[:purpose]) == "current_location" &&
            %w(browser_geolocation legacy_explicit_location).include?(location["provenance"] || location[:provenance])
        end

        def coordinates(location)
          return [] unless location.respond_to?(:[])
          return [] unless consented_current_location?(location)

          latitude = Float(location["latitude"] || location[:latitude])
          longitude = Float(location["longitude"] || location[:longitude])
          return [] unless valid_coordinate_pair?(latitude, longitude)

          [latitude, longitude]
        rescue ArgumentError, TypeError
          []
        end

        def valid_coordinate_pair?(latitude, longitude)
          latitude.finite? && latitude.between?(-90, 90) && longitude.finite? && longitude.between?(-180, 180)
        end

        # Copy an explicit number beside the SAME accepted street when the
        # classifier shortened it. Never infer numbers from GPS, other streets,
        # a negated address or a turn containing competing numeric details.
        def preserve_named_street_number(address, text)
          return address unless address

          fold = Decidim::Bih::Text
          place = fold.fold(address).match(/\Aulic[aeiu] (.+)\z/)&.[](1)
          return address unless place && !place.match?(/\d/)

          current = fold.fold(text)
          return address unless unambiguous_street_number_text?(current)

          number = current.match(/\bulic[aeiu] #{Regexp.escape(place)}(?: kod)?(?: (?:broja|broj|br))? (\d{1,5}[a-z]?)\b/)&.[](1)
          number ? bounded_text("#{address} #{number}", 300) || address : address
        end

        def unambiguous_street_number_text?(current)
          current.scan(/\b\d+[a-z]?\b/).one? && !current.match?(/\b(?:ne|nije|nego|umjesto|not|instead)\b/)
        end

        def bounded_text(value, limit)
          return unless value.is_a?(String) && value.valid_encoding?

          text = value.strip.gsub(/[\r\n\t]+/, " ")
          return if text.empty? || text.length > limit || text.match?(/[\x00-\x1f]/)

          text
        end

        def confirm(message:, context:, pending:, lease:, code:)
          return [reply(t("expired")), nil] unless pending && pending["code"] == code
          return cached_receipt(pending) if pending["reference"]

          # A confirmation may not outlive a transition into danger: the draft
          # is destroyed here, before any submission, so no unreviewed report
          # can be sent by a later click on the same button.
          described = danger_card(pending["description"], locale: pending["locale"])
          if described
            @store.clear(context:, lease:)
            return safety_turn(described)
          end

          author = message.respond_to?(:user) ? message.user : nil
          confirmed_context = context.with(capabilities: (context.capabilities + ["write_report"]).uniq)
          unless pending["disclosure_version"] == submission_class::DISCLOSURE_VERSION
            # Lookup uses the ORIGINAL scope/code/fingerprint. A committed old
            # request can replay; an unsubmitted old button cannot create one.
            existing = submission.replay(context: confirmed_context, draft: pending, author:)
            return finish_receipt(existing, pending:, context:, lease:) if existing

            refreshed = pending.merge("code" => SecureRandom.hex(6), "disclosure_version" => submission_class::DISCLOSURE_VERSION)
            @store.write(context:, draft: refreshed, lease:)
            return [preview_reply(refreshed, disclosure_changed: true), nil]
          end

          report = submission.call(context: confirmed_context, draft: pending, author:)
          finish_receipt(report, pending:, context:, lease:)
        end

        def finish_receipt(report, pending:, context:, lease:)
          raise ArgumentError, "Typed report receipt required" unless report.is_a?(submission_class::Receipt) && [true, false].include?(report.replayed)

          reference = report.respond_to?(:reference) ? report.reference : nil
          raise ArgumentError, "Report receipt required" unless reference.is_a?(String) && reference.match?(/\A[A-Za-z0-9-]{1,64}\z/)

          # Retain only an opaque receipt so a repeated click returns the same
          # reference. The durable service also deduplicates after cache failure.
          ChatPhotoIntake.attach(report:, context:, draft_id: pending["id"]) if report.respond_to?(:record) || report.is_a?(submission_class::Receipt)
          receipt = pending.slice("code", "locale", "expires_at").merge("reference" => reference)
          @store.write(context:, draft: receipt, lease:)
          complete_report_task(context:, pending:)
          [receipt_reply(reference, pending["locale"]), report]
        end

        def cached_receipt(pending)
          receipt = submission_class::Receipt.new(reference: pending.fetch("reference"), replayed: true)
          [receipt_reply(receipt.reference, pending["locale"]), receipt]
        end

        # A photo arrives on its own inbound turn on a chat channel. Fetch it
        # once, bind it to the draft the citizen is about to confirm, and let
        # the refusal reason reach the citizen instead of disappearing.
        def offer_photo(message:, context:, pending:)
          image_url = message.respond_to?(:image_url) ? message.image_url : nil
          return if image_url.blank?

          ChatPhotoIntake.offer(context:, image_url:, locale: pending&.fetch("locale", nil) || I18n.locale,
                                draft_id: pending && pending["id"])
        end

        def with_photo_lines(answer, draft, locale:)
          return answer unless ChatPhotoIntake.pending?(context: photo_context(draft), draft_id: draft["id"])

          [answer, ChatPhotoIntake.preview_line(locale:), ChatPhotoIntake.disclosure_line(locale:)].join("\n")
        end

        def photo_context(draft)
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: draft.fetch("organization_id"), conversation_key: draft.fetch("conversation_key"),
            actor_id: draft["actor_id"], account_state: draft["actor_id"] ? "registered" : "anonymous",
            capabilities: %w(public_reads), now: Time.current
          )
        end

        def immediate_danger?(text)
          Decidim::Bih::Concierge::Responder.immediate_danger?(text.to_s)
        end

        # The whole emergency turn, in the order that matters: compose the card
        # for the service this danger needs, THEN destroy the draft, THEN try
        # to leave a bounded hint for the next turn. Every step after the first
        # is best-effort — none of them may delay or replace the answer.
        def emergency_turn(text, context:)
          assessment = signal.assess(text)
          return nil unless assessment || immediate_danger?(text)

          pending = readable_draft(context:)
          card = danger_card(text, locale: (pending.is_a?(Hash) ? pending["locale"] : nil) || I18n.locale, assessment:)
          return nil unless card

          # nil means the store answered "no draft". Anything else — a draft, or
          # a read that failed — means one may exist, so it is destroyed.
          discard_draft(context:) unless pending.nil?
          remember_safety_context(assessment, context:) if assessment
          safety_turn(card)
        end

        # The card for +text+, or nil when it reports no danger. A danger this
        # signal cannot type (a threat, an assault) keeps the all-services card
        # it has always had: there the police and the SOS line ARE the answer.
        def danger_card(text, locale:, assessment: :unread)
          value = text.to_s
          assessment = signal.assess(value) if assessment == :unread
          reply_locale = card_builder.locale_for(value, fallback: locale)
          return card_builder.call(assessment, locale: reply_locale) if assessment
          return card_builder.generic(locale: reply_locale) if immediate_danger?(value)

          nil
        end

        def safety_turn(text)
          response = safety_response(text)
          outcome = Decidim::Bih::Concierge::Dialogue::ProcedureRunner::Result.new(
            state: nil, reply: response, resolution: Decidim::Bih::Concierge::Dialogue::Resolution::SAFETY_GUIDANCE,
            fact_ids: [], handoff_offered: false, handoff_completed: false
          )
          [response, outcome]
        end

        def safety_response(text)
          Decidim::Bih::Concierge::Responder::Reply.new(
            text:, report: nil, quick_replies: [], answer_intent: "safety", tone: "core"
          )
        end

        # The draft as the store sees it: a Hash, nil for "there is none", or
        # :unknown when the store could not be read at all.
        def readable_draft(context:)
          @store.read(context:)
        rescue StandardError
          :unknown
        end

        # A draft the citizen can no longer see must not stay confirmable.
        def discard_draft(context:)
          @store.synchronize(context:) { |lease| @store.clear(context:, lease:) }
        rescue StandardError => e
          # The store being busy or down cannot hold up an emergency answer.
          # The preview stays confirmable only by its exact printed code, which
          # this turn has already replaced on the citizen's screen.
          Rails.logger.warn("[MilicaReportConversation] emergency draft retained: #{e.class.name}") if defined?(Rails) && Rails.respond_to?(:logger)
          nil
        end

        # The one bounded continuity hint: which danger, under which topic, for
        # at most ten minutes and three turns. Never text, never a location.
        def remember_safety_context(assessment, context:)
          state = state_store.read(context:)
          return unless state.is_a?(Hash) && state["topic"].is_a?(String)

          now = context.now.to_f
          key = Decidim::Bih::Concierge::Dialogue::StateStore::SAFETY_CONTEXT_KEY
          ttl = Decidim::Bih::Concierge::Dialogue::StateStore::SAFETY_CONTEXT_TTL
          state_store.write(
            context:, expected_version: state.fetch("version"),
            state: state.merge(
              "updated_at" => now, "expires_at" => now + Decidim::Bih::Concierge::Dialogue::Contracts::CONTEXT_TTL,
              key => { "kind" => assessment.kind, "topic" => state.fetch("topic"), "opened_at" => now,
                       "expires_at" => now + ttl, "turns" => 1 }
            )
          )
        rescue StandardError
          nil # Continuity is a convenience; the card is the answer.
        end

        def signal = Decidim::Bih::Concierge::EmergencySignal

        def card_builder = Decidim::Bih::Concierge::EmergencyCard

        def complete_report_task(context:, pending:)
          state = state_store.read(context:)
          return unless state && state["active_task"] == "report_problem" && state["version"] == pending["state_version"]

          finished = state_store.empty_state(context).merge(
            "version" => state.fetch("version"), "created_at" => state.fetch("created_at"),
            "locale" => state.fetch("locale"), "suspended_task" => state["suspended_task"]
          )
          # Another turn may complete after the lease expires. Never delete or
          # overwrite its semantic state; only close the previewed version.
          state_store.write(context:, state: finished, expected_version: state.fetch("version"))
        end

        def preview_reply(draft, disclosure_changed: false)
          return receipt_reply(draft.fetch("reference"), draft["locale"]) if draft["reference"]

          locale = draft.fetch("locale")
          place = draft["address"] || t("shared_location", locale:)
          location_note = "\n#{t("location_notice", locale:)}"
          account = t(draft["actor_id"] ? "account_notice" : "anonymous_notice", locale:)
          command = confirmation_command(draft, locale:)
          key = @typed_confirmation ? "preview_typed" : "preview"
          answer = t(key, locale:, description: draft.fetch("description"), place:, location_note:, account:, command:)
          answer = with_photo_lines(answer, draft, locale:)
          answer = "#{t("duplicate_notice", locale:)}\n\n#{answer}" if draft["possible_duplicates"]
          answer = "#{t("disclosure_changed", locale:)}\n\n#{answer}" if disclosure_changed
          reply(answer, quick_replies: confirmation_chips(command, locale:))
        end

        def confirmation_command(draft, locale:)
          return locale == "en" ? "Confirm report YES" : "Potvrdi prijavu DA" if @typed_confirmation

          "#{locale == "en" ? "Submit report" : "Pošalji prijavu"} #{draft.fetch("code")}"
        end

        # On a channel the chips are rendered as text, so their LABEL is what
        # the citizen reads and retypes: it must be the command itself, not a
        # button caption nobody can press.
        def confirmation_chips(command, locale:)
          if @typed_confirmation
            cancel = t("cancel_command", locale:)
            return [{ label: command, send: command }, { label: cancel, send: cancel }]
          end

          [{ label: t("confirm_button", locale:), send: command },
           { label: t("cancel_button", locale:), send: CANCEL_COMMAND }]
        end

        def courtesy_preview_reply(pending, kind)
          preview = preview_reply(pending)
          line = I18n.t("decidim.bih.dialogue.#{kind}", locale: pending.fetch("locale"), raise: true)
          preview.text = "#{line}\n\n#{preview.text}"
          preview
        end

        def receipt_reply(reference, locale)
          path = Decidim::Bih.public_path("prijave/#{reference}")
          reply(t("submitted", locale:, reference:, url: path),
                quick_replies: [{ label: t("status_button", locale:), url: path }])
        end

        def reply(text, quick_replies: [])
          Decidim::Bih::Concierge::Responder::Reply.new(
            text:, report: nil, quick_replies:, answer_intent: "report_guidance", tone: "core"
          )
        end

        def t(key, locale: I18n.locale, **values)
          I18n.t("bijeljina.milica_report.#{key}", locale:, **values, raise: true)
        end

        def submission
          @submission ||= submission_class.new
        end

        def submission_class = Decidim::Bih::Concierge::ConfirmedReportSubmission

        def state_store
          @state_store ||= Decidim::Bih::Concierge::Dialogue::StateStore.new
        end
      end
    end
  end
end
