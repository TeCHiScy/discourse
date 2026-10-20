# frozen_string_literal: true

module DiscuzCategoryEligibility
  MAX_CATEGORY_NESTING = 3
  IMPORTABLE_STATUSES = [0, 1].freeze

  def self.ensure_site_nesting!
    SiteSetting.max_category_nesting = MAX_CATEGORY_NESTING
    return if SiteSetting.max_category_nesting.to_i == MAX_CATEGORY_NESTING

    raise "Discuz import requires max_category_nesting=#{MAX_CATEGORY_NESTING}"
  end

  def self.importable?(row)
    IMPORTABLE_STATUSES.include?(row["status"].to_s.to_i)
  end

  def self.sql_condition(table_alias = nil)
    status_column = table_alias ? "#{table_alias}.status" : "status"
    "#{status_column} IN (0, 1)"
  end

  def self.effective_parent_ids(rows, max_nesting:)
    rows_by_id = {}
    rows.each { |row| rows_by_id[row["id"].to_i] = row }
    eligible_ids = {}
    rows.each { |row| eligible_ids[row["id"].to_i] = true if importable?(row) }
    parent_ids = {}
    depths = {}

    eligible_rows = rows.select { |row| eligible_ids.key?(row["id"].to_i) }
    eligible_rows
      .sort_by { |row| [source_depth(row, rows_by_id), row["id"].to_i] }
      .each do |row|
        source_id = row["id"].to_i
        source_parent_id = row["parent_id"].to_i
        effective_parent_id = nil

        if eligible_ids.key?(source_parent_id)
          if depths.fetch(source_parent_id) + 1 >= max_nesting
            effective_parent_id = parent_ids.fetch(source_parent_id)
          else
            effective_parent_id = source_parent_id
          end
        end

        parent_ids[source_id] = effective_parent_id
        depths[source_id] = effective_parent_id ? depths.fetch(effective_parent_id) + 1 : 0
      end

    parent_ids
  end

  def self.display_names(rows, effective_parent_ids:, reserved_root_names:)
    eligible = rows.select { |row| importable?(row) }
    grouped =
      eligible.group_by do |row|
        source_name = row["name"].to_s.strip
        source_name = "Blank" if source_name.empty?
        [effective_parent_ids[row["id"].to_i], source_name[0..49].downcase]
      end

    grouped.each_with_object({}) do |((parent_id, base_name), members), names|
      collision = members.length > 1 || (parent_id.nil? && reserved_root_names.include?(base_name))
      members.each do |row|
        source_name = row["name"].to_s.strip
        source_name = "Blank" if source_name.empty?
        source_name = source_name[0..49]
        if collision
          suffix = " [DZ #{row["id"]}]"
          source_name = source_name[0, 50 - suffix.length] + suffix
        end
        names[row["id"].to_i] = source_name
      end
    end
  end

  def self.source_depth(row, rows_by_id)
    depth = 0
    parent_id = row["parent_id"].to_i
    visited = {}
    while parent_id.positive? && !visited.key?(parent_id) && (parent = rows_by_id[parent_id])
      visited[parent_id] = true
      depth += 1
      parent_id = parent["parent_id"].to_i
    end
    depth
  end
  private_class_method :source_depth
end
