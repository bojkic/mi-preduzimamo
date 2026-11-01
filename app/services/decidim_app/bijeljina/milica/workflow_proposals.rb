# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Typed model proposals terminate public generation before this boundary.
      # Existing protected state reducers may prepare a preview or handoff; only
      # ReportConversation can consume an exact confirmation and submit a report.
      class WorkflowProposals
        Dialogue = Decidim::Bih::Concierge::Dialogue
        ACCOUNT_ACTIONS = %w(registration sign_in link_account verification choose_area change_area preferences).freeze
        PRIVATE_KINDS = (PrivateAccountRead::KINDS + %w(report_status neighborhood)).freeze

        def self.declarations
          string = ->(description, max = 160) { { "type" => "string", "description" => description, "maxLength" => max } }
          [
            { "name" => "prepare_report", "description" => "Prepare or correct a citizen problem-report draft. This does not submit. Use for an actual request to report a " \
                                                           "problem; use read_platform_guidance subject reports for general report rules. Preserve supplied details across clarifications.",
              "parameters" => { "type" => "object", "properties" => {
                "description" => string.call("Citizen's problem description; do not invent details.", 1000),
                "address" => string.call("Address explicitly supplied by citizen."), "area_query" => string.call("Named area supplied by citizen."),
                "category" => string.call("Problem category.", 80)
              }, "additionalProperties" => false } },
            { "name" => "account_action", "description" => "Offer the existing authorized account/registration/verification/preferences/area handoff. Does not register, sign " \
                                                           "in, verify, change membership or authorize a user. Use only for a requested account action, not public information " \
                                                           "or transport.",
              "parameters" => { "type" => "object", "properties" => {
                "action" => { "type" => "string", "enum" => ACCOUNT_ACTIONS, "maxLength" => 40 }
              }, "required" => ["action"], "additionalProperties" => false } },
            { "name" => "read_own_information",
              "description" => "Read only the signed-in citizen's own balance, invitation, area, verification, referrals, identity, reward " \
                               "affordability, report status or private neighborhood. Server verifies identity. Result is presented privately, never " \
                               "returned to the public model. Choose identity only when asked about account identity; shared GPS or a public service in my area is not an identity lookup. General public rules use public tools.",
              "parameters" => { "type" => "object", "properties" => {
                "kind" => { "type" => "string", "enum" => PRIVATE_KINDS, "maxLength" => 40 },
                "reference" => string.call("Report reference supplied by citizen.", 160),
                "reward_key" => string.call("Known catalog reward key, only for affordability.", 100),
                "area_query" => string.call("Explicit named neighborhood.")
              }, "required" => ["kind"], "additionalProperties" => false } },
            { "name" => "neighborhood_action",
              "description" => "Offer the existing moderated neighborhood posting or area-choice workflow. No post is created in chat and no area " \
                               "assignment occurs automatically.",
              "parameters" => { "type" => "object", "properties" => {
                "action" => { "type" => "string", "enum" => %w(neighborhood_post choose_area), "maxLength" => 40 },
                "area_query" => string.call("Named area supplied by citizen.")
              }, "required" => ["action"], "additionalProperties" => false } }
          ]
        end

        def initialize(organization:, procedures: nil, private_reader: nil)
          @organization = organization
          @private_reader = private_reader || PrivateAccountRead.new(organization:)
          @procedures = procedures || Dialogue::ProcedureRunner.new(
            read_port: ReadPort.new(organization:), registration_port: RegistrationPort.new(organization:),
            destinations: { "report" => routes.new_report_path, "account" => routes.account_overview_path,
                            "neighborhood" => routes.komsiluk_board_index_path, "support" => Decidim::Bih.public_path("vodic") },
            capabilities: CityServiceCapabilities
          )
        end

        def call(request:, message:, state:, context:, locale: "sr")
          validate_context!(context, locale)
          name, args = validated_request(request)
          case name
          when "prepare_report"
            raise Dialogue::Contracts::Invalid, "Report guidance denied" unless context.allows?("report_guidance")

            procedure(action: "report_problem", topic: "report", entities: args, message:, state:, context:, locale:)
          when "account_action"
            action = args.fetch("action")
            raise Dialogue::Contracts::Invalid, "Account handoff denied" unless context.allows?("registration_handoff")
            return connection_guidance(state:, locale:) if action == "link_account"

            procedure(action:, topic: "account", entities: {}, message:, state:, context:, locale:)
          when "neighborhood_action"
            action = args.fetch("action")
            procedure(action:, topic: "neighborhood", entities: args.slice("area_query"), message:, state:, context:, locale:)
          when "read_own_information"
            private_information(args:, message:, state:, context:, locale:)
          else
            raise Dialogue::Contracts::Invalid, "Unknown protected proposal"
          end
        end

        def cancel(message:, state:, context:, locale:)
          validate_context!(context, locale)
          procedure(action: "cancel", topic: state.fetch("topic"), entities: {}, message:, state:, context:, locale:)
        end

        private

        def routes = Decidim::Bih::Engine.routes.url_helpers

        def validate_context!(context, locale)
          unless context.is_a?(Dialogue::Contracts::TrustedContext) && context.organization_id == @organization.id
            raise Dialogue::Contracts::Invalid,
                  "Trusted workflow scope required"
          end
          raise Dialogue::Contracts::Invalid, "Workflow deadline required" unless context.deadline && !context.deadline.expired?

          Dialogue::Contracts.enum!(locale, Dialogue::Contracts::LOCALES)
        end

        # Validate again at the protected boundary, even if a model adapter
        # previously checked its JSON. No model-supplied actor or effect flags.
        def validated_request(request)
          data = Dialogue::Contracts.object!(request, %w(name arguments))
          definition = self.class.declarations.find { |item| item.fetch("name") == data["name"] }
          raise Dialogue::Contracts::Invalid, "Unknown protected proposal" unless definition

          schema = definition.fetch("parameters")
          properties = schema.fetch("properties")
          args = Dialogue::Contracts.object!(data["arguments"], properties.keys)
          raise Dialogue::Contracts::Invalid, "Missing protected argument" unless (schema.fetch("required", []) - args.keys).empty?

          args.each do |key, value|
            field = properties.fetch(key)
            if field.has_key?("enum")
              Dialogue::Contracts.enum!(value, field.fetch("enum"))
            else
              Dialogue::Contracts.text!(value, limit: field.fetch("maxLength"))
            end
          end
          [data.fetch("name"), args]
        end

        def connection_guidance(state:, locale:)
          text = I18n.t("decidim.bih.dialogue.handoff_next_step", locale:, url: routes.channel_connections_path)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text:, report: nil, answer_intent: "setup", tone: "core", locale:)
          candidate = state.merge("active_task" => "link_account", "topic" => "account", "locale" => locale,
                                  "pending_slot" => nil, "entities" => {}, "entity_provenance" => {},
                                  "prior_evidence" => nil, "report_handoff_offered" => false)
          Dialogue::ProcedureRunner::Result.new(state: candidate, reply:, resolution: "handoff", fact_ids: [],
                                                handoff_offered: true, handoff_completed: false)
        end

        def procedure(action:, topic:, entities:, **turn)
          state = turn.fetch(:state)
          locale = turn.fetch(:locale)
          # No ordinary information request is permitted through the retained
          # workflow reducer. This seam neither classifies nor calls a model.
          allowed = ACCOUNT_ACTIONS + %w(report_problem report_status neighborhood_information neighborhood_post cancel)
          raise Dialogue::Contracts::Invalid, "Ordinary routing forbidden in protected workflow" unless allowed.include?(action)

          input = Dialogue::Contracts::Understanding.parse(
            action:, topic:, entities:, operation: state["active_task"] == action ? "continue" : "start",
            needs_clarification: false, secondary: nil, locale:
          )
          @procedures.call(understanding: input, state:, context: turn.fetch(:context), message: turn.fetch(:message))
        end

        def private_information(args:, message:, state:, context:, locale:)
          kind = args.fetch("kind")
          if kind == "report_status"
            return procedure(action: "report_status", topic: "report", entities: args.slice("reference").merge("query" => message.text.to_s[0, 160]), message:, state:, context:,
                             locale:)
          end
          if kind == "neighborhood"
            return procedure(action: "neighborhood_information", topic: "neighborhood", entities: args.slice("area_query"), message:, state:, context:, locale:)
          end

          value = @private_reader.call(kind:, context:, locale:, reward_key: args["reward_key"])
          resolution = { "ok" => "answered", "not_authorized" => "handoff", "unavailable" => "source_unavailable" }.fetch(value.status)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: value.text, report: nil, answer_intent: "goodwill", tone: "core", locale:)
          candidate = state.merge("active_task" => nil, "topic" => "goodwill", "pending_slot" => nil,
                                  "entities" => {}, "entity_provenance" => {}, "locale" => locale,
                                  "prior_evidence" => nil, "report_handoff_offered" => false)
          Dialogue::ProcedureRunner::Result.new(state: candidate, reply:, resolution:, fact_ids: [],
                                                handoff_offered: value.status == "not_authorized", handoff_completed: false)
        end
      end
    end
  end
end
