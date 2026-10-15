# frozen_string_literal: true

# MediumClone after the two fixes Hallmark points to:
#   UsersController: add :update to the :correct_user filter
#   PostsController: require sign-in for :update and check the post's author
#
# Run: bin/hallmark check examples/medium_clone/hallmark_fixed.rb

Hallmark.analyze "MediumClone (fixed)" do
  map do
    principal "User"
    resource "User", kind: :profile
    resource "Post", owner: :user, public_if: true
  end

  reads  "UsersController#show",   "User", guard: logged_in & owner
  reads  "UsersController#edit",   "User", guard: logged_in & owner
  writes "UsersController#update", "User", guard: logged_in & owner

  reads  "PostsController#show",   "Post", guard: none
  reads  "PostsController#edit",   "Post", guard: logged_in
  writes "PostsController#update", "Post", guard: logged_in & owner
end
