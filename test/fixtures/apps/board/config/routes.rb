# frozen_string_literal: true

# Routes for Hallmark's routes reader and op inference tests: one of each
# form `Extractor::RoutesFile` reads, and some it skips.
Rails.application.routes.draw do
  root "pages#home"
  get "/about" => "pages#about"
  get "photos/search"

  concern :commentable do
    resources :comments, only: [:create]
  end

  resources :events, only: %i[index show update] do
    get :ledger
    get :statement
    post "toggle_pinned"
    get "payouts/new", to: "events#new_payout"
    get "edit", to: redirect("/events/%{event_id}/preferences")
    member do
      post :archive
    end
    collection do
      get :mine
    end
    resources :payees, only: %i[index create], controller: "payroll/payees"
  end
  post "events/:id/statement", to: "events#email_statement"

  resource :inbox, only: :show
  resources :invoices, only: [], concerns: :commentable

  namespace :admin do
    resources :events, only: [:index]
    get "stats", to: "dashboard#stats"
  end

  scope module: :api, path: "api" do
    resources :tags, except: %i[new edit]
  end

  controller :pages do
    get "terms"
  end

  match "status", to: "pages#status", via: %i[get head]
  match "hook", to: "hooks#receive", via: :all
  %w[one two].each { |name| get name }

  draw :extra
  mount Sidekiq::Web => "/sidekiq"
end
