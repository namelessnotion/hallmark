# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# bench/app.rb, the hot path measured inside a booted app, run on the shop
# app in a child process with a small BENCH_N: it loads the app's mapping
# itself (the development environment installs no collectors), and prints
# the shop's table plus decisions per call and the 1% sample rate.
class BenchAppTest < Minitest::Test
  RUNNER = File.join(ROOT, "test", "support", "bench_app.rb")
  SCENARIOS = File.join(ROOT, "test", "support", "bench_scenarios.rb")
  CONFIG = "Hallmark.configure { |config| config.map { Shop.map(self) } }\n"
  ROUTES = <<~RUBY
    Rails.application.routes.draw do
      get "/links/:id/edit" => "pundit_shop/links#edit"
    end
  RUBY

  def run_bench
    Dir.mktmpdir("hallmark-bench-app") do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config", "hallmark.rb"), CONFIG)
      File.write(File.join(root, "config", "routes.rb"), ROUTES)
      env = { "RAILS_ENV" => "development", "HALLMARK_MODE" => nil, "HALLMARK_ROOT" => root, "BENCH_N" => "1000",
              "BENCH_SCENARIOS" => SCENARIOS }
      output, error, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), RUNNER, root)
      assert_predicate status, :success?, error
      output
    end
  end

  def test_measures_the_apps_requests_per_decision
    output = run_bench
    rows = output.lines.select { |line| line.start_with?("GET /links/1/edit", "LinkPolicy#edit?") }

    assert_equal 4, rows.size, output
    assert_match(/^scenario\s+bare p50 .* skip allocs$/, output)
    assert_match(%r{^scenario\s+decisions\s+own p50/d\s+own p99/d\s+1% expect\s+1% meas$}, output)
    # One decision per call in each scenario.
    assert_equal([1, 1], rows.last(2).map { |row| row.split.fetch(-5).to_i })
  end
end
