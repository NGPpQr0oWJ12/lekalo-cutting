# encoding: UTF-8
# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module CodexLekaloCutting
  EXTENSION = SketchupExtension.new(
    'Лекало для раскроя ткани',
    'lekalo_cutting/main'
  )
  EXTENSION.description = 'Построение лекал ткани по выбранным граням SketchUp. Ручная карта раскроя, ворс, резы, насечки и экспорт SVG/XML.'
  EXTENSION.version = '1.4.0'
  EXTENSION.creator = 'Малкаров Сослан'
  Sketchup.register_extension(EXTENSION, true)
end
