# frozen_string_literal: true

require "test_helper"

module DecidimApp
  class DurableReceiptSchemaReadinessTest < ActiveSupport::TestCase
    Metadata = Struct.new(:name, :columns, :valid, :unique, keyword_init: true) do
      def valid? = valid != false
    end

    test "rejects the pre-outbox schema even when sender ordering is present" do
      result = DurableReceiptSchemaReadiness.call(
        delivery: fake_delivery(
          columns: %w(channel), constraints: [], dedupe_index: true,
          sender_index: true, effect_scrub_index: true
        )
      )

      assert_not result.ready?
      assert result.sender_order_index
      assert_equal %w(phase encrypted_effects effects_cursor effects_count next_effect_scrub_at), result.missing_columns
      assert_equal DurableReceiptSchemaReadiness::REQUIRED_CONSTRAINTS, result.missing_constraints
    end

    test "accepts the complete ordered durable-effects schema" do
      result = DurableReceiptSchemaReadiness.call(
        delivery: fake_delivery(
          columns: DurableReceiptSchemaReadiness::REQUIRED_COLUMNS,
          constraints: DurableReceiptSchemaReadiness::REQUIRED_CONSTRAINTS,
          dedupe_index: true,
          sender_index: true,
          effect_scrub_index: true
        )
      )

      assert result.ready?
      assert_empty result.missing_columns
      assert_empty result.missing_constraints
    end

    test "rejects an invalid concurrent sender-order index" do
      result = DurableReceiptSchemaReadiness.call(
        delivery: fake_delivery(
          columns: DurableReceiptSchemaReadiness::REQUIRED_COLUMNS,
          constraints: DurableReceiptSchemaReadiness::REQUIRED_CONSTRAINTS,
          dedupe_index: true,
          sender_index: :invalid,
          effect_scrub_index: true
        )
      )

      assert_not result.ready?
      assert_not result.sender_order_index
    end

    test "rejects a missing or invalid effect-scrub index" do
      [false, :invalid].each do |index_state|
        result = DurableReceiptSchemaReadiness.call(
          delivery: fake_delivery(
            columns: DurableReceiptSchemaReadiness::REQUIRED_COLUMNS,
            constraints: DurableReceiptSchemaReadiness::REQUIRED_CONSTRAINTS,
            dedupe_index: true,
            sender_index: true,
            effect_scrub_index: index_state
          )
        )

        assert_not result.ready?
        assert_not result.effect_scrub_index
      end
    end

    test "rejects a missing invalid or nonunique provider-message dedupe index" do
      [false, :invalid, :nonunique].each do |index_state|
        result = DurableReceiptSchemaReadiness.call(
          delivery: fake_delivery(
            columns: DurableReceiptSchemaReadiness::REQUIRED_COLUMNS,
            constraints: DurableReceiptSchemaReadiness::REQUIRED_CONSTRAINTS,
            dedupe_index: index_state,
            sender_index: true,
            effect_scrub_index: true
          )
        )

        assert_not result.ready?
        assert_not result.dedupe_index
      end
    end

    private

    def fake_delivery(columns:, constraints:, sender_index:, dedupe_index: false, effect_scrub_index: false)
      connection = Object.new
      connection.define_singleton_method(:data_source_exists?) { |_table| true }
      connection.define_singleton_method(:indexes) do |_table|
        indexes = []
        if dedupe_index
          indexes << Metadata.new(
            name: DurableReceiptSchemaReadiness::DEDUPE_INDEX,
            columns: DurableReceiptSchemaReadiness::DEDUPE_COLUMNS,
            valid: dedupe_index != :invalid,
            unique: dedupe_index != :nonunique
          )
        end
        if sender_index
          indexes << Metadata.new(
            name: DurableReceiptSchemaReadiness::SENDER_ORDER_INDEX,
            columns: DurableReceiptSchemaReadiness::SENDER_ORDER_COLUMNS,
            valid: sender_index != :invalid
          )
        end
        if effect_scrub_index
          indexes << Metadata.new(
            name: DurableReceiptSchemaReadiness::EFFECT_SCRUB_INDEX,
            columns: DurableReceiptSchemaReadiness::EFFECT_SCRUB_COLUMNS,
            valid: effect_scrub_index != :invalid
          )
        end
        indexes
      end
      connection.define_singleton_method(:check_constraints) do |_table|
        constraints.map { |name| Metadata.new(name:) }
      end

      Object.new.tap do |delivery|
        delivery.define_singleton_method(:connection) { connection }
        delivery.define_singleton_method(:table_name) { "decidim_bih_viber_inbound_deliveries" }
        delivery.define_singleton_method(:reset_column_information) { nil }
        delivery.define_singleton_method(:column_names) { columns }
      end
    end
  end
end
