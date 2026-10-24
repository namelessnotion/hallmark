# frozen_string_literal: true

Rails.application.routes.draw do
  patch "/links/:id" => "links#update"
end
