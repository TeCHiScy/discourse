# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class SellTagParser
    OPENING = /\[sell=(\+?\d+),(\d+)\]/i
    OPEN_PREFIX = /\[sell\s*=/i
    CLOSING = %r{\[/sell\]}i
    MAX_SECTIONS = 100

    def self.extract(raw, discuz_pid:)
      source = raw.to_s
      pid = Integer(discuz_pid)
      raise ArgumentError, "Discuz post ID must be positive" unless pid.positive?

      sections = []
      output = +""
      cursor = 0

      loop do
        opening = OPENING.match(source, cursor)
        prefix = OPEN_PREFIX.match(source, cursor)
        if prefix && (!opening || prefix.begin(0) < opening.begin(0))
          raise ArgumentError, "malformed Discuz sell section in post #{pid}"
        end
        break unless opening

        closing = CLOSING.match(source, opening.end(0))
        raise ArgumentError, "unclosed Discuz sell section in post #{pid}" unless closing

        nested_prefix = OPEN_PREFIX.match(source, opening.end(0))
        if nested_prefix && nested_prefix.begin(0) < closing.begin(0)
          raise ArgumentError, "nested Discuz sell section in post #{pid}"
        end

        index = sections.length
        raise ArgumentError, "too many Discuz sell sections in post #{pid}" if index >= MAX_SECTIONS

        body = source[opening.end(0)...closing.begin(0)]
        sections << {
          section_index: index,
          price: opening[1].to_i,
          credit_id: opening[2].to_i,
          body: body,
        }

        output << source[cursor...opening.begin(0)]
        output << marker(pid, index)
        cursor = closing.end(0)
      end

      output << source[cursor..].to_s
      [output, sections]
    rescue ArgumentError
      raise
    rescue StandardError => e
      raise ArgumentError, "unable to parse Discuz sell sections: #{e.class}"
    end

    def self.marker(discuz_pid, section_index)
      "[discuzsell]#{Integer(discuz_pid)}:#{Integer(section_index)}[/discuzsell]"
    end
  end
end
