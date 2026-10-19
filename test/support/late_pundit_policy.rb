# frozen_string_literal: true

# A Pundit policy loaded after the collectors are installed, as Rails
# autoloads one. It overrides a rule and calls the one it overrides,
# delegates to another rule (as Pundit's generated `edit?` calls `update?`),
# takes arguments and a block and returns what it was given, and raises.
module PunditShop
  class LatePolicy < LinkPolicy
    Transfer = Struct.new(:buyer, :note, :notify, :block_result)

    def update? = super || (!user.nil? && user.staff?)
    def destroy? = update?
    def transfer?(buyer, note = nil, notify: false, &block) = Transfer.new(buyer, note, notify, block&.call)
    def archive? = raise(KeyError, "no membership")
  end
end
