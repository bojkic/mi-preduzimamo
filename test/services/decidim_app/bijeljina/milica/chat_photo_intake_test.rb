# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      # A photo sent to Milica on Viber/WhatsApp/Messenger/Instagram is kept for
      # exactly as long as the report draft, attached only after the citizen
      # confirms, and refused with an honest sentence when it cannot be taken.
      class ChatPhotoIntakeTest < ActiveSupport::TestCase
        Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
        Fetch = Decidim::Bih::Infobip::ChatMediaFetch
        JPEG_PATH = Rails.root.join("test/fixtures/files/chat_photo.jpg")
        MEDIA_URL = "https://api.infobip.com/whatsapp/1/media/abc?token=SECRET"

        # Honours the TTL so "the bytes expire with the draft" can be asserted
        # rather than assumed.
        class RedisMemory
          attr_reader :writes

          def initialize(now: -> { Time.current })
            @data = {}
            @writes = []
            @now = now
          end

          # "ex" is Redis's own keyword for a TTL in seconds.
          def set(key, value, ex: nil) # rubocop:disable Naming/MethodParameterName
            @writes << { key:, ttl: ex, bytes: value.bytesize }
            @data[key] = { value:, expires_at: ex ? @now.call.to_f + ex : nil }
            "OK"
          end

          def get(key)
            entry = @data[key]
            return unless entry
            return @data.delete(key) && nil if entry[:expires_at] && entry[:expires_at] <= @now.call.to_f

            entry[:value]
          end

          def del(key) = @data.delete(key) ? 1 : 0

          def empty? = @data.empty?
        end

        # Counts calls so "the flag off means zero HTTP calls" is a real count.
        class RecordingFetcher
          attr_reader :calls

          def initialize(result)
            @result = result
            @calls = []
          end

          def call(url)
            @calls << url
            @result
          end
        end

        setup do
          @organization = create_organization
          @context = Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "c" * 64,
                                                   capabilities: ["report_guidance"], now: Time.now.utc)
          @redis = RedisMemory.new
          @store = ChatPhotoStore.new(redis: @redis)
        end

        test "a valid JPEG is kept for the draft and attached to the confirmed report" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          intake = ChatPhotoIntake.new(store: @store, fetcher: RecordingFetcher.new(ok_result))

          outcome = I18n.with_locale(:sr) { intake.offer(context: @context, image_url: MEDIA_URL) }

          assert outcome.stored?
          assert_includes outcome.message, I18n.t("bijeljina.milica_chat_photo.stored", locale: :sr)
          assert_includes outcome.message, ChatPhotoIntake.disclosure_line(locale: :sr)
          assert intake.pending?(context: @context)

          report = create_report

          assert intake.attach(report:, context: @context)
          report.reload

          assert report.photo.attached?
          assert_equal "image/jpeg", report.photo.blob.content_type
          assert_equal File.binread(JPEG_PATH).bytesize, report.photo.blob.byte_size
          assert_not intake.pending?(context: @context), "the bytes are forgotten once they are on the report"
        end

        test "an oversized photo is refused with the size sentence and nothing is kept" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          intake = ChatPhotoIntake.new(store: @store, fetcher: RecordingFetcher.new(refusal(:too_large)))

          outcome = I18n.with_locale(:sr) { intake.offer(context: @context, image_url: MEDIA_URL) }

          assert_equal :too_large, outcome.status
          assert outcome.refused?
          assert_equal I18n.t("bijeljina.milica_chat_photo.too_large", locale: :sr), outcome.message
          assert_not intake.pending?(context: @context)
          assert @redis.empty?
        end

        test "nine megabytes never reaches the store because the fetcher refuses it first" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          oversize = Fetch::Response.new(status: 200, headers: { "Content-Type" => "image/jpeg" },
                                         body: "\xFF".b * (9 * 1024 * 1024), truncated: false)
          transport = ->(**) { oversize }
          intake = ChatPhotoIntake.new(store: @store, fetcher: Fetch.new(transport:))

          outcome = I18n.with_locale(:sr) { intake.offer(context: @context, image_url: MEDIA_URL) }

          assert_equal :too_large, outcome.status
          assert_equal I18n.t("bijeljina.milica_chat_photo.too_large", locale: :sr), outcome.message
          assert @redis.empty?
        end

        test "a PDF is refused with the format sentence" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          pdf = Fetch::Response.new(status: 200, headers: { "Content-Type" => "application/pdf" },
                                    body: "%PDF-1.4 nothing to see", truncated: false)
          intake = ChatPhotoIntake.new(store: @store, fetcher: Fetch.new(transport: ->(**) { pdf }))

          outcome = I18n.with_locale(:sr) { intake.offer(context: @context, image_url: MEDIA_URL) }

          assert_equal :invalid_type, outcome.status
          assert_equal I18n.t("bijeljina.milica_chat_photo.invalid_type", locale: :sr), outcome.message
          assert @redis.empty?
        end

        test "a 404 from the provider is refused with the download sentence" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          missing = Fetch::Response.new(status: 404, headers: {}, body: "not found", truncated: false)
          intake = ChatPhotoIntake.new(store: @store, fetcher: Fetch.new(transport: ->(**) { missing }))

          outcome = I18n.with_locale(:sr) { intake.offer(context: @context, image_url: MEDIA_URL) }

          assert_equal :fetch_failed, outcome.status
          assert_equal I18n.t("bijeljina.milica_chat_photo.fetch_failed", locale: :sr), outcome.message
        end

        test "provider-expired media gets its own sentence" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          gone = Fetch::Response.new(status: 410, headers: {}, body: "", truncated: false)
          intake = ChatPhotoIntake.new(store: @store, fetcher: Fetch.new(transport: ->(**) { gone }))

          outcome = I18n.with_locale(:sr) { intake.offer(context: @context, image_url: MEDIA_URL) }

          assert_equal :expired, outcome.status
          assert_equal I18n.t("bijeljina.milica_chat_photo.expired", locale: :sr), outcome.message
        end

        test "with the flag off nothing is fetched and the citizen is told" do
          ENV.delete(ChatPhotoIntake::ENABLED_ENV)
          fetcher = RecordingFetcher.new(ok_result)
          intake = ChatPhotoIntake.new(store: @store, fetcher:)

          outcome = I18n.with_locale(:sr) { intake.offer(context: @context, image_url: MEDIA_URL) }

          assert_not ChatPhotoIntake.enabled?
          assert_equal :disabled, outcome.status
          assert_equal I18n.t("bijeljina.milica_chat_photo.disabled", locale: :sr), outcome.message
          assert_empty fetcher.calls, "the flag off means not one provider request"
          assert @redis.empty?
          assert_not intake.pending?(context: @context)
        end

        test "a message with no photo says nothing at all" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          fetcher = RecordingFetcher.new(ok_result)
          intake = ChatPhotoIntake.new(store: @store, fetcher:)

          outcome = intake.offer(context: @context, image_url: nil)

          assert outcome.silent?
          assert_nil outcome.message
          assert_empty fetcher.calls
        end

        test "pending bytes expire with the draft and are never attached afterwards" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          intake = ChatPhotoIntake.new(store: @store, fetcher: RecordingFetcher.new(ok_result))
          intake.offer(context: @context, image_url: MEDIA_URL)

          write = @redis.writes.last

          assert_operator write.fetch(:ttl), :<=, ReportConversationStore::TTL
          assert_equal ChatPhotoStore::TTL, ReportConversationStore::TTL,
                       "the photo may never outlive the draft it belongs to"

          travel_to Time.current + ChatPhotoStore::TTL.seconds + 1.second do
            expired_context = Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "c" * 64,
                                                            capabilities: ["report_guidance"], now: Time.now.utc)
            expired_store = ChatPhotoStore.new(redis: @redis)
            expired = ChatPhotoIntake.new(store: expired_store, fetcher: RecordingFetcher.new(ok_result))

            assert_not expired.pending?(context: expired_context)

            report = create_report

            assert_not expired.attach(report:, context: expired_context)
            assert_not report.reload.photo.attached?
          end
        end

        test "cancelling a draft discards the bytes" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          intake = ChatPhotoIntake.new(store: @store, fetcher: RecordingFetcher.new(ok_result))
          intake.offer(context: @context, image_url: MEDIA_URL)

          assert intake.pending?(context: @context)
          intake.discard(context: @context)

          assert_not intake.pending?(context: @context)
          assert @redis.empty?
        end

        test "neither the media URL nor a byte of the photo reaches the log" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          io = StringIO.new
          captured = ActiveSupport::Logger.new(io)

          Rails.stub(:logger, captured) do
            [Fetch::Response.new(status: 500, headers: {}, body: "boom", truncated: false),
             Fetch::Response.new(status: 200, headers: { "Content-Type" => "application/pdf" }, body: "%PDF-1.4", truncated: false),
             Fetch::Response.new(status: 200, headers: { "Content-Type" => "image/jpeg" }, body: File.binread(JPEG_PATH), truncated: false)].each do |stub|
              ChatPhotoIntake.new(store: @store, fetcher: Fetch.new(transport: ->(**) { stub }))
                             .offer(context: @context, image_url: MEDIA_URL)
            end
          end

          log = io.string

          assert_includes log, "ChatMediaFetch", "the refusals really were logged, so this assertion is not vacuous"
          assert_not_includes log, MEDIA_URL
          assert_not_includes log, "SECRET"
          assert_not_includes log, "api.infobip.com"
          assert_not_includes log, "%PDF"
          assert_not_includes log, File.binread(JPEG_PATH)[0, 32]
        end

        test "a photo the report model refuses is dropped and the report keeps its reference" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          # Real GIF bytes forced into the store prove Report#acceptable_photo is
          # still the last word at attach time. They must really be a GIF:
          # ActiveStorage identifies the blob from the bytes, so a mislabelled
          # JPEG would simply be corrected back to image/jpeg and accepted.
          gif = Base64.strict_decode64("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
          @store.write(context: @context, bytes: gif,
                       content_type: "image/gif", filename: "chat_photo.gif")
          intake = ChatPhotoIntake.new(store: @store, fetcher: RecordingFetcher.new(ok_result))
          report = create_report

          assert_not intake.attach(report:, context: @context)
          assert_not report.reload.photo.attached?
          assert report.reference.present?
          assert_not intake.pending?(context: @context)
        end

        test "a photo offered for one draft never rides along on another" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          intake = ChatPhotoIntake.new(store: @store, fetcher: RecordingFetcher.new(ok_result))
          intake.offer(context: @context, image_url: MEDIA_URL, draft_id: "a" * 48)

          assert intake.pending?(context: @context, draft_id: "a" * 48)
          assert_not intake.pending?(context: @context, draft_id: "b" * 48)

          report = create_report

          assert_not intake.attach(report:, context: @context, draft_id: "b" * 48)
          assert_not report.reload.photo.attached?
          assert_not intake.pending?(context: @context, draft_id: "a" * 48),
                     "a photo refused for the confirmed draft is dropped, not left waiting"
        end

        test "a corrected preview carries the photo onto the new draft without extending its life" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          intake = ChatPhotoIntake.new(store: @store, fetcher: RecordingFetcher.new(ok_result))
          intake.offer(context: @context, image_url: MEDIA_URL, draft_id: "a" * 48)
          first_deadline = @redis.writes.last.fetch(:ttl)

          assert intake.rebind(context: @context, draft_id: "c" * 48)
          assert intake.pending?(context: @context, draft_id: "c" * 48)
          assert_not intake.pending?(context: @context, draft_id: "a" * 48)
          assert_operator @redis.writes.last.fetch(:ttl), :<=, first_deadline

          report = create_report

          assert intake.attach(report:, context: @context, draft_id: "c" * 48)
          assert report.reload.photo.attached?
        end

        test "a photo that predates any preview is still attachable after confirmation" do
          ENV[ChatPhotoIntake::ENABLED_ENV] = "true"
          intake = ChatPhotoIntake.new(store: @store, fetcher: RecordingFetcher.new(ok_result))
          intake.offer(context: @context, image_url: MEDIA_URL)

          assert intake.pending?(context: @context, draft_id: "d" * 48)

          report = create_report

          assert intake.attach(report:, context: @context, draft_id: "d" * 48)
          assert report.reload.photo.attached?
        end

        test "the disclosure line exists in every enabled locale and never claims the photo is public" do
          ChatPhotoIntake::LOCALES.each do |locale|
            line = ChatPhotoIntake.disclosure_line(locale:)

            assert line.present?, locale
            assert_equal I18n.t("bijeljina.milica_chat_photo.disclosure", locale:), line
          end

          sr = ChatPhotoIntake.disclosure_line(locale: :sr)

          assert_includes sr, "nije javno objavljena"
          assert_includes sr, "nadležna gradska služba"
        end

        teardown do
          ENV.delete(ChatPhotoIntake::ENABLED_ENV)
        end

        private

        def ok_result
          Fetch::Result.new(status: :ok, content_type: "image/jpeg", byte_size: File.size(JPEG_PATH),
                            attachable: { io: StringIO.new(File.binread(JPEG_PATH)),
                                          filename: "chat_photo.jpg", content_type: "image/jpeg" })
        end

        def refusal(status)
          Fetch::Result.new(status:, attachable: nil, content_type: nil, byte_size: nil)
        end

        # Created directly, not through ReportIntake: this package owns the
        # attach, and the confirmation package owns how the report gets made.
        def create_report
          Decidim::Bih::Report.create!(
            organization: @organization, description: "Rupa na putu kod škole",
            address: "Karađorđeva 1", anonymous: true, status: "primljeno"
          )
        end
      end
    end
  end
end
