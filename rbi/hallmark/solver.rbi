# typed: strict

module Hallmark
  module Solver
    # Anything with `check(model)` and `close`: Solver::CLI or Solver::Sidecar
    Backend = T.type_alias { T.any(CLI, Sidecar) }

    sig { params(config: Configuration).returns(Backend) }
    def self.build(config = Hallmark.configuration); end

    sig { params(java: String).returns(T.nilable(T::Boolean)) }
    def self.java_runs?(java); end

    sig { params(pid: Integer).void }
    def self.kill(pid); end
  end
end
