# frozen_string_literal: true

require_relative "../mapping"

Hallmark.configure { |config| config.map { RevocationShopMapping.apply(self) } }
