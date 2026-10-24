# frozen_string_literal: true

# Runs bench/app.rb inside the shop app rooted at ARGV[0], as `bin/rails
# runner` would in a real app (test/bench_app_test.rb).

require_relative "shop_app"

load File.expand_path("../../bench/app.rb", __dir__)
