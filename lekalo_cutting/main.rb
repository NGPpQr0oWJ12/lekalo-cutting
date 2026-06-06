# encoding: UTF-8
# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require 'fileutils'
require 'net/http'
require 'uri'
require 'tempfile'
require 'digest'

module CodexLekaloCutting
  module Main
    PLUGIN_DIR = File.dirname(__FILE__)
    DIALOG_FILE = File.join(PLUGIN_DIR, 'dialog.html')
    DETAILS_FILE = File.join(PLUGIN_DIR, 'details.html')
    GITHUB_REPOSITORY = 'NGPpQr0oWJ12/lekalo-cutting'
    GITHUB_RELEASE_API = "https://api.github.com/repos/#{GITHUB_REPOSITORY}/releases/latest"
    RELEASE_ASSET_NAME = 'lekalo_cutting.rbz'
    DICT = 'LekaloCutting'
    MM_PER_INCH = 25.4
    INCH_PER_MM = 1.0 / MM_PER_INCH
    DEFAULT_FABRIC_WIDTH = 1400
    DEFAULT_EDGE_MARGIN = 20
    DEFAULT_GAP = 30
    DEFAULT_ALLOWANCE = 20
    AUTO_PATCH_NORMAL_SPREAD_DEGREES = 28.0
    AUTO_COMPLEX_SURFACE_FACE_COUNT = 12

    module_function

    def install_ui
      menu = UI.menu('Extensions').add_submenu('Лекало для раскроя ткани')
      open_command = make_command('Открыть карту раскроя', 'open.svg') { open_dialog }
      open_command.tooltip = 'Построить карту раскроя по выделенным граням'
      open_command.status_bar_text = 'Выберите грани, группу или компонент и откройте карту раскроя.'
      list_command = make_command('Список деталей', 'list.svg') { open_parts_dialog }
      list_command.tooltip = 'Открыть отдельное окно деталей лекала'
      list_command.status_bar_text = 'Немодальный список деталей: создание, резы, насечки, ворс и удаление меток.'
      part_command = make_command('Создать деталь из выделения', 'part.svg') { mark_part_from_selection }
      cut_command = make_command('Добавить линию реза', 'cut.svg') { mark_cut_edges_from_selection }
      notch_command = make_command('Добавить насечку по ребру', 'notch.svg') { mark_notches_from_selection }
      grain_command = make_command('Задать направление ворса', 'grain.svg') { start_grain_tool }
      update_command = make_command('Обновить плагин', 'update.svg') { open_update_dialog }
      clear_command = make_command('Очистить метки лекала', 'clear.svg') { clear_marks_from_selection }
      menu.add_item(open_command)
      menu.add_item(list_command)
      menu.add_separator
      [part_command, cut_command, notch_command, grain_command, clear_command].each { |command| menu.add_item(command) }
      menu.add_separator
      menu.add_item(update_command)

      toolbar = UI::Toolbar.new('Лекало ткани')
      [open_command, list_command, part_command, cut_command, notch_command, grain_command, update_command, clear_command].each { |command| toolbar.add_item(command) }
      toolbar.restore
    end

    def make_command(title, icon_name, &block)
      command = UI::Command.new(title) { block.call }
      icon_path = File.join(PLUGIN_DIR, 'icons', icon_name)
      if File.exist?(icon_path)
        command.small_icon = icon_path
        command.large_icon = icon_path
      end
      command.tooltip = title
      command.status_bar_text = title
      command
    end

    def open_update_dialog
      result = UI.inputbox(
        ['Источник обновления'],
        ['С сервера'],
        ['С сервера|Из файла'],
        'Обновление плагина'
      )
      return unless result

      if result.first == 'С сервера'
        update_plugin_from_server
      else
        update_plugin_from_file
      end
    end

    def update_plugin_from_file
      source_path = UI.openpanel(
        'Выберите файл обновления RBZ или RB',
        nil,
        'Расширение SketchUp или Ruby-файл|*.rbz;*.rb||'
      )
      return unless source_path

      extension = File.extname(source_path).downcase
      if extension == '.rbz'
        install_rbz(source_path)
      elsif extension == '.rb'
        update_plugin_from_rb(source_path)
      else
        UI.messagebox('Выберите файл с расширением .rbz или .rb.')
      end
    end

    def update_plugin_from_server
      Sketchup.set_status_text('Лекало ткани: загрузка последней версии с GitHub...')
      release = JSON.parse(http_get(URI(GITHUB_RELEASE_API)))
      assets = release.fetch('assets', [])
      rbz_asset = assets.find { |asset| asset['name'] == RELEASE_ASSET_NAME } ||
                  assets.find { |asset| File.extname(asset['name'].to_s).downcase == '.rbz' }
      raise "В последнем релизе #{release['tag_name']} нет RBZ-файла." unless rbz_asset

      archive_data = http_get(URI(rbz_asset.fetch('browser_download_url')))
      verify_release_checksum!(assets, archive_data)

      archive = Tempfile.new(['lekalo_cutting_update_', '.rbz'])
      archive.binmode
      archive.write(archive_data)
      archive.close
      install_rbz(archive.path, release['tag_name'])
    rescue StandardError => error
      UI.messagebox("Не удалось обновить плагин с сервера:\n#{error.class}: #{error.message}")
    ensure
      Sketchup.set_status_text('')
      archive&.unlink
    end

    def install_rbz(path, version = nil)
      unless Sketchup.respond_to?(:install_from_archive)
        raise 'Эта версия SketchUp не поддерживает установку RBZ через Ruby API.'
      end

      Sketchup.install_from_archive(path)
      label = version ? " #{version}" : ''
      UI.messagebox("Обновление#{label} установлено.\n\nПерезапустите SketchUp.")
    rescue Interrupt
      UI.messagebox('Установка обновления отменена.')
    end

    def verify_release_checksum!(assets, archive_data)
      checksum_asset = assets.find { |asset| asset['name'] == "#{RELEASE_ASSET_NAME}.sha256" }
      return unless checksum_asset

      expected = http_get(URI(checksum_asset.fetch('browser_download_url'))).split.first.to_s.downcase
      actual = Digest::SHA256.hexdigest(archive_data)
      raise 'Контрольная сумма RBZ не совпадает. Установка отменена.' unless expected == actual
    end

    def http_get(uri, redirect_limit = 5)
      raise 'Слишком много перенаправлений при загрузке обновления.' if redirect_limit <= 0

      request = Net::HTTP::Get.new(uri)
      request['Accept'] = 'application/vnd.github+json'
      request['User-Agent'] = 'Lekalo-Cutting-SketchUp'
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == 'https',
        open_timeout: 15,
        read_timeout: 60
      ) { |http| http.request(request) }

      case response
      when Net::HTTPSuccess
        response.body
      when Net::HTTPRedirection
        http_get(URI.join(uri.to_s, response['location']), redirect_limit - 1)
      else
        if response.code.to_i == 404
          raise "На сервере обновлений пока нет опубликованного релиза для #{GITHUB_REPOSITORY}."
        end
        raise "GitHub вернул HTTP #{response.code}: #{response.message}"
      end
    end

    def update_plugin_from_rb(source_path)
      target_path = nil
      backup_path = nil
      temp_path = nil

      source_path = File.expand_path(source_path)
      unless File.file?(source_path) && File.extname(source_path).downcase == '.rb'
        UI.messagebox('Выбранный файл должен иметь расширение .rb.')
        return
      end

      source = File.open(source_path, 'rb', &:read)
      target_path = update_target_for(source)
      unless target_path
        UI.messagebox("Файл не похож на файл плагина «Лекало ткани».\n\nВыберите новый main.rb или загрузочный lekalo_cutting.rb.")
        return
      end

      if same_file_path?(source_path, target_path)
        UI.messagebox('Выбран уже установленный файл. Выберите новый RB-файл обновления.')
        return
      end

      unless File.writable?(File.dirname(target_path)) && (!File.exist?(target_path) || File.writable?(target_path))
        UI.messagebox("Нет прав для обновления файла:\n#{target_path}\n\nПереустановите расширение в папку пользователя или запустите SketchUp с правами записи.")
        return
      end

      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      temp_path = "#{target_path}.update_tmp_#{timestamp}"
      backup_path = "#{target_path}.backup_#{timestamp}"
      File.open(temp_path, 'wb') { |file| file.write(source) }
      raise 'Не удалось полностью подготовить файл обновления.' unless File.size(temp_path) == source.bytesize

      FileUtils.cp(target_path, backup_path) if File.exist?(target_path)
      FileUtils.cp(temp_path, target_path)

      unless File.size(target_path) == source.bytesize
        FileUtils.cp(backup_path, target_path) if File.exist?(backup_path)
        raise 'Размер обновленного файла не совпадает с исходным.'
      end

      FileUtils.rm_f(temp_path)
      UI.messagebox("Плагин успешно обновлен.\n\nПерезапустите SketchUp.")
    rescue StandardError => error
      FileUtils.cp(backup_path, target_path) if backup_path && target_path && File.exist?(backup_path)
      FileUtils.rm_f(temp_path) if temp_path
      UI.messagebox("Не удалось обновить плагин:\n#{error.class}: #{error.message}")
    end

    def update_target_for(source)
      if source.include?('module CodexLekaloCutting') && source.include?('module Main')
        __FILE__
      elsif source.include?('SketchupExtension.new') && source.include?('lekalo_cutting/main')
        File.expand_path('../lekalo_cutting.rb', PLUGIN_DIR)
      end
    end

    def same_file_path?(first, second)
      File.expand_path(first).tr('\\', '/').downcase == File.expand_path(second).tr('\\', '/').downcase
    end

    def open_dialog
      payload = current_payload
      if payload[:panels].empty?
        UI.messagebox('Выберите хотя бы одну грань Face, группу или компонент с гранями.')
        return
      end

      dialog = UI::HtmlDialog.new(
        dialog_title: 'Лекало для раскроя ткани',
        preferences_key: 'codex.lekalo_cutting',
        scrollable: true,
        resizable: true,
        width: 1280,
        height: 820,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      html = File.open(DIALOG_FILE, 'r:utf-8') { |file| file.read }
      html.sub!('__LEKALO_MODEL_JSON__', JSON.generate(payload))
      dialog.set_html(html)

      dialog.add_action_callback('reload_selection') do |_context|
        dialog.execute_script("window.LekaloApp.loadModel(#{JSON.generate(current_payload)});")
      end

      dialog.add_action_callback('mark_part') do |_context|
        mark_part_from_selection(false)
        dialog.execute_script("window.LekaloApp.loadModel(#{JSON.generate(current_payload)});")
      end

      dialog.add_action_callback('mark_cut') do |_context|
        mark_cut_edges_from_selection(false)
        dialog.execute_script("window.LekaloApp.loadModel(#{JSON.generate(current_payload)});")
      end

      dialog.add_action_callback('mark_notch') do |_context|
        mark_notches_from_selection(false)
        dialog.execute_script("window.LekaloApp.loadModel(#{JSON.generate(current_payload)});")
      end

      dialog.add_action_callback('clear_marks') do |_context|
        clear_marks_from_selection(false)
        dialog.execute_script("window.LekaloApp.loadModel(#{JSON.generate(current_payload)});")
      end

      dialog.add_action_callback('start_grain') do |_context|
        start_grain_tool
      end

      dialog.add_action_callback('open_parts_dialog') do |_context|
        open_parts_dialog
      end

      dialog.add_action_callback('set_selection_grain_axis') do |_context, axis|
        set_selection_grain_axis(axis.to_s, false)
      end

      dialog.add_action_callback('create_model') do |_context, layout_json|
        create_layout_in_model(JSON.parse(layout_json.to_s))
      end

      dialog.add_action_callback('save_svg') do |_context, svg|
        save_text_file('Сохранить SVG лекала', 'lekalo.svg', svg)
      end

      dialog.add_action_callback('save_xml') do |_context, xml|
        save_text_file('Сохранить XML лекала', 'lekalo.xml', xml)
      end

      dialog.show
    rescue StandardError => error
      UI.messagebox("Ошибка плагина лекал:\n#{error.class}: #{error.message}\n\n#{error.backtrace.first}")
    end

    def open_parts_dialog
      dialog = UI::HtmlDialog.new(
        dialog_title: 'Список деталей лекала',
        preferences_key: 'codex.lekalo_cutting.parts',
        scrollable: true,
        resizable: true,
        width: 420,
        height: 620,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      html = File.open(DETAILS_FILE, 'r:utf-8') { |file| file.read }
      html.sub!('__LEKALO_MODEL_JSON__', JSON.generate(current_payload))
      dialog.set_html(html)

      refresh = lambda do
        dialog.execute_script("window.LekaloParts.loadModel(#{JSON.generate(current_payload)});")
      end

      dialog.add_action_callback('refresh') { |_context| refresh.call }
      dialog.add_action_callback('open_map') { |_context| open_dialog }
      dialog.add_action_callback('mark_part') do |_context|
        mark_part_from_selection(false)
        refresh.call
      end
      dialog.add_action_callback('mark_cut') do |_context|
        mark_cut_edges_from_selection(false)
        refresh.call
      end
      dialog.add_action_callback('mark_notch') do |_context|
        mark_notches_from_selection(false)
        refresh.call
      end
      dialog.add_action_callback('clear_marks') do |_context|
        clear_marks_from_selection(false)
        refresh.call
      end
      dialog.add_action_callback('set_selection_grain_axis') do |_context, axis|
        set_selection_grain_axis(axis.to_s, false)
        refresh.call
      end

      dialog.show
    rescue StandardError => error
      UI.messagebox("Ошибка окна деталей:\n#{error.class}: #{error.message}\n\n#{error.backtrace.first}")
    end

    def current_payload
      model = Sketchup.active_model
      panels = build_surface_panels(selected_face_refs)
      {
        model_name: model.title.to_s,
        generated_at: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        unit: 'mm',
        fabric: {
          width_mm: DEFAULT_FABRIC_WIDTH,
          edge_margin_mm: DEFAULT_EDGE_MARGIN,
          nap_direction: { x: 0, y: 1 },
          has_nap: true
        },
        defaults: {
          allowance_mm: DEFAULT_ALLOWANCE,
          gap_mm: DEFAULT_GAP
        },
        panels: panels,
        layout: panels.map { |panel| { id: panel[:id], x: nil, y: nil, rotation: 0, manual: false, locked: false } }
      }
    end

    def selected_face_refs
      refs = []
      Sketchup.active_model.selection.each do |entity|
        collect_face_refs(entity, Geom::Transformation.new, refs)
      end
      refs.uniq { |item| [stable_entity_id(item[:face]), item[:path]] }
    end

    def collect_face_refs(entity, transformation, refs, path = '')
      case entity
      when Sketchup::Face
        refs << { face: entity, transformation: transformation, path: path }
      when Sketchup::Group
        collect_entities(entity.entities, transformation * entity.transformation, refs, "#{path}/group#{stable_entity_id(entity)}")
      when Sketchup::ComponentInstance
        collect_entities(entity.definition.entities, transformation * entity.transformation, refs, "#{path}/instance#{stable_entity_id(entity)}")
      when Sketchup::Edge
        entity.faces.each { |face| refs << { face: face, transformation: transformation, path: path } }
      end
    end

    def collect_entities(entities, transformation, refs, path)
      entities.each { |entity| collect_face_refs(entity, transformation, refs, path) }
    end

    def mark_part_from_selection(show_message = true)
      refs = selected_face_refs
      if refs.empty?
        UI.messagebox('Выберите грани, группу или компонент для детали.') if show_message
        return
      end
      suggested = "Деталь #{Time.now.strftime('%H%M%S')}"
      result = UI.inputbox(['Название детали'], [suggested], 'Создать деталь из выделения')
      return unless result

      name = result[0].to_s.strip
      name = suggested if name.empty?
      part_id = "part_#{Time.now.to_i}_#{rand(1000)}"
      refs.each do |ref|
        ref[:face].set_attribute(DICT, 'part_id', part_id)
        ref[:face].set_attribute(DICT, 'part_name', name)
      end
      UI.messagebox("Деталь создана: #{name}") if show_message
    end

    def mark_cut_edges_from_selection(show_message = true)
      edges = Sketchup.active_model.selection.grep(Sketchup::Edge)
      if edges.empty?
        UI.messagebox('Выберите ребра, которые должны стать линиями реза.') if show_message
        return
      end
      edges.each { |edge| edge.set_attribute(DICT, 'cut_edge', true) }
      UI.messagebox("Линий реза добавлено: #{edges.length}") if show_message
    end

    def mark_notches_from_selection(show_message = true)
      edges = Sketchup.active_model.selection.grep(Sketchup::Edge)
      if edges.empty?
        UI.messagebox('Нарисуйте короткие ребра от края детали внутрь и выделите их как линии насечки.') if show_message
        return
      end
      edges.each { |edge| edge.set_attribute(DICT, 'notch', true) }
      UI.messagebox("Линий насечки добавлено: #{edges.length}") if show_message
    end

    def clear_marks_from_selection(show_message = true)
      entities = []
      Sketchup.active_model.selection.each { |entity| collect_markable_entities(entity, entities) }
      entities.each do |entity|
        %w[part_id part_name cut_edge notch grain_vector grain_points].each { |key| delete_attr(entity, key) }
      end
      UI.messagebox('Метки лекала очищены у выбранных элементов.') if show_message
    end

    def collect_markable_entities(entity, entities)
      entities << entity if [Sketchup::Face, Sketchup::Edge].any? { |klass| entity.is_a?(klass) }
      case entity
      when Sketchup::Group
        entity.entities.each { |child| collect_markable_entities(child, entities) }
      when Sketchup::ComponentInstance
        entity.definition.entities.each { |child| collect_markable_entities(child, entities) }
      end
    end

    def start_grain_tool
      refs = selected_face_refs
      if refs.empty?
        UI.messagebox('Сначала выберите грани детали, для которой нужно задать направление ворса.')
        return
      end
      Sketchup.active_model.select_tool(GrainDirectionTool.new)
    end

    def store_grain_for_selection(first_point, second_point)
      vector = first_point.vector_to(second_point)
      if vector.length <= 0.0001
        UI.messagebox('Направление ворса не задано: точки совпадают.')
        return
      end
      refs = selected_face_refs
      vector.normalize!
      points = [[first_point.x, first_point.y, first_point.z], [second_point.x, second_point.y, second_point.z]]
      refs.each do |ref|
        ref[:face].set_attribute(DICT, 'grain_vector', [vector.x, vector.y, vector.z])
        ref[:face].set_attribute(DICT, 'grain_points', points)
      end
      UI.messagebox('Направление ворса сохранено для выбранной детали.')
    end

    def set_selection_grain_axis(axis, show_message = true)
      refs = selected_face_refs
      if refs.empty?
        UI.messagebox('Выберите грани детали, для которых нужно задать ворс.') if show_message
        return
      end

      vector = case axis
               when 'up' then Geom::Vector3d.new(0, 0, 1)
               when 'down' then Geom::Vector3d.new(0, 0, -1)
               when 'right' then Geom::Vector3d.new(1, 0, 0)
               when 'left' then Geom::Vector3d.new(-1, 0, 0)
               else Geom::Vector3d.new(0, 1, 0)
               end
      refs.each { |ref| ref[:face].set_attribute(DICT, 'grain_vector', [vector.x, vector.y, vector.z]) }
      UI.messagebox('Направление ворса сохранено для выбранных граней.') if show_message
    end

    def build_surface_panels(face_refs)
      explicit = {}
      fallback = []
      face_refs.each do |ref|
        part_id = ref[:face].get_attribute(DICT, 'part_id')
        if part_id
          explicit[part_id] ||= []
          explicit[part_id] << ref
        else
          fallback << ref
        end
      end

      groups = []
      explicit.values.each { |refs| groups.concat(connected_face_groups(refs)) }
      groups.concat(connected_face_groups(fallback))
      groups.each_with_index.map { |group, index| panel_from_face_group(group, index + 1) }.compact
    end

    def connected_face_groups(face_refs)
      return [] if face_refs.empty?

      edge_owners = Hash.new { |hash, key| hash[key] = [] }
      face_refs.each_with_index do |face_ref, index|
        face_edges(face_ref[:face]).each do |edge|
          next if marked?(edge, 'cut_edge')

          edge_owners[edge_key(edge, face_ref[:path])] << index
        end
      end

      neighbors = Array.new(face_refs.length) { [] }
      edge_owners.each_value do |owners|
        next if owners.length < 2

        owners.each { |owner| neighbors[owner].concat(owners.reject { |other| other == owner }) }
      end

      seen = {}
      groups = []
      face_refs.each_index do |start|
        next if seen[start]

        stack = [start]
        seen[start] = true
        group = []
        until stack.empty?
          current = stack.pop
          group << face_refs[current]
          neighbors[current].each do |neighbor|
            next if seen[neighbor]

            seen[neighbor] = true
            stack << neighbor
          end
        end
        groups << group
      end
      groups
    end

    def panel_from_face_group(face_group, index)
      points_3d = []
      face_group.each do |face_ref|
        face_ref[:face].vertices.each { |vertex| points_3d << transformed_point(vertex.position, face_ref[:transformation]) }
      end
      return nil if points_3d.length < 3

      origin = points_3d.first
      normal = averaged_normal(face_group)
      x_axis = first_loop_axis(points_3d)
      y_axis = normal * x_axis
      if y_axis.length <= 0.0001
        x_axis = Geom::Vector3d.new(1, 0, 0)
        y_axis = normal * x_axis
      end
      y_axis.normalize!
      x_axis = y_axis * normal
      x_axis.normalize!

      spread = normal_spread_degrees(face_group)
      use_unfold = spread <= AUTO_PATCH_NORMAL_SPREAD_DEGREES
      unfolded_points = use_unfold ? unfold_face_group(face_group) : nil
      boundary_loops = unfolded_points ? boundary_loops_from_unfold(face_group, unfolded_points) : boundary_loops_for_group(face_group, origin, x_axis, y_axis)
      boundary_loops = [convex_hull(points_3d.map { |point| point_to_2d(point, origin, x_axis, y_axis) })] if boundary_loops.empty?
      boundary_loops = boundary_loops.reject { |loop| loop.length < 3 }
      boundary_loops.sort_by! { |loop| -polygon_area(loop).abs }
      outer = boundary_loops.shift || []
      holes = boundary_loops
      holes_area = holes.inject(0.0) { |total, hole| total + polygon_area(hole) }
      area = polygon_area(outer) - holes_area
      grain = grain_for_group(face_group, x_axis, y_axis)
      notches = unfolded_points ? notches_from_unfold(face_group, unfolded_points) : notches_for_group(face_group, origin, x_axis, y_axis)
      cuts = unfolded_points ? cuts_from_unfold(face_group, unfolded_points) : cuts_for_group(face_group, origin, x_axis, y_axis)
      part_name = face_group.map { |ref| ref[:face].get_attribute(DICT, 'part_name') }.compact.first
      normalized = normalize_panel_geometry(outer, holes, notches, cuts, grain)
      outer = normalized[:outer]
      holes = normalized[:holes]
      notches = normalized[:notches]
      cuts = normalized[:cuts]
      grain = normalized[:grain]
      extra_warnings = []
      unless use_unfold
        extra_warnings << 'Сложная связанная поверхность оставлена одной деталью и построена проекцией. Для пошива проверьте рез/шов вручную.'
      end
      if polygon_self_intersects?(outer)
        extra_warnings << 'Развертка дала самопересечение. Деталь упрощена внешним контуром; поставьте рез/шов вручную.'
        outer = convex_hull(outer)
        holes = []
        cuts = []
      end
      holes_area = holes.inject(0.0) { |total, hole| total + polygon_area(hole) }
      area = polygon_area(outer) - holes_area
      warnings = (extra_warnings + panel_warnings(face_group, outer, holes)).uniq

      {
        id: index,
        name: part_name || "Деталь #{index}",
        face_ids: face_group.map { |face_ref| stable_entity_id(face_ref[:face]) },
        source_id: face_group.map { |face_ref| stable_entity_id(face_ref[:face]) }.join(','),
        face_count: face_group.length,
        area_mm2: area.abs.round(2),
        outer: outer,
        holes: holes,
        allowance: DEFAULT_ALLOWANCE,
        notches: notches,
        cuts: cuts,
        grain: grain,
        warnings: warnings,
        bounds: bounds_for([outer] + holes)
      }
    end

    def unfold_face_group(face_group)
      return nil if face_group.empty?

      edge_owners = Hash.new { |hash, key| hash[key] = [] }
      face_group.each_with_index do |face_ref, index|
        face_edges(face_ref[:face]).each do |edge|
          next if marked?(edge, 'cut_edge')

          edge_owners[edge_key(edge, face_ref[:path])] << index
        end
      end

      neighbors = Hash.new { |hash, key| hash[key] = [] }
      edge_owners.each do |_key, owners|
        next if owners.length < 2

        owners.each { |owner| neighbors[owner].concat(owners.reject { |other| other == owner }) }
      end

      first_vertices = transformed_face_vertices(face_group[0])
      return nil if first_vertices.length < 3

      placed_points = place_initial_face(first_vertices)
      placed_faces = { 0 => true }
      queue = [0]
      until queue.empty?
        current_index = queue.shift
        neighbors[current_index].each do |neighbor_index|
          next if placed_faces[neighbor_index]

          if place_adjacent_face(face_group[current_index], face_group[neighbor_index], placed_points)
            placed_faces[neighbor_index] = true
            queue << neighbor_index
          end
        end
      end

      min_expected = [face_group.length, 3].max
      placed_points.length >= min_expected ? placed_points : nil
    rescue StandardError
      nil
    end

    def transformed_face_vertices(face_ref)
      face_ref[:face].vertices.map { |vertex| transformed_point(vertex.position, face_ref[:transformation]) }
    end

    def place_initial_face(points)
      result = {}
      a = points[0]
      b = points[1]
      a_key = point3d_key(a)
      b_key = point3d_key(b)
      ab = a.distance(b) * MM_PER_INCH
      result[a_key] = { x: 0.0, y: 0.0 }
      result[b_key] = { x: ab, y: 0.0 }
      points[2..-1].each do |point|
        result[point3d_key(point)] = trilaterate(result[a_key], result[b_key], a.distance(point) * MM_PER_INCH, b.distance(point) * MM_PER_INCH, 1)
      end
      result
    end

    def place_adjacent_face(current_ref, neighbor_ref, placed_points)
      current_vertices = transformed_face_vertices(current_ref)
      neighbor_vertices = transformed_face_vertices(neighbor_ref)
      shared = neighbor_vertices.select { |point| placed_points.key?(point3d_key(point)) }
      return false if shared.length < 2

      a = shared[0]
      b = shared[1]
      a2 = placed_points[point3d_key(a)]
      b2 = placed_points[point3d_key(b)]
      current_known = current_vertices.map { |point| placed_points[point3d_key(point)] }.compact
      current_center = center_2d(current_known)
      side = cross2(a2, b2, current_center) >= 0 ? -1 : 1

      neighbor_vertices.each do |point|
        key = point3d_key(point)
        next if placed_points[key]

        placed_points[key] = trilaterate(a2, b2, a.distance(point) * MM_PER_INCH, b.distance(point) * MM_PER_INCH, side)
      end
      true
    end

    def trilaterate(a, b, da, db, side)
      dx = b[:x] - a[:x]
      dy = b[:y] - a[:y]
      length = Math.sqrt((dx * dx) + (dy * dy))
      return { x: a[:x], y: a[:y] } if length <= 0.0001

      x = ((da * da) - (db * db) + (length * length)) / (2.0 * length)
      h2 = (da * da) - (x * x)
      h = Math.sqrt([h2, 0.0].max) * side
      ux = dx / length
      uy = dy / length
      { x: a[:x] + (ux * x) - (uy * h), y: a[:y] + (uy * x) + (ux * h) }
    end

    def center_2d(points)
      return { x: 0, y: 0 } if points.empty?

      { x: points.inject(0.0) { |sum, point| sum + point[:x] } / points.length, y: points.inject(0.0) { |sum, point| sum + point[:y] } / points.length }
    end

    def boundary_loops_from_unfold(face_group, unfolded_points)
      edge_owners = Hash.new { |hash, key| hash[key] = [] }
      face_group.each do |face_ref|
        face_edges(face_ref[:face]).each { |edge| edge_owners[edge_key(edge, face_ref[:path])] << face_ref }
      end

      segments = []
      face_group.each do |face_ref|
        face_edges(face_ref[:face]).each do |edge|
          next if marked?(edge, 'notch')

          owners = edge_owners[edge_key(edge, face_ref[:path])]
          next unless owners.length == 1 || marked?(edge, 'cut_edge')

          a_key = point3d_key(transformed_point(edge.start.position, face_ref[:transformation]))
          b_key = point3d_key(transformed_point(edge.end.position, face_ref[:transformation]))
          next unless unfolded_points[a_key] && unfolded_points[b_key]

          segments << { a_key: a_key, b_key: b_key, a: unfolded_points[a_key], b: unfolded_points[b_key] }
        end
      end
      ordered_loops_from_segments(segments)
    end

    def notches_from_unfold(face_group, unfolded_points)
      notches = []
      face_group.each do |face_ref|
        face_edges(face_ref[:face]).each do |edge|
          next unless marked?(edge, 'notch')

          a_key = point3d_key(transformed_point(edge.start.position, face_ref[:transformation]))
          b_key = point3d_key(transformed_point(edge.end.position, face_ref[:transformation]))
          next unless unfolded_points[a_key] && unfolded_points[b_key]

          notches << [unfolded_points[a_key], unfolded_points[b_key]]
        end
      end
      unique_segments(notches)
    end

    def cuts_from_unfold(face_group, unfolded_points)
      cuts = []
      face_group.each do |face_ref|
        face_edges(face_ref[:face]).each do |edge|
          next unless marked?(edge, 'cut_edge')

          a_key = point3d_key(transformed_point(edge.start.position, face_ref[:transformation]))
          b_key = point3d_key(transformed_point(edge.end.position, face_ref[:transformation]))
          cuts << [unfolded_points[a_key], unfolded_points[b_key]] if unfolded_points[a_key] && unfolded_points[b_key]
        end
      end
      cuts
    end

    def face_edges(face)
      face.respond_to?(:edges) ? face.edges : face.loops.flat_map(&:edges)
    end

    def edge_key(edge, path)
      "#{path}/edge#{stable_entity_id(edge)}"
    end

    def averaged_normal(face_group)
      x = 0.0
      y = 0.0
      z = 0.0
      face_group.each do |face_ref|
        points = face_ref[:face].outer_loop.vertices.map { |vertex| transformed_point(vertex.position, face_ref[:transformation]) }
        next if points.length < 3

        face_normal = normal_from_points(points)
        x += face_normal.x
        y += face_normal.y
        z += face_normal.z
      end
      normal = Geom::Vector3d.new(x, y, z)
      if normal.length <= 0.0001
        normal = normal_from_points(face_group.first[:face].outer_loop.vertices.map { |vertex| transformed_point(vertex.position, face_group.first[:transformation]) })
      else
        normal.normalize!
      end
      normal
    end

    def boundary_loops_for_group(face_group, origin, x_axis, y_axis)
      edge_owners = Hash.new { |hash, key| hash[key] = [] }
      face_group.each do |face_ref|
        face_edges(face_ref[:face]).each { |edge| edge_owners[edge_key(edge, face_ref[:path])] << face_ref }
      end

      segments = []
      face_group.each do |face_ref|
        face_edges(face_ref[:face]).each do |edge|
          next if marked?(edge, 'notch')

          owners = edge_owners[edge_key(edge, face_ref[:path])]
          next unless owners.length == 1 || marked?(edge, 'cut_edge')

          start_point = transformed_point(edge.start.position, face_ref[:transformation])
          end_point = transformed_point(edge.end.position, face_ref[:transformation])
          segments << {
            a_key: point3d_key(start_point),
            b_key: point3d_key(end_point),
            a: point_to_2d(start_point, origin, x_axis, y_axis),
            b: point_to_2d(end_point, origin, x_axis, y_axis)
          }
        end
      end
      ordered_loops_from_segments(segments)
    end

    def notches_for_group(face_group, origin, x_axis, y_axis)
      notches = []
      face_group.each do |face_ref|
        face_edges(face_ref[:face]).each do |edge|
          next unless marked?(edge, 'notch')

          start_point = transformed_point(edge.start.position, face_ref[:transformation])
          end_point = transformed_point(edge.end.position, face_ref[:transformation])
          notches << [point_to_2d(start_point, origin, x_axis, y_axis), point_to_2d(end_point, origin, x_axis, y_axis)]
        end
      end
      unique_segments(notches)
    end

    def cuts_for_group(face_group, origin, x_axis, y_axis)
      cuts = []
      face_group.each do |face_ref|
        face_edges(face_ref[:face]).each do |edge|
          next unless marked?(edge, 'cut_edge')

          start_point = transformed_point(edge.start.position, face_ref[:transformation])
          end_point = transformed_point(edge.end.position, face_ref[:transformation])
          cuts << [point_to_2d(start_point, origin, x_axis, y_axis), point_to_2d(end_point, origin, x_axis, y_axis)]
        end
      end
      cuts
    end

    def panel_warnings(face_group, outer, holes)
      warnings = []
      spread = normal_spread_degrees(face_group)
      if spread > AUTO_PATCH_NORMAL_SPREAD_DEGREES
        warnings << "Разброс плоскостей #{spread.round(1)}°. Нужен технологический рез или шов."
      end
      if face_group.length >= AUTO_COMPLEX_SURFACE_FACE_COUNT && spread > 12.0
        warnings << 'Сложная криволинейная зона. Проверьте вытачки/надрезы перед раскроем.'
      end
      if polygon_self_intersects?(outer)
        warnings << 'Контур самопересекается. Поверхность нельзя раскроить одной деталью.'
      end
      holes.each do |hole|
        if polygon_self_intersects?(hole)
          warnings << 'Внутренний контур самопересекается. Проверьте резы.'
          break
        end
      end
      warnings
    end

    def normal_spread_degrees(face_group)
      normals = face_group.map { |face_ref| face_ref_normal(face_ref) }.compact
      return 0.0 if normals.length < 2

      max_angle = 0.0
      normals.each_with_index do |normal, index|
        ((index + 1)...normals.length).each do |other_index|
          max_angle = [max_angle, vector_angle_degrees(normal, normals[other_index])].max
        end
      end
      max_angle
    end

    def face_ref_normal(face_ref)
      points = face_ref[:face].outer_loop.vertices.map { |vertex| transformed_point(vertex.position, face_ref[:transformation]) }
      normal_from_points(points)
    rescue StandardError
      nil
    end

    def vector_angle_degrees(a, b)
      return 0.0 unless a && b && a.length > 0.0001 && b.length > 0.0001

      aa = a.clone
      bb = b.clone
      aa.normalize!
      bb.normalize!
      dot = [[aa.dot(bb).abs, -1.0].max, 1.0].min
      Math.acos(dot) * 180.0 / Math::PI
    end

    def grain_for_group(face_group, x_axis, y_axis)
      vector = nil
      face_group.each do |face_ref|
        raw = face_ref[:face].get_attribute(DICT, 'grain_vector')
        if raw && raw.length == 3
          vector = Geom::Vector3d.new(raw[0].to_f, raw[1].to_f, raw[2].to_f)
          break
        end
      end
      return { set: false, x: 0, y: 1 } unless vector && vector.length > 0.0001

      vector.normalize!
      gx = vector.dot(x_axis)
      gy = vector.dot(y_axis)
      length = Math.sqrt((gx * gx) + (gy * gy))
      return { set: false, x: 0, y: 1 } if length <= 0.0001

      { set: true, x: (gx / length).round(4), y: (gy / length).round(4) }
    end

    def normalize_panel_geometry(outer, holes, notches, cuts, grain)
      return { outer: outer, holes: holes, notches: notches, cuts: cuts, grain: grain } if outer.length < 2

      angle = dominant_edge_angle(outer)
      cos = Math.cos(-angle)
      sin = Math.sin(-angle)
      rotate = lambda { |point| { x: (point[:x] * cos) - (point[:y] * sin), y: (point[:x] * sin) + (point[:y] * cos) } }

      rotated_outer = outer.map { |point| rotate.call(point) }
      rotated_holes = holes.map { |loop| loop.map { |point| rotate.call(point) } }
      rotated_notches = notches.map do |notch|
        notch.is_a?(Array) ? notch.map { |point| rotate.call(point) } : [rotate.call(notch)]
      end
      rotated_cuts = cuts.map { |cut| cut.map { |point| rotate.call(point) } }
      all_loops = [rotated_outer] + rotated_holes + rotated_cuts
      all_loops << rotated_notches unless rotated_notches.empty?
      box = bounds_for(all_loops)
      shift = lambda { |point| { x: (point[:x] - box[:min_x]).round(3), y: (point[:y] - box[:min_y]).round(3) } }

      normalized_grain = grain
      if grain[:set]
        gx = (grain[:x] * cos) - (grain[:y] * sin)
        gy = (grain[:x] * sin) + (grain[:y] * cos)
        length = Math.sqrt((gx * gx) + (gy * gy))
        normalized_grain = length > 0.0001 ? { set: true, x: (gx / length).round(4), y: (gy / length).round(4) } : grain
      end

      {
        outer: rotated_outer.map { |point| shift.call(point) },
        holes: rotated_holes.map { |loop| loop.map { |point| shift.call(point) } },
        notches: rotated_notches.map { |notch| notch.map { |point| shift.call(point) } },
        cuts: rotated_cuts.map { |cut| cut.map { |point| shift.call(point) } },
        grain: normalized_grain
      }
    end

    def dominant_edge_angle(points)
      longest = nil
      points.each_with_index do |point, index|
        other = points[(index + 1) % points.length]
        dx = other[:x] - point[:x]
        dy = other[:y] - point[:y]
        length = Math.sqrt((dx * dx) + (dy * dy))
        longest = { dx: dx, dy: dy, length: length } if !longest || length > longest[:length]
      end
      return 0.0 unless longest && longest[:length] > 0.0001

      Math.atan2(longest[:dy], longest[:dx])
    end

    def polygon_self_intersects?(points)
      return false if points.length < 4

      points.each_with_index do |a1, index|
        a2 = points[(index + 1) % points.length]
        points.each_with_index do |b1, other_index|
          next if (index - other_index).abs <= 1
          next if index.zero? && other_index == points.length - 1
          next if other_index.zero? && index == points.length - 1
          next if other_index <= index

          b2 = points[(other_index + 1) % points.length]
          return true if segments_intersect?(a1, a2, b1, b2)
        end
      end
      false
    end

    def segments_intersect?(a1, a2, b1, b2)
      d1 = cross2(a1, a2, b1)
      d2 = cross2(a1, a2, b2)
      d3 = cross2(b1, b2, a1)
      d4 = cross2(b1, b2, a2)
      return false if [d1, d2, d3, d4].any? { |value| value.abs < 0.001 }

      (d1.positive? != d2.positive?) && (d3.positive? != d4.positive?)
    end

    def ordered_loops_from_segments(segments)
      adjacency = Hash.new { |hash, key| hash[key] = [] }
      segments.each_with_index do |segment, index|
        adjacency[segment[:a_key]] << index
        adjacency[segment[:b_key]] << index
      end

      used = {}
      loops = []
      segments.each_with_index do |segment, index|
        next if used[index]

        used[index] = true
        start_key = segment[:a_key]
        current_key = segment[:b_key]
        points = [segment[:a], segment[:b]]
        guard = 0
        while current_key != start_key && guard < segments.length + 5
          guard += 1
          next_index = adjacency[current_key].find { |candidate| !used[candidate] }
          break unless next_index

          used[next_index] = true
          next_segment = segments[next_index]
          if next_segment[:a_key] == current_key
            current_key = next_segment[:b_key]
            points << next_segment[:b]
          else
            current_key = next_segment[:a_key]
            points << next_segment[:a]
          end
        end
        points.pop if points.length > 1 && point2d_key(points.first) == point2d_key(points.last)
        loops << simplify_polyline(points)
      end
      loops
    end

    def create_layout_in_model(layout)
      payload = current_payload
      panels_by_id = {}
      payload[:panels].each { |panel| panels_by_id[panel[:id].to_i] = panel }
      settings = layout['settings'] || {}
      allowance_mm = settings['allowance_mm'].to_f
      fabric_width_mm = settings['fabric_width_mm'].to_f
      fabric_height_mm = settings['fabric_height_mm'].to_f
      placements = layout['placements'] || []

      model = Sketchup.active_model
      model.start_operation('Create Lekalo Cutting Pattern', true)
      group = model.active_entities.add_group
      group.name = 'Лекало для раскроя ткани'
      entities = group.entities
      draw_rectangle(entities, 0, 0, fabric_width_mm, fabric_height_mm, 'fabric')

      placements.each do |placement|
        panel = panels_by_id[placement['id'].to_i]
        next unless panel

        transform = placement_transform(placement)
        draw_loop(entities, offset_polygon(panel[:outer], allowance_mm), transform, 'allowance')
        draw_loop(entities, panel[:outer], transform, 'panel')
        panel[:holes].each { |hole| draw_loop(entities, hole, transform, 'hole') }
        panel[:cuts].each { |cut| draw_open_polyline(entities, cut, transform, 'cut') }
        panel[:notches].each { |notch| draw_notch(entities, notch, transform) }
        label_point = transform_point({ x: panel[:bounds][:min_x], y: panel[:bounds][:min_y] }, transform)
        add_label(entities, panel[:name], label_point[:x], label_point[:y])
      end

      model.commit_operation
      UI.messagebox('Геометрия лекала создана в модели.')
    rescue StandardError => error
      model.abort_operation if model
      UI.messagebox("Не удалось создать геометрию лекала:\n#{error.class}: #{error.message}")
    end

    def pack_panels(panels, allowance_mm, fabric_width_mm, gap_mm, edge_margin_mm)
      x = edge_margin_mm
      y = edge_margin_mm
      row_height = 0
      panels.map do |panel|
        allowed = offset_polygon(panel[:outer], allowance_mm)
        box = bounds_for([allowed] + panel[:holes])
        width = box[:max_x] - box[:min_x]
        height = box[:max_y] - box[:min_y]
        if x + width + edge_margin_mm > fabric_width_mm && x > edge_margin_mm
          x = edge_margin_mm
          y += row_height + gap_mm
          row_height = 0
        end
        placement = { panel: panel, x: x - box[:min_x], y: y - box[:min_y], width: width, height: height }
        x += width + gap_mm
        row_height = [row_height, height].max
        placement
      end
    end

    def offset_polygon(points, distance)
      return points.map(&:dup) if points.length < 3 || distance <= 0

      orientation = polygon_area(points) >= 0 ? 1 : -1
      points.each_with_index.each_with_object([]) do |(current, index), result|
        previous = points[(index - 1) % points.length]
        following = points[(index + 1) % points.length]
        previous_line = offset_line(previous, current, distance, orientation)
        next_line = offset_line(current, following, distance, orientation)
        intersection = line_intersection(previous_line[0], previous_line[1], next_line[0], next_line[1])
        miter_length = intersection ? point_distance(intersection, current) : Float::INFINITY
        if !intersection || miter_length > distance * 8
          result << previous_line[1]
          result << next_line[0]
        else
          result << intersection
        end
      end
    end

    def offset_line(start_point, end_point, distance, orientation)
      dx = end_point[:x] - start_point[:x]
      dy = end_point[:y] - start_point[:y]
      length = Math.sqrt((dx * dx) + (dy * dy))
      length = 1.0 if length <= 0.0001
      nx = orientation.positive? ? dy / length : -dy / length
      ny = orientation.positive? ? -dx / length : dx / length
      [
        { x: start_point[:x] + (nx * distance), y: start_point[:y] + (ny * distance) },
        { x: end_point[:x] + (nx * distance), y: end_point[:y] + (ny * distance) }
      ]
    end

    def line_intersection(a, b, c, d)
      denominator = ((a[:x] - b[:x]) * (c[:y] - d[:y])) - ((a[:y] - b[:y]) * (c[:x] - d[:x]))
      return nil if denominator.abs < 0.000001

      first = (a[:x] * b[:y]) - (a[:y] * b[:x])
      second = (c[:x] * d[:y]) - (c[:y] * d[:x])
      {
        x: ((first * (c[:x] - d[:x])) - ((a[:x] - b[:x]) * second)) / denominator,
        y: ((first * (c[:y] - d[:y])) - ((a[:y] - b[:y]) * second)) / denominator
      }
    end

    def point_distance(first, second)
      dx = first[:x] - second[:x]
      dy = first[:y] - second[:y]
      Math.sqrt((dx * dx) + (dy * dy))
    end

    def placement_transform(placement)
      { x: placement['x'].to_f, y: placement['y'].to_f, rotation: placement['rotation'].to_f * Math::PI / 180.0 }
    end

    def transform_point(point, transform)
      cos = Math.cos(transform[:rotation])
      sin = Math.sin(transform[:rotation])
      { x: (point[:x] * cos) - (point[:y] * sin) + transform[:x], y: (point[:x] * sin) + (point[:y] * cos) + transform[:y] }
    end

    def draw_loop(entities, points, transform, tag)
      return if points.length < 2

      sketchup_points = points.map { |point| point_to_sketchup(transform_point(point, transform)) }
      sketchup_points.each_with_index do |point, index|
        edge = entities.add_line(point, sketchup_points[(index + 1) % sketchup_points.length])
        edge.set_attribute(DICT, 'type', tag)
      end
    end

    def draw_open_polyline(entities, points, transform, tag)
      return if points.length < 2

      sketchup_points = points.map { |point| point_to_sketchup(transform_point(point, transform)) }
      (0...(sketchup_points.length - 1)).each do |index|
        edge = entities.add_line(sketchup_points[index], sketchup_points[index + 1])
        edge.set_attribute(DICT, 'type', tag)
      end
    end

    def draw_notch(entities, notch, transform)
      points = notch.is_a?(Array) ? notch : [notch, { x: notch[:x], y: notch[:y] + 6 }]
      draw_open_polyline(entities, points, transform, 'notch')
    end

    def draw_rectangle(entities, x, y, width, height, tag)
      draw_loop(entities, [{ x: x, y: y }, { x: x + width, y: y }, { x: x + width, y: y + height }, { x: x, y: y + height }], { x: 0, y: 0, rotation: 0 }, tag)
    end

    def point_to_sketchup(point)
      Geom::Point3d.new(point[:x] * INCH_PER_MM, point[:y] * INCH_PER_MM, 0)
    end

    def add_label(entities, text, x_mm, y_mm)
      entities.add_text(text, Geom::Point3d.new(x_mm * INCH_PER_MM, y_mm * INCH_PER_MM, 0))
    rescue StandardError
      nil
    end

    def marked?(entity, key)
      value = entity.get_attribute(DICT, key)
      value == true || value.to_s == 'true'
    end

    def delete_attr(entity, key)
      entity.delete_attribute(DICT, key)
    rescue StandardError
      entity.set_attribute(DICT, key, nil)
    end

    def transformed_point(point, transformation)
      point.transform(transformation)
    end

    def stable_entity_id(entity)
      entity.respond_to?(:persistent_id) ? entity.persistent_id : entity.entityID
    end

    def normal_from_points(points)
      return Geom::Vector3d.new(0, 0, 1) if points.length < 3

      origin = points[0]
      (1...(points.length - 1)).each do |index|
        a = origin.vector_to(points[index])
        b = origin.vector_to(points[index + 1])
        normal = a * b
        next unless normal.length > 0.0001

        normal.normalize!
        return normal
      end
      Geom::Vector3d.new(0, 0, 1)
    end

    def first_loop_axis(points)
      points.each_with_index do |point, index|
        vector = point.vector_to(points[(index + 1) % points.length])
        next unless vector.length > 0.0001

        vector.normalize!
        return vector
      end
      Geom::Vector3d.new(1, 0, 0)
    end

    def point_to_2d(point, origin, x_axis, y_axis)
      vector = origin.vector_to(point)
      { x: (vector.dot(x_axis) * MM_PER_INCH).round(3), y: (vector.dot(y_axis) * MM_PER_INCH).round(3) }
    end

    def point3d_key(point)
      [(point.x * 10_000).round, (point.y * 10_000).round, (point.z * 10_000).round].join(',')
    end

    def point2d_key(point)
      [(point[:x] * 1000).round, (point[:y] * 1000).round].join(',')
    end

    def unique_points(points)
      unique = {}
      points.each { |point| unique[point2d_key(point)] = point }
      unique.values
    end

    def unique_segments(segments)
      unique = {}
      segments.each do |segment|
        next unless segment.is_a?(Array) && segment.length >= 2

        key = segment.first(2).map { |point| point2d_key(point) }.sort.join('|')
        unique[key] = segment.first(2)
      end
      unique.values
    end

    def simplify_polyline(points)
      return points if points.length < 4

      simplified = []
      points.each_with_index do |point, index|
        previous_point = points[(index - 1) % points.length]
        next_point = points[(index + 1) % points.length]
        area = ((point[:x] - previous_point[:x]) * (next_point[:y] - previous_point[:y])) -
               ((point[:y] - previous_point[:y]) * (next_point[:x] - previous_point[:x]))
        next if area.abs < 0.01

        simplified << point
      end
      simplified.length >= 3 ? simplified : points
    end

    def convex_hull(points)
      unique = {}
      points.each { |point| unique[point2d_key(point)] = point }
      sorted = unique.values.sort_by { |point| [point[:x], point[:y]] }
      return sorted if sorted.length <= 3

      lower = []
      sorted.each do |point|
        lower.pop while lower.length >= 2 && cross2(lower[-2], lower[-1], point) <= 0
        lower << point
      end
      upper = []
      sorted.reverse_each do |point|
        upper.pop while upper.length >= 2 && cross2(upper[-2], upper[-1], point) <= 0
        upper << point
      end
      lower[0...-1] + upper[0...-1]
    end

    def cross2(origin, a, b)
      ((a[:x] - origin[:x]) * (b[:y] - origin[:y])) - ((a[:y] - origin[:y]) * (b[:x] - origin[:x]))
    end

    def bounds_for(loops)
      points = loops.flatten
      xs = points.map { |point| point[:x] }
      ys = points.map { |point| point[:y] }
      { min_x: xs.min || 0, min_y: ys.min || 0, max_x: xs.max || 0, max_y: ys.max || 0 }
    end

    def polygon_area(points)
      return 0.0 if points.length < 3

      sum = 0.0
      points.each_with_index do |point, index|
        next_point = points[(index + 1) % points.length]
        sum += (point[:x] * next_point[:y]) - (next_point[:x] * point[:y])
      end
      sum / 2.0
    end

    def save_text_file(title, default_name, content)
      path = UI.savepanel(title, nil, default_name)
      return unless path

      File.open(path, 'w:utf-8') { |file| file.write(content.to_s) }
    rescue StandardError => error
      UI.messagebox("Не удалось сохранить файл:\n#{error.message}")
    end
  end

  class GrainDirectionTool
    def initialize
      @points = []
      @input = Sketchup::InputPoint.new
    end

    def activate
      Sketchup.set_status_text('Укажите первую точку направления ворса.')
    end

    def onMouseMove(_flags, x, y, view)
      @input.pick(view, x, y)
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      @input.pick(view, x, y)
      return unless @input.valid?

      @points << @input.position
      if @points.length == 1
        Sketchup.set_status_text('Укажите вторую точку направления ворса.')
      else
        Main.store_grain_for_selection(@points[0], @points[1])
        Sketchup.active_model.select_tool(nil)
      end
    end

    def draw(view)
      @input.draw(view) if @input.valid?
      view.draw(GL_LINES, @points[0], @input.position) if @points.length == 1 && @input.valid?
    end
  end
end

unless file_loaded?(__FILE__)
  CodexLekaloCutting::Main.install_ui
  file_loaded(__FILE__)
end
