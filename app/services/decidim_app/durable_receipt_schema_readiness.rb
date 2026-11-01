# frozen_string_literal: true

module DecidimApp
  # Read-only schema contract shared by the Viber and external-chat launch
  # smokes. Keeping the check in one pure object lets tests prove that an older
  # receipt table cannot pass merely because the sender-order index exists.
  class DurableReceiptSchemaReadiness
    REQUIRED_COLUMNS = %w(
      channel phase encrypted_effects effects_cursor effects_count next_effect_scrub_at
    ).freeze
    REQUIRED_CONSTRAINTS = %w(chk_bih_inbound_delivery_phase chk_bih_inbound_effect_cursor).freeze
    DEDUPE_INDEX = "idx_bih_viber_inbound_org_message"
    DEDUPE_COLUMNS = %w(decidim_organization_id channel provider_message_key).freeze
    SENDER_ORDER_INDEX = "idx_bih_inbound_sender_order"
    SENDER_ORDER_COLUMNS = %w(decidim_organization_id channel sender_digest received_at id).freeze
    EFFECT_SCRUB_INDEX = "idx_bih_inbound_effect_scrub"
    EFFECT_SCRUB_COLUMNS = %w(phase next_effect_scrub_at).freeze

    Result = Struct.new(
      :table_exists,
      :dedupe_index,
      :sender_order_index,
      :effect_scrub_index,
      :missing_columns,
      :missing_constraints,
      keyword_init: true
    ) do
      def ready?
        table_exists && dedupe_index && sender_order_index && effect_scrub_index &&
          missing_columns.empty? && missing_constraints.empty?
      end
    end

    def self.call(delivery: Decidim::Bih::Viber::InboundDelivery)
      connection = delivery.connection
      return missing_table_result unless connection.data_source_exists?(delivery.table_name)

      delivery.reset_column_information
      indexes = connection.indexes(delivery.table_name)
      dedupe_ready = valid_index?(indexes, DEDUPE_INDEX, DEDUPE_COLUMNS, unique: true)
      index_ready = valid_index?(indexes, SENDER_ORDER_INDEX, SENDER_ORDER_COLUMNS)
      effect_scrub_ready = valid_index?(indexes, EFFECT_SCRUB_INDEX, EFFECT_SCRUB_COLUMNS)
      constraint_names = connection.check_constraints(delivery.table_name).map(&:name)

      Result.new(
        table_exists: true,
        dedupe_index: dedupe_ready,
        sender_order_index: index_ready,
        effect_scrub_index: effect_scrub_ready,
        missing_columns: REQUIRED_COLUMNS - delivery.column_names,
        missing_constraints: REQUIRED_CONSTRAINTS - constraint_names
      )
    end

    def self.missing_table_result
      Result.new(
        table_exists: false,
        dedupe_index: false,
        sender_order_index: false,
        effect_scrub_index: false,
        missing_columns: REQUIRED_COLUMNS,
        missing_constraints: REQUIRED_CONSTRAINTS
      )
    end
    private_class_method :missing_table_result

    def self.valid_index?(indexes, name, columns, unique: nil)
      indexes.any? do |index|
        matches = index.name == name && index.columns == columns && index.respond_to?(:valid?) && index.valid?
        matches &&= index.unique == unique unless unique.nil?
        matches
      end
    end
    private_class_method :valid_index?
  end
end
