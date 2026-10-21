# typed: strict
# frozen_string_literal: true

module Hallmark
  # The op a rule performs on its record, read or write, which picks the
  # catalog patterns its guard is checked against:
  #
  # 1. the mapping's `rule ..., op:`, which always wins;
  # 2. the rule's name, when it names a page that only shows something:
  #    `index?`, `show?`, the forms `new?` and `edit?`, a few view names
  #    (`preview?`, `stats?`, `export?`), and names that start or end like
  #    one (`index_collections?`, `show_in_v4?`, `new_transfer?`,
  #    `ledger_stats?`, `followers_count?`);
  # 3. the routes that reach it: a rule that only GET (or HEAD) requests
  #    authorize reads, since by HTTP's convention a GET changes nothing.
  #    The routes are those the test run recorded, else those read from
  #    `config/routes.rb` (`Extractor::RoutesFile`); a route reaches a rule
  #    when a stamp of the rule names its entry point, or when its
  #    controller action's authorize calls check it (`Extractor::Controllers`;
  #    for a record whose class the reader cannot tell, the policy its
  #    variable names, as Pundit's convention has it: `authorize @event`
  #    checks EventPolicy);
  # 4. otherwise a `?` rule writes, and a rule with another name (a
  #    DeclarativePolicy ability) has no op until the mapping gives one.
  #
  # A request's verb never makes a rule write: an action may check a read
  # rule on one record and then write another (reblogging checks `show?` on
  # the status reblogged), so only the absence of any other verb says
  # something about the rule.
  #
  # The collectors know no routes, so stamps record the facts that depend
  # on the op (`permitted`) for the op from steps 1, 2 and 4 (`Ops.named`).
  class Ops
    READ_NAMES = %w[index show new edit preview paged statistics stats overview search feed export download
                    pdf].freeze
    READ_PREFIXES = %w[index_ show_ new_ edit_ preview_ export_ download_].freeze
    READ_SUFFIXES = %w[_count _stats _statistics _overview _preview _chart].freeze
    SAFE_VERBS = %w[GET HEAD].freeze

    # The op from the mapping and the rule's name alone (steps 1, 2 and 4).
    def self.named(mapping, policy, name)
      declared = mapping.rules["#{policy}##{name}"]&.op
      return declared if declared
      return nil unless name.end_with?("?")

      read_name?(name) ? :read : :write
    end

    def self.read_name?(name)
      base = name.delete_suffix("?")
      READ_NAMES.include?(base) || READ_PREFIXES.any? { |prefix| base.start_with?(prefix) } ||
        READ_SUFFIXES.any? { |suffix| base.end_with?(suffix) }
    end

    def initialize(mapping, stamps: [], routes: [], controllers: nil)
      @mapping = mapping
      @stamps = stamps
      @controllers = controllers
      @verbs = {}
      routes.each do |route|
        verbs = route.verb.split("|")
        # "" is any verb.
        (@verbs[route.entry_point] ||= []).concat(verbs.empty? ? [""] : verbs)
      end
      @reaching = nil
      @unresolved = nil
    end

    # The rule's op (nil when only a `rule ..., op:` could give one).
    def fetch(policy, name)
      op = Ops.named(@mapping, policy, name)
      return op unless op == :write && @mapping.rules["#{policy}##{name}"]&.op.nil?

      gets_only(policy, name) ? :read : :write
    end

    # Why a rule reads when its routes decided it ("only GET requests reach
    # it: EventsController#ledger"), else nil.
    def basis(policy, name)
      return nil unless Ops.named(@mapping, policy, name) == :write && @mapping.rules["#{policy}##{name}"]&.op.nil?

      entry_points = gets_only(policy, name)
      "read: only GET requests reach it (#{entry_points.join(", ")})" if entry_points
    end

    private

    # The entry points that reach the rule, when there is at least one and
    # every route to each is a GET or HEAD; else nil. An authorize call whose
    # policy the controller reader could not tell counts against every rule
    # of its name.
    def gets_only(policy, name)
      reaching, unresolved = links
      found = reaching.fetch("#{policy}##{name}", [])
      return nil if found.empty?

      entry_points = (found + unresolved.fetch(name, [])).uniq.sort
      entry_points if entry_points.all? { |entry_point| safe?(entry_point) }
    end

    def safe?(entry_point)
      verbs = @verbs.fetch(entry_point) { grape_verb(entry_point) }
      !verbs.empty? && verbs.all? { |verb| SAFE_VERBS.include?(verb) }
    end

    # Grape endpoints are named by their verb ("GET /projects/:id").
    def grape_verb(entry_point)
      verb = entry_point[%r{\A[A-Z]+(?= /)}]
      verb ? [verb] : []
    end

    # Rule key => entry points, and rule name => entry points whose authorize
    # call names no policy, built on first use.
    def links
      reaching = @reaching
      unresolved = @unresolved
      return [reaching, unresolved] if reaching && unresolved

      reaching = {}
      unresolved = {}
      @stamps.each do |stamp|
        entry_point = stamp.entry_point
        (reaching[stamp.rule_key] ||= []) << entry_point if stamp.enforced && entry_point
      end
      @verbs.each_key { |entry_point| link_code(entry_point, reaching, unresolved) }
      @reaching = reaching
      @unresolved = unresolved
      [reaching, unresolved]
    end

    def link_code(entry_point, reaching, unresolved)
      read = @controllers&.fetch(entry_point)
      return unless read

      read.authorizations.each do |authorization|
        policy = authorization.policy || authorization.named_policy
        links = policy ? reaching : unresolved
        (links[policy ? "#{policy}##{authorization.rule}" : authorization.rule] ||= []) << entry_point
      end
    end
  end
end
