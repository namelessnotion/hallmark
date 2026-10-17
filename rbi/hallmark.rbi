# typed: strict

# Signatures for lib/hallmark.rb. Hallmark keeps every signature in rbi/ so the
# gem never loads sorbet-runtime; `srb tc` checks lib/ against these files.
module Hallmark
  DATA_DIR = T.let(T.unsafe(nil), String)
  CATALOG_PATH = T.let(T.unsafe(nil), String)
  SIDECAR_SOURCE = T.let(T.unsafe(nil), String)

  @configuration = T.let(nil, T.nilable(Configuration))
  @analyses = T.let(nil, T.nilable(T::Array[Analysis]))
  @solver = T.let(nil, T.nilable(Solver::Backend))

  class << self
    sig { returns(Configuration) }
    def configuration; end

    sig { params(blk: T.proc.params(config: Configuration).void).void }
    def configure(&blk); end

    sig do
      params(
        name: T.any(String, Symbol),
        blk: T.nilable(T.proc.bind(Analysis::Builder).void)
      ).returns(Analysis)
    end
    def analyze(name = "app", &blk); end

    sig { returns(T::Array[Analysis]) }
    def analyses; end

    sig { returns(Solver::Backend) }
    def solver; end

    sig { void }
    def reset!; end
  end
end
