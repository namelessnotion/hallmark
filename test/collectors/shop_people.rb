# frozen_string_literal: true

require_relative "../support/shop"

# The people of the test shop: two sellers, a team admin and a marketer of
# the first, someone on no team, and a member of the vendor's staff.
module ShopPeople
  def setup
    super
    @ann = Shop::User.new("ann")
    @bob = Shop::User.new("bob")
    @ada = Shop::User.new("ada")
    @mia = Shop::User.new("mia")
    @sam = Shop::User.new("sam")
    @sue = Shop::User.new("sue", staff: true)
    Shop.memberships.replace([@ada, @ann] => ["admin"], [@mia, @ann] => ["marketing"])
    @ann_link = Shop::Link.new(@ann)
    @bob_link = Shop::Link.new(@bob)
  end

  def stamp_for(set, entry_point, rule, **facts)
    set.stamps.find do |stamp|
      stamp.entry_point == entry_point && stamp.rule == rule && facts.all? { |key, value| stamp[key] == value }
    end
  end
end
