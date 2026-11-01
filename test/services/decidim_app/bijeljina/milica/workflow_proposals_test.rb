# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class WorkflowProposalsTest < ActiveSupport::TestCase
        Dialogue = Decidim::Bih::Concierge::Dialogue
        Message = Data.define(:text)

        setup do
          @organization = create_organization
          @calls = []
          @procedures = lambda { |**args|
            @calls << args
            :protected_result
          }
          @workflow = WorkflowProposals.new(organization: @organization, procedures: @procedures)
          @state = { "active_task" => nil, "topic" => "unknown", "entities" => {}, "entity_provenance" => {} }
          @message = Message.new("Synthetic request")
        end

        test "protected declarations satisfy the actual tool registry schema" do
          definitions = WorkflowProposals.declarations.map { |item| item.merge("handler" => ->(**) { flunk "Validation must not execute" }) }
          registry = Dialogue::ReadToolRegistry.new(definitions:)
          assert_equal WorkflowProposals.declarations, registry.declarations
          assert_equal({ "action" => "verification" }, registry.validate_call!(name: "account_action", arguments: { "action" => "verification" }))
          assert_raises(Dialogue::Contracts::Invalid) { registry.validate_call!(name: "account_action", arguments: { "action" => "erase" }) }
        end

        test "allows all existing handoffs and never upgrades them to effects" do
          (WorkflowProposals::ACCOUNT_ACTIONS - ["link_account"]).each do |action|
            assert_equal :protected_result, call("account_action", { "action" => action })
            assert_equal action, @calls.last.fetch(:understanding).action
            assert_empty @calls.last.fetch(:understanding).entities
          end
          %w(neighborhood_post choose_area).each do |action|
            call("neighborhood_action", { "action" => action, "area_query" => "Janja" })
            assert_equal action, @calls.last.fetch(:understanding).action
            assert_equal "Janja", @calls.last.fetch(:understanding).entities.fetch("area_query")
          end
        end

        test "web connection proposal offers authenticated page and never claims linked" do
          result = call("account_action", { "action" => "link_account" })
          assert_equal "handoff", result.resolution
          assert result.handoff_offered
          assert_not result.handoff_completed
          assert_includes result.reply.text, Decidim::Bih::Engine.routes.url_helpers.channel_connections_path
          assert_empty @calls
        end

        test "rejects actor injection unknown actions and malformed or unbounded arguments" do
          bad = [
            ["account_action", { "action" => "delete_account" }],
            ["account_action", { "action" => "sign_in", "actor_id" => 99 }],
            ["prepare_report", { "description" => "x" * 1001 }],
            ["prepare_report", { "address" => "x" * 161 }],
            ["prepare_report", { "submit" => true }],
            ["read_own_information", { "kind" => "all_reports" }],
            ["read_own_information", { "kind" => "balance", "actor_id" => 99 }],
            ["neighborhood_action", { "action" => "publish" }],
            ["account_action", {}], ["ordinary_read", {}], ["prepare_report", nil]
          ]
          bad.each do |name, args|
            assert_raises(Dialogue::Contracts::Invalid) { call(name, args) }
          end
          assert_empty @calls
        end

        test "call and cancel reject foreign tenant expired deadline and missing permission" do
          [context(organization_id: @organization.id + 1), context(deadline: expired_budget)].each do |scope|
            assert_raises(Dialogue::Contracts::Invalid) { call("prepare_report", {}, context: scope) }
            assert_raises(Dialogue::Contracts::Invalid) { @workflow.cancel(message: @message, state: @state, context: scope, locale: "sr") }
          end
          assert_raises(Dialogue::Contracts::Invalid) { call("account_action", { "action" => "sign_in" }, context: context(capabilities: [])) }
          assert_raises(Dialogue::Contracts::Invalid) { call("prepare_report", {}, context: context(capabilities: [])) }
          assert_empty @calls
        end

        test "report preview and private report read use distinct protected actions" do
          call("prepare_report", { "description" => "Slomljena klupa", "address" => "Synthetic street" })
          assert_equal "report_problem", @calls.last.fetch(:understanding).action
          assert_equal "Slomljena klupa", @calls.last.fetch(:understanding).entities.fetch("description")
          call("read_own_information", { "kind" => "report_status", "reference" => "SYN-123" })
          assert_equal "report_status", @calls.last.fetch(:understanding).action
          assert_equal "SYN-123", @calls.last.fetch(:understanding).entities.fetch("reference")
        end

        test "unavailable private read is not answered or a completed handoff" do
          reader = ->(**_args) { PrivateAccountRead::Result.new(status: "unavailable", text: "Unavailable") }
          @workflow = WorkflowProposals.new(organization: @organization, procedures: @procedures, private_reader: reader)
          result = call("read_own_information", { "kind" => "affordability", "reward_key" => "missing" })
          assert_equal "source_unavailable", result.resolution
          assert_not result.handoff_offered
          assert_not result.handoff_completed
        end

        test "private presentation is absent from persisted state and model evidence" do
          secret = "Private synthetic balance 83721"
          reader = ->(**_args) { PrivateAccountRead::Result.new(status: "ok", text: secret) }
          @workflow = WorkflowProposals.new(organization: @organization, procedures: @procedures, private_reader: reader)
          result = call("read_own_information", { "kind" => "balance" })
          assert_equal secret, result.reply.text
          assert_not_includes JSON.generate(result.state), secret
          assert_empty result.fact_ids
          assert_nil result.state["prior_evidence"]
          assert_empty @calls
        end

        private

        def expired_budget
          clock = 0
          budget = Dialogue::TurnBudget.new(timeout: 1, clock: -> { clock })
          clock = 2
          budget
        end

        def call(name, args, context: self.context)
          @workflow.call(request: { "name" => name, "arguments" => args }, message: @message, state: @state, context:)
        end

        def context(organization_id: @organization.id, deadline: Dialogue::TurnBudget.new(timeout: 5), capabilities: %w(registration_handoff report_guidance public_reads))
          Dialogue::Contracts::TrustedContext.new(organization_id:, conversation_key: "b" * 64, deadline:, capabilities:)
        end
      end
    end
  end
end
