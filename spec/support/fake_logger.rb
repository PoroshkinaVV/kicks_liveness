# Simpler than a verified double: what matters in the logging tests is the order
# and the levels, not the individual calls.
class FakeLogger
  attr_reader :lines

  def initialize
    @lines = []
  end

  def info(message)
    @lines << [:info, message]
  end

  def error(message)
    @lines << [:error, message]
  end
end
