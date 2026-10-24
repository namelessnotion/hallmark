# frozen_string_literal: true

# The runner fixture after the fix (test/graphql_field_classes_test.rb): a
# runner's maintainer lists the jobs it ran, which may belong to other
# projects; a job's trace is for the job's project members.
Hallmark.analyze "GraphQL runners, after the fix" do
  map do
    principal "User"
    tenant "Project", membership: "ProjectMember", roles: :access_level
    resource "Project", tenant: :itself
    # A runner may serve projects other than its own, so jobs reached
    # through it may be anywhere (no same-tenant fact for its edges).
    resource "Ci::Runner", tenant: :project, tenant_optional: true
    resource "Ci::Build", tenant: :project
    graphql_type "Types::Ci::JobType", resource: "Ci::Build"
    graphql_type "Types::Ci::RunnerType", resource: "Ci::Runner"

    grant :member, :read, "Project"
    grant :maintainer, :read, "Project"
    grant :member, :read, "Ci::Build"
    grant :maintainer, :read, "Ci::Build"
    grant :maintainer, :read, "Ci::Runner"

    field_policy "Ci::Build", :trace, role(:member, tenant: :record) | role(:maintainer, tenant: :record)

    term "member", role(:member, tenant: :record) | role(:maintainer, tenant: :record)
    term "maintainer", role(:maintainer, tenant: :record)
    term "admin", Hallmark::Guard.new(:never)
  end

  graphql_schema __dir__
end
