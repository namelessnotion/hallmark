# typed: strict

module Hallmark
  module Naming
    module_function

    sig { params(text: T.any(String, Symbol)).returns(String) }
    def identifier(text); end

    sig { params(value: T.any(String, Symbol, T::Module[T.anything])).returns(String) }
    def class_name(value); end

    sig { params(name: String, kind: Symbol).returns(String) }
    def resource_sig(name, kind); end

    sig { params(name: T.any(String, Symbol)).returns(String) }
    def role_sig(name); end

    sig { params(name: T.any(String, Symbol)).returns(String) }
    def flag_field(name); end

    sig { params(name: T.any(String, Symbol)).returns(String) }
    def flag_sig(name); end

    # Shop::TeamMember -> "team_member"
    sig { params(class_name: String).returns(String) }
    def underscore(class_name); end

    # Link -> "links", Category -> "categories"
    sig { params(class_name: String).returns(String) }
    def plural(class_name); end

    sig { params(name: T.nilable(String)).returns(String) }
    def atom(name); end
  end
end
