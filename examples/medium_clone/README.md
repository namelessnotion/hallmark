# MediumClone

The worked example from Near and Jackson's SPACE paper (ICSE 2016). MediumClone
is a small blogging app: users sign up, write posts, and are meant to change
only their own posts and profiles. Its controllers enforce that with Rails
`before_filter` callbacks, summarized here:

```ruby
class UsersController < ApplicationController
  before_filter :signed_in_user, only: [:show, :edit, :update]
  before_filter :correct_user,   only: [:show, :edit]          # :update is missing
end

class PostsController < ApplicationController
  before_filter :signed_in_user, only: [:new, :create, :edit]  # :update is missing
  # no action checks that the post belongs to the current user
end
```

`hallmark.rb` states those guards; `hallmark_fixed.rb` states the corrected
ones. In phase 0 the guards are written by hand. Phase 2 extracts them from
controller filters and policy classes.

```console
$ bin/hallmark check examples/medium_clone/hallmark.rb
Hallmark 0.0.1, MediumClone, Alloy 6.2.0, scope 5

FAIL  UsersController#update (write User)
      guard: logged_in
      a signed-in User (User$1) holding no roles can update the User profile of User$0
      intended pattern: User profiles
FAIL  PostsController#update (write Post)
      guard: no check
      an anonymous visitor can update a Post owned by User$0
      intended pattern: Authentication
ok    UsersController#show (read User)
ok    UsersController#edit (read User)
ok    PostsController#show (read Post)
ok    PostsController#edit (read Post)

2 counterexamples in 6 checks.
```

These are the two counterexamples in the paper's Figure 2. Fixing only the
sign-in check on `PostsController#update` leaves a third: any signed-in user
can update anyone's post (see `test/medium_clone_test.rb`).
