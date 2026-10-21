# frozen_string_literal: true

require "rake/testtask"
require "rubocop/rake_task"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
end

namespace :alloy do
  desc "Download the pinned Alloy jar and verify its checksum"
  task :install do
    require_relative "lib/hallmark"
    puts Hallmark::AlloyInstaller.new.install
  end
end

namespace :sidecar do
  desc "Build the solver sidecar jar from solver/src (needs a JDK 17+ and the Alloy jar)"
  task :install do
    require_relative "lib/hallmark"
    puts Hallmark::SidecarInstaller.new.install
  end
end

namespace :fixtures do
  desc "Re-run the buggy examples through Alloy and refresh test/fixtures/<example>"
  task :regenerate do
    require_relative "lib/hallmark"
    %w[medium_clone storefront].each do |example|
      load File.expand_path("examples/#{example}/hallmark.rb", __dir__)
      model = Hallmark::ModelBuilder.new(Hallmark.analyses.last).build
      output = File.expand_path("test/fixtures/#{example}", __dir__)
      receipt = Hallmark::Solver::CLI.new.solve_into(model, output)
      found = receipt.commands.values.count(&:counterexample?)
      puts "Wrote #{output} (#{receipt.commands.size} checks, #{found} counterexamples)"
    end
  end
end

desc "Measure what the collectors add to one authorization decision (BENCH_N decisions, default 20000)"
task :bench do
  ruby "-Ilib", "-Itest", "bench/hot_path.rb"
end

RuboCop::RakeTask.new

desc "Type-check lib/ against the signatures in rbi/"
task :typecheck do
  sh "bundle exec srb tc"
end

task default: %i[test rubocop typecheck]
