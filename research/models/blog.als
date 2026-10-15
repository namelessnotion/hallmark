module blog
open catalog

sig Post extends Resource {}

-- Generated from PostsController#update (seen 1,204 times in shadow mode)
-- Guard recovered from PostPolicy#update?: user.present?
pred posts_update[p: Principal, r: Post] { authenticated[p] }

-- Same action after the fix: user.present? && record.user == user
pred posts_update_fixed[p: Principal, r: Post] { authenticated[p] and r.owner = p }

assert PostsUpdateIsSafe {
  all p: Principal, r: Post | posts_update[p, r] implies allowed[p, Write, r]
}
assert PostsUpdateFixedIsSafe {
  all p: Principal, r: Post | posts_update_fixed[p, r] implies allowed[p, Write, r]
}

check PostsUpdateIsSafe for 5
check PostsUpdateFixedIsSafe for 5
check NoHierarchyCycles for 5
check StaticSoD for 5
check NoEscalationByAssignment for 5
