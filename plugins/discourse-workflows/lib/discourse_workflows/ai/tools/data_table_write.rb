# frozen_string_literal: true

module DiscourseWorkflows
  module Ai
    module Tools
      class DataTableWrite < DataTableBase
        OPERATIONS = %w[insert update upsert delete].freeze
        MUTATIONS = {
          "update" => :update_rows,
          "upsert" => :upsert_row,
          "delete" => :delete_rows,
        }.freeze

        def self.signature
          {
            name: name,
            description:
              "Inserts, updates, upserts or deletes rows in a workflow data table. upsert inserts one row when the filter matches nothing. count is the number of affected rows; rows holds at most #{DiscourseWorkflows::Pagination::MAX_LIMIT} of them.",
            json_schema: {
              type: "object",
              additionalProperties: false,
              required: %w[table operation],
              properties: {
                table: TABLE_SCHEMA,
                operation: {
                  type: "string",
                  enum: OPERATIONS,
                },
                data: {
                  type: "object",
                  description: "Column name to value pairs to write",
                  additionalProperties: true,
                },
                filter: FILTER_SCHEMA,
              },
            },
          }
        end

        def self.name
          "data_table_write"
        end

        def self.requires_approval?
          true
        end

        def self.attribute_to_approver?
          true
        end

        def validation_error
          with_data_table do |data_table|
            if OPERATIONS.exclude?(operation)
              next error_response("Unsupported operation '#{operation}'")
            end
            next error_response("data is required") if data.blank? && operation != "delete"

            mutate(data_table, dry_run: true, take: 1) if MUTATIONS.key?(operation)
            nil
          end
        end

        def invoke
          validation_error ||
            with_data_table do |data_table|
              result =
                if operation == "insert"
                  { data: node_proxy(data_table).insert_rows([data], "all"), count: 1 }
                else
                  mutate(data_table, take: DiscourseWorkflows::Pagination::MAX_LIMIT)
                end

              {
                status: "success",
                table: data_table.name,
                operation:,
                count: result[:count],
                rows: json_safe(result[:data]),
              }
            end
        end

        private

        def mutate(data_table, **options)
          node_proxy(data_table).public_send(
            MUTATIONS.fetch(operation),
            { filter: parameters[:filter], data: }.merge(options),
          )
        end

        def operation
          parameters[:operation].to_s
        end

        def data
          parameters[:data]
        end
      end
    end
  end
end
