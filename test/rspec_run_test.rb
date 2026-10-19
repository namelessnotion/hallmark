# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# The matchers inside a real RSpec run, in a child process: the `:hallmark`
# tag (subject and ordering), guards inferred from the run being recorded,
# the shared solver closed after the suite, and the Storefront example spec.
class RSpecRunTest < Minitest::Test
  RSPEC = Gem.bin_path("rspec-core", "rspec")

  # A Pundit policy, whose constructor needs a user and a record, checked by
  # a tagged group defined before the requests that stamp its rules. In
  # defined or random order, the tagged group runs last. FixtureSolver
  # answers, so no Java is needed.
  SPEC = <<~RUBY.freeze
    require "hallmark/rspec"
    require #{File.join(ROOT, "test", "support", "shop").inspect}
    require #{File.join(ROOT, "test", "support", "fixture_solver").inspect}

    Hallmark.configure { |config| config.map { Shop.map(self) } }
    Hallmark::Collectors.install!(store: Hallmark::StampStore.new(ENV.fetch("STAMPS"), run: "spec"))
    solver = FixtureSolver.new("safe_PunditShop_LinkPolicy_update_write_Shop_Link" => :counterexample)
    Hallmark::RSpec.solver = solver
    at_exit { puts "closed=\#{solver.closed?} checks=\#{solver.checks.join(",")}" }

    RSpec.describe PunditShop::LinkPolicy, :hallmark do
      it { is_expected.to have_no_counterexample(:edit?) }

      context "nested" do
        it { is_expected.to have_no_counterexample(:update?) }
      end
    end

    RSpec.describe "LinksController" do
      it "lets the seller's team in, and an admin into another seller's link" do
        ann = Shop::User.new("ann")
        ada = Shop::User.new("ada")
        Shop.memberships.replace([ada, ann] => ["admin"])
        expect(Shop.request(PunditShop::LinksController, :edit, user: ann, seller: ann, link: Shop::Link.new(ann)))
          .to eq(200)
        other = Shop::Link.new(Shop::User.new("bob"))
        expect(Shop.request(PunditShop::LinksController, :update, user: ada, seller: ann, link: other)).to eq(200)
      end
    end
  RUBY

  def rspec(*, chdir: ROOT, env: {})
    env = { "HALLMARK_SOLVER" => nil, "HALLMARK_RUN" => nil, "HALLMARK_MODE" => nil, "HALLMARK_STAMPS" => nil }
          .merge(env)
    Open3.capture2e(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), RSPEC, *, chdir: chdir)
  end

  def test_runs_inside_rspec
    %w[defined rand:7].each { |order| run_policy_spec(order) }
  end

  def run_policy_spec(order)
    Dir.mktmpdir("hallmark-rspec") do |dir|
      File.write(File.join(dir, "policy_spec.rb"), SPEC)
      output, status = rspec("--order", order, "--format", "documentation", "policy_spec.rb",
                             chdir: dir, env: { "STAMPS" => File.join(dir, "stamps") })

      assert_equal 1, status.exitstatus, output
      assert_operator output.index("LinksController"), :<, output.index("PunditShop::LinkPolicy"), output
      assert_includes output, "is expected to have no counterexample for edit? within scope 5\n"
      assert_includes output, "FAIL  PunditShop::LinkPolicy#update? (write Shop::Link)"
      assert_includes output, "inferred from 1 allow-stamp of PunditShop::LinkPolicy#update?"
      assert_includes output, "closed=true checks=safe_PunditShop_LinkPolicy_edit_read_Shop_Link," \
                              "safe_PunditShop_LinkPolicy_update_write_Shop_Link"
    end
  end

  # A Pundit policy spec: `permit` builds the policy and calls the rule
  # itself, which the wrapper on the policy class's rules stamps. The
  # collectors are installed before pundit/rspec loads, as the Railtie does.
  PERMIT_SPEC = <<~RUBY.freeze
    require "hallmark"
    require #{File.join(ROOT, "test", "support", "shop").inspect}

    Hallmark.configure { |config| config.map { Shop.map(self) } }
    Hallmark::Collectors.install!(store: Hallmark::StampStore.new(ENV.fetch("STAMPS"), run: "spec"))
    require "pundit/rspec"

    RSpec.configure do |config|
      config.after(:suite) do
        Hallmark::Collectors.flush
        Hallmark::StampSet.load(ENV.fetch("STAMPS")).stamps.each do |stamp|
          puts "stamp \#{stamp.rule} \#{stamp.decision} enforced=\#{stamp.enforced} at=\#{stamp.entry_point.inspect}"
        end
      end
    end

    RSpec.describe PunditShop::LinkPolicy, type: :policy do
      subject { described_class }

      let(:ann) { Shop::User.new("ann") }
      let(:ada) { Shop::User.new("ada") }

      before { Shop.memberships.replace([ada, ann] => ["admin"]) }

      permissions :update? do
        it { is_expected.to permit(PunditShop::Context.new(ada, ann), Shop::Link.new(ann)) }
        it { is_expected.not_to permit(PunditShop::Context.new(ann, ada), Shop::Link.new(ann)) }
      end
    end
  RUBY

  def test_stamps_rules_a_pundit_policy_spec_calls
    Dir.mktmpdir("hallmark-rspec") do |dir|
      File.write(File.join(dir, "link_policy_spec.rb"), PERMIT_SPEC)
      output, status = rspec("link_policy_spec.rb", chdir: dir, env: { "STAMPS" => File.join(dir, "stamps") })

      assert_predicate status, :success?, output
      assert_includes output, "stamp update? allow enforced=false at=nil"
      assert_includes output, "stamp update? deny enforced=false at=nil"
    end
  end

  # The real solver: the sidecar when it is built, else the CLI.
  def test_storefront_example_spec_passes
    require_solver!
    output, status = rspec(File.join("examples", "storefront", "link_policy_spec.rb"))

    assert_predicate status, :success?, output
    assert_includes output, "5 examples, 0 failures"
  end
end
