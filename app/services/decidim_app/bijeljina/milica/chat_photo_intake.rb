# frozen_string_literal: true

require "stringio"
require_relative "chat_photo_store"

module DecidimApp
  module Bijeljina
    module Milica
      # Photo intake for a report a citizen is filing from Viber, WhatsApp,
      # Messenger or Instagram.
      #
      # It is a standalone collaborator on purpose: the chat adapter owns the
      # conversation and the explicit confirmation, this owns the bytes. Nothing
      # here can create, confirm or alter a report — #attach only decorates a
      # report that some OTHER, confirmed path already created.
      #
      # The three moments:
      #
      #   offer   — a photo arrived with (or during) a draft. Fetch it, validate
      #             it, remember it for as long as the draft lives, and hand the
      #             adapter a sentence to send back. NEVER raises, never drops a
      #             photo silently: every refusal has its own honest sentence.
      #   pending?/disclosure_line/preview_line — what the preview needs in order
      #             to tell the citizen, before they confirm, that a photo is
      #             attached and who will see it.
      #   rebind  — a corrected preview mints a new draft id; carry the photo
      #             across so the citizen does not have to send it again. It
      #             does NOT buy the bytes more time.
      #   attach  — after the citizen confirmed and the report exists, put the
      #             bytes on the report the same way the web form does, then
      #             forget them.
      #
      # DRAFT BINDING. A photo is remembered against the draft id it was offered
      # for, and #attach refuses a photo bound to a DIFFERENT draft than the one
      # that was confirmed. The draft id is inside the confirmation digest
      # (Decidim::Bih::Concierge::ConfirmedReportSubmission), so "the citizen
      # confirmed a preview that disclosed this photo" is enforced, not assumed
      # — a photo that arrived after the preview cannot ride along on it. A
      # photo with no draft id yet (sent before any preview existed) is still
      # allowed: the confirmation the adapter requires is what gates it.
      #
      # Off by default: MI_CHAT_PHOTO_INTAKE_ENABLED must be 1/true/yes. With the
      # flag off nothing is fetched at all — not a single HTTP request — and the
      # citizen is told photos are not accepted on this channel yet.
      class ChatPhotoIntake
        ENABLED_ENV = "MI_CHAT_PHOTO_INTAKE_ENABLED"
        LOCALES = %w(sr sr-Cyrl bs hr en).freeze

        # status:
        #   :none      — no photo in this message; the adapter says nothing
        #   :disabled  — the feature flag is off; the adapter says so once
        #   :stored    — kept until confirmation; message carries the disclosure
        #   :too_large / :invalid_type / :fetch_failed / :expired — refusals
        Outcome = Data.define(:status, :message) do
          def stored? = status == :stored

          def refused? = [:too_large, :invalid_type, :fetch_failed, :expired].include?(status)

          def silent? = status == :none
        end

        # Maps a fetcher status onto the sentence the citizen gets. :failed
        # covers a refused URL and a transport error alike — from the citizen's
        # side both are "I could not download it", which is the truth.
        COPY_FOR = {
          too_large: :too_large,
          invalid_type: :invalid_type,
          expired: :expired,
          failed: :fetch_failed
        }.freeze

        class << self
          def enabled?
            ENV.fetch(ENABLED_ENV, "false").match?(/\A(?:1|true|yes)\z/i)
          end

          def offer(...) = new.offer(...)

          def pending?(...) = new.pending?(...)

          def attach(...) = new.attach(...)

          def discard(...) = new.discard(...)

          # The sentence the report preview includes so the citizen knows who
          # will see the photo BEFORE they confirm. Deliberately says what this
          # platform actually does: the photo is not published with the public
          # report, it goes to the operators and the responsible city service.
          def disclosure_line(locale: I18n.locale)
            translate("disclosure", locale:)
          end

          # One short line for the preview body ("Fotografija: priložena.").
          def preview_line(locale: I18n.locale)
            translate("preview_line", locale:)
          end

          def translate(key, locale:)
            normalized = LOCALES.include?(locale.to_s) ? locale.to_s : I18n.default_locale
            I18n.t("bijeljina.milica_chat_photo.#{key}", locale: normalized, raise: true)
          end
        end

        def initialize(store: ChatPhotoStore.new, fetcher: nil)
          @store = store
          @fetcher = fetcher
        end

        # image_url is the provider media reference from the inbound message
        # (Decidim::Bih::Infobip::InboundMessage#image_url); draft_id is the
        # pending draft's "id", when there already is one. Returns an Outcome.
        def offer(context:, image_url:, locale: I18n.locale, draft_id: nil)
          return outcome(:none) if image_url.to_s.strip.empty?
          return outcome(:disabled, locale:) unless self.class.enabled?

          result = fetcher.call(image_url)
          return outcome(:none) if result.status == :none
          return outcome(COPY_FOR.fetch(result.status, :fetch_failed), locale:) unless result.ok?

          stored = remember(context:, result:, draft_id:)
          return outcome(:fetch_failed, locale:) unless stored

          outcome(:stored, locale:, suffix: self.class.disclosure_line(locale:))
        rescue StandardError => e
          # A photo must never take the report down with it.
          Rails.logger.warn("[ChatPhotoIntake] offer failed (#{e.class})")
          outcome(:fetch_failed, locale:)
        end

        # True only for a photo this draft may actually use.
        def pending?(context:, draft_id: nil)
          envelope = store.read(context:)
          return false unless envelope

          usable?(envelope, draft_id)
        rescue StandardError
          false
        end

        # Carries a pending photo onto a freshly built draft.
        def rebind(context:, draft_id:)
          store.rebind(context:, draft_id:)
        rescue StandardError
          false
        end

        # Attaches the pending photo to an already-created, already-confirmed
        # report, exactly as the web form does (ActiveStorage has_one_attached
        # :photo, with Report#acceptable_photo as the server-side backstop), and
        # then forgets the bytes whatever happened. Returns true only when the
        # photo is really on the report.
        def attach(report:, context:, draft_id: nil)
          envelope = store.read(context:)
          return false unless envelope

          unless usable?(envelope, draft_id)
            # The photo belongs to a preview the citizen did not confirm. It is
            # dropped (the ensure below), never quietly attached to this one.
            Rails.logger.warn("[ChatPhotoIntake] pending photo belongs to another draft; not attaching")
            return false
          end

          report.photo.attach(
            io: StringIO.new(envelope.fetch("data")),
            filename: envelope["filename"].presence || "chat_photo.jpg",
            content_type: envelope.fetch("content_type")
          )
          # Read the model's verdict BEFORE reload, which clears the errors, and
          # only trust the reloaded record: "attached" must mean "on the report
          # in the database", not "assigned in memory".
          refused = report.errors.include?(:photo)
          report.reload
          attached = !refused && report.photo.attached?
          unless attached
            # Report#acceptable_photo had the last word (size/type). Drop the
            # photo AND its blob, and keep the report: the citizen already has
            # their reference number, and a report without a picture is still a
            # report.
            Rails.logger.warn("[ChatPhotoIntake] report #{report.id} refused the chat photo; filing without it")
            report.photo.purge if report.photo.attached?
          end
          attached
        rescue StandardError => e
          Rails.logger.warn("[ChatPhotoIntake] attach failed (#{e.class})")
          false
        ensure
          discard(context:)
        end

        def discard(context:)
          store.clear(context:)
        rescue StandardError
          false
        end

        private

        attr_reader :store

        def fetcher
          @fetcher ||= Decidim::Bih::Infobip::ChatMediaFetch.new
        end

        # A photo bound to a draft may only be used by that draft. A photo with
        # no binding yet predates any preview and stays usable.
        def usable?(envelope, draft_id)
          bound = envelope["draft_id"].to_s
          return true if bound.empty?

          bound == draft_id.to_s
        end

        def remember(context:, result:, draft_id: nil)
          attachable = result.attachable
          io = attachable.fetch(:io)
          io.rewind if io.respond_to?(:rewind)
          bytes = io.read.to_s
          io.rewind if io.respond_to?(:rewind)
          return false if bytes.empty?

          store.write(
            context:, bytes:, draft_id:,
            content_type: attachable.fetch(:content_type),
            filename: attachable[:filename],
            expires_at: draft_deadline(context)
          )
        rescue StandardError => e
          Rails.logger.warn("[ChatPhotoIntake] could not keep the photo (#{e.class})")
          false
        end

        # The photo can never outlive the draft it belongs to.
        def draft_deadline(context)
          context.now.to_f + ChatPhotoStore::TTL
        end

        def outcome(status, locale: nil, suffix: nil)
          return Outcome.new(status:, message: nil) if status == :none

          key = status == :stored ? "stored" : status.to_s
          text = self.class.translate(key, locale: locale || I18n.locale)
          text = "#{text}\n#{suffix}" if suffix.present?
          Outcome.new(status:, message: text)
        end
      end
    end
  end
end
