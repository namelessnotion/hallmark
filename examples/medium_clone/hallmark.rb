# frozen_string_literal: true

# MediumClone as analyzed by Near and Jackson (ICSE 2016): a small blogging
# app where users sign up, write posts, and may only change their own posts
# and profiles. The guards below are what its controllers actually enforce;
# see README.md in this folder for the controller filters they come from.
#
# Run: bin/hallmark check examples/medium_clone/hallmark.rb

Hallmark.analyze "MediumClone" do
  map do
    principal "User"
    resource "User", kind: :profile
    resource "Post", owner: :user, public_if: true
  end

  # UsersController: before_filter :signed_in_user, only: [:show, :edit, :update]
  #                  before_filter :correct_user,   only: [:show, :edit]
  reads  "UsersController#show",   "User", guard: logged_in & owner
  reads  "UsersController#edit",   "User", guard: logged_in & owner
  writes "UsersController#update", "User", guard: logged_in

  # PostsController: before_filter :signed_in_user, only: [:new, :create, :edit]
  reads  "PostsController#show",   "Post", guard: none
  reads  "PostsController#edit",   "Post", guard: logged_in
  writes "PostsController#update", "Post", guard: none
end
