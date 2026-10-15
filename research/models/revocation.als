module revocation

sig Role {}
sig Resource { needs: one Role }
sig User { var roles: set Role, var cached: set Resource }

pred unchangedExcept[u: User] {
  all x: User - u | x.roles' = x.roles and x.cached' = x.cached
}

pred decide[u: User, d: Resource] {        -- an allow decision gets cached
  d.needs in u.roles
  u.cached' = u.cached + d
  u.roles' = u.roles
  unchangedExcept[u]
}

pred revoke[u: User, r: Role] {            -- the app's revocation path
  r in u.roles
  u.roles' = u.roles - r
  u.cached' = u.cached                     -- does the app clear the cache? here: no
  unchangedExcept[u]
}

pred stutter { roles' = roles and cached' = cached }

fact traces {
  no cached
  always (stutter
          or (some u: User, d: Resource | decide[u, d])
          or (some u: User, r: Role | revoke[u, r]))
}

assert NoStaleAccess { always all u: User | u.cached.needs in u.roles }
check NoStaleAccess for 3 but 6 steps
