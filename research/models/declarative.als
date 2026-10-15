module declarative

sig User {}
sig Blocked in User {}

sig Project { members: set User, maintainers: set User }
sig Public in Project {}
fact { all p: Project | p.maintainers in p.members }

sig Issue { project: one Project, author: one User }
sig Confidential in Issue {}

-- ProjectPolicy, one predicate per DSL line
--   condition(:public_project, scope: :subject) { @subject.public? }
--   condition(:member)     { @subject.member?(@user) }
--   condition(:maintainer) { @subject.maintainer?(@user) }
--   condition(:blocked, scope: :user) { @user.blocked? }
--   rule { public_project | member }.enable :read_project
--   rule { maintainer }.enable :update_project
--   rule { blocked }.prevent :read_project
--   rule { blocked }.prevent :update_project
pred member[u: User, p: Project]     { u in p.members }
pred maintainer[u: User, p: Project] { u in p.maintainers }
pred read_project[u: User, p: Project] {
  (p in Public or member[u, p]) and not u in Blocked
}
pred update_project[u: User, p: Project] { maintainer[u, p] and not u in Blocked }

-- IssuePolicy: delegate { @subject.project }
--   rule { can?(:read_project) }.enable :read_issue
-- buggy:  rule { confidential & ~member }.prevent :read_issue
-- fixed:  rule { confidential & ~author & ~can?(:update_project) }.prevent :read_issue
pred read_issue_buggy[u: User, i: Issue] {
  read_project[u, i.project]
  and not (i in Confidential and not member[u, i.project])
}
pred read_issue_fixed[u: User, i: Issue] {
  read_project[u, i.project]
  and not (i in Confidential and i.author != u and not update_project[u, i.project])
}

-- Ability.allowed?(user, :read_project, issue)
-- delegated as written: the parent's enable AND prevent rules both apply
pred issue_read_project[u: User, i: Issue] { read_project[u, i.project] }
-- with `overrides :read_project` + rule { author }.enable :read_project
pred issue_read_project_overridden[u: User, i: Issue] { i.author = u }

-- condition(:member, scope: :user): the first subject's answer is cached per user
one sig Cache { first: User -> one Project }
pred member_cached[u: User, p: Project] { u in (Cache.first[u]).members }
pred read_project_cached[u: User, p: Project] {
  (p in Public or member_cached[u, p]) and not u in Blocked
}

-- Intended policy, from the mapping and catalog
pred intended_read_issue[u: User, i: Issue] {
  not u in Blocked
  (i.project in Public or member[u, i.project])
  i in Confidential implies (i.author = u or maintainer[u, i.project])
}
pred intended_read_project[u: User, p: Project] {
  not u in Blocked
  p in Public or member[u, p]
}

D1_ConfidentialPrevent: check { all u: User, i: Issue | read_issue_buggy[u, i] implies intended_read_issue[u, i] } for 4
D1_Fixed:               check { all u: User, i: Issue | read_issue_fixed[u, i] implies intended_read_issue[u, i] } for 4
D2_Delegated:           check { all u: User, i: Issue | issue_read_project[u, i] implies intended_read_project[u, i.project] } for 4
D2_OverridesDropPrevent: check { all u: User, i: Issue | issue_read_project_overridden[u, i] implies intended_read_project[u, i.project] } for 4
D3_CacheScope:          check { all u: User, p: Project | read_project_cached[u, p] implies intended_read_project[u, p] } for 4
