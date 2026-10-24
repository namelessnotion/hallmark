# frozen_string_literal: true

Rails.application.routes.draw do
  resources :links, only: :show

  namespace :admin do
    resources :links, only: :show
  end
end
