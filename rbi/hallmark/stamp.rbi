# typed: strict

module Hallmark
  class Stamp
    sig { returns(T.nilable(String)) }
    def entry_point; end

    sig { returns(T.nilable(String)) }
    def policy; end

    sig { returns(T.nilable(String)) }
    def rule; end

    sig { returns(T.nilable(String)) }
    def resource; end

    sig { returns(T.nilable(T::Boolean)) }
    def class_level; end

    sig { returns(T.nilable(T::Boolean)) }
    def enforced; end

    # "allow" or "deny"
    sig { returns(T.nilable(String)) }
    def decision; end

    sig { returns(T.nilable(String)) }
    def raised; end

    sig { returns(T.nilable(T::Boolean)) }
    def logged_in; end

    sig { returns(T.nilable(T::Boolean)) }
    def owner; end

    sig { returns(T.nilable(T::Boolean)) }
    def public_record; end

    sig { returns(T.nilable(T::Boolean)) }
    def member; end

    sig { returns(T.nilable(T::Boolean)) }
    def in_current_tenant; end

    sig { returns(T.nilable(T::Boolean)) }
    def outside_tenants; end

    sig { returns(T.nilable(T::Boolean)) }
    def granted; end

    sig { returns(T.nilable(T::Boolean)) }
    def permitted; end

    sig { returns(T.nilable(T::Array[String])) }
    def roles; end

    sig { returns(T.nilable(T::Array[String])) }
    def record_roles; end

    sig { returns(T.nilable(T::Array[String])) }
    def current_roles; end

    sig do
      params(
        entry_point: T.nilable(String),
        policy: T.nilable(String),
        rule: T.nilable(String),
        resource: T.nilable(String),
        class_level: T.nilable(T::Boolean),
        enforced: T.nilable(T::Boolean),
        decision: T.nilable(String),
        raised: T.nilable(String),
        logged_in: T.nilable(T::Boolean),
        owner: T.nilable(T::Boolean),
        public_record: T.nilable(T::Boolean),
        member: T.nilable(T::Boolean),
        in_current_tenant: T.nilable(T::Boolean),
        outside_tenants: T.nilable(T::Boolean),
        granted: T.nilable(T::Boolean),
        permitted: T.nilable(T::Boolean),
        roles: T.nilable(T::Array[String]),
        record_roles: T.nilable(T::Array[String]),
        current_roles: T.nilable(T::Array[String])
      ).void
    end
    def initialize(
      entry_point: nil, policy: nil, rule: nil, resource: nil, class_level: nil, enforced: nil, decision: nil,
      raised: nil, logged_in: nil, owner: nil, public_record: nil, member: nil, in_current_tenant: nil,
      outside_tenants: nil, granted: nil, permitted: nil, roles: nil, record_roles: nil, current_roles: nil
    ); end

    sig { returns(T::Boolean) }
    def allow?; end

    sig { returns(String) }
    def rule_key; end

    sig { params(example: T.nilable(Example)).returns(String) }
    def to_json_line(example = nil); end
  end

  class Unchecked
    sig { returns(String) }
    def entry_point; end

    # The response status; nil in lines written before Oct 17, 2026
    sig { returns(T.nilable(Integer)) }
    def status; end

    # The HTTP verb ("GET"); nil in lines written before Oct 17, 2026
    sig { returns(T.nilable(String)) }
    def verb; end

    sig { params(entry_point: String, status: T.nilable(Integer), verb: T.nilable(String)).void }
    def initialize(entry_point:, status: nil, verb: nil); end

    sig { returns(String) }
    def to_json_line; end
  end

  class Route
    sig { returns(String) }
    def entry_point; end

    sig { returns(String) }
    def verb; end

    sig { returns(String) }
    def path; end

    sig { params(entry_point: String, verb: String, path: String).void }
    def initialize(entry_point:, verb:, path:); end

    sig { returns(String) }
    def to_json_line; end
  end

  class StampSet
    sig { returns(T::Array[Stamp]) }
    attr_reader :stamps

    # The app's routes, recorded at the end of the run; empty before Oct 19, 2026
    sig { returns(T::Array[Route]) }
    attr_reader :routes

    # Requests that finished without an authorization call, deduplicated
    sig { returns(T::Array[Unchecked]) }
    attr_reader :unchecked

    # The hashed ids each stamp was first seen with, when ids were recorded
    sig { returns(T::Hash[Stamp, Example]) }
    attr_reader :examples

    sig { params(path: String, run: T.nilable(String)).returns(StampSet) }
    def self.load(path, run: nil); end

    sig { params(path: String, run: T.nilable(String)).returns(T::Array[String]) }
    def self.files(path, run: nil); end

    # Stamp files grouped by run id; nil for files outside the naming pattern
    sig { params(runs: T::Hash[T.nilable(String), T::Array[String]]).returns(T.nilable(String)) }
    def self.latest(runs); end

    sig { params(files: T::Array[String]).returns(StampSet) }
    def self.read(files); end

    sig { params(lines: T::Array[String]).returns(StampSet) }
    def self.parse(lines); end

    # A parsed JSON line
    sig { params(data: T.untyped).returns(Stamp) }
    def self.stamp(data); end

    sig { params(data: T.untyped).returns(T.nilable(Example)) }
    def self.example(data); end

    sig do
      params(stamps: T::Array[Stamp], unchecked: T::Array[Unchecked], routes: T::Array[Route],
             examples: T::Hash[Stamp, Example]).void
    end
    def initialize(stamps = [], unchecked = [], routes = [], examples: {})
      @stamps = T.let(T.unsafe(nil), T::Array[Stamp])
      @unchecked = T.let(T.unsafe(nil), T::Array[Unchecked])
      @routes = T.let(T.unsafe(nil), T::Array[Route])
      @examples = T.let(T.unsafe(nil), T::Hash[Stamp, Example])
    end
  end
end
