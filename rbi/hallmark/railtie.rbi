# typed: strict

module Hallmark
  class Railtie < ::Rails::Railtie
    ROUTES_LOADED_HOOK = T.let(T.unsafe(nil), String)
  end
end
