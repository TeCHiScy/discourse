# frozen_string_literal: true

require "php_serialize"

module DiscuzCategoryPermissions
  GUEST_GROUP_ID = "7"

  def self.source_category_read_restrictions(rows, medals_enabled:)
    # The sample manifest builder calls this helper outside Rails/ActiveSupport.
    # rubocop:disable Rails/IndexBy
    rows_by_id = rows.to_h { |row| [row["id"].to_i, row] }
    # rubocop:enable Rails/IndexBy
    cache = {}
    rows_by_id.each_value do |row|
      source_category_read_restricted?(row, rows_by_id, cache, Set.new, medals_enabled:)
    end
    cache
  end

  def self.write_restricted?(row)
    group_permission_restricted?(row["postperm"]) || group_permission_restricted?(row["replyperm"])
  end

  def self.source_category_read_restricted?(row, rows_by_id, cache, visiting, medals_enabled:)
    id = row["id"].to_i
    return cache[id] if cache.key?(id)
    return true if visiting.include?(id)

    source_restricted =
      view_restricted?(row["viewperm"]) ||
        formula_restricted?(row["formulaperm"], medals_enabled:) ||
        php_truthy?(row["forum_password"])
    parent_id = row["parent_id"].to_i
    parent = rows_by_id[parent_id] if parent_id.positive?
    inherited_restriction =
      parent &&
        source_category_read_restricted?(
          parent,
          rows_by_id,
          cache,
          visiting | [id],
          medals_enabled:,
        )
    cache[id] = !!(source_restricted || inherited_restriction)
  end

  def self.view_restricted?(value)
    permission = value.to_s
    return false if permission.empty? || permission == "0"

    !permission.split("\t").include?(GUEST_GROUP_ID)
  end

  def self.formula_restricted?(value, medals_enabled:)
    serialized = value.to_s
    return false if serialized.empty?

    data = PHP.unserialize(serialized)
    return false if data.nil? || data == false
    return true unless data.is_a?(Hash)

    formula = data[1] || data["1"]
    return true if active_formula_restricts?(formula)
    return true if medals_enabled && php_truthy?(data["medal"])

    php_truthy?(data["users"])
  rescue StandardError
    true
  end

  def self.active_formula_restricts?(formula)
    return false unless php_truthy?(formula)

    !%w[1 true].include?(formula.to_s.strip.downcase)
  end

  def self.group_permission_restricted?(value)
    permission = value.to_s
    return false if permission.empty? || permission == "0"

    !permission.split("\t").include?(GUEST_GROUP_ID)
  end

  def self.php_truthy?(value)
    return false if value.nil? || value == false
    return !value.empty? && value != "0" if String === value
    return !value.zero? if Numeric === value

    value.respond_to?(:empty?) ? !value.empty? : true
  end
end
