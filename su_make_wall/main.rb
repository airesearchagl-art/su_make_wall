# frozen_string_literal: true

# =============================================================================
# main.rb — MakeWall Extension の初期化エントリーポイント
#
# su_make_wall.rb（ローダー）から SketchupExtension 経由でロードされる。
# サブファイルの読み込み、メニュー登録、コンテキストメニュー登録を行う。
# =============================================================================

require 'sketchup.rb'

module SuMakeWall
  # ── サブファイルの読み込み ──────────────────────────────────────────────────
  dir = File.dirname(__FILE__)
  require File.join(dir, 'constants')
  require File.join(dir, 'parameters')
  require File.join(dir, 'wall_builder')
  require File.join(dir, 'ui_dialog')   # Step 6: HtmlDialog ラッパー
  require File.join(dir, 'tool')

  # ── ツール起動 ──────────────────────────────────────────────────────────────

  # デフォルト値で Parameters を生成してツールをアクティブにする。
  # パラメータの編集は Tool#activate 内で開く HtmlDialog で行う。
  def self.activate_tool
    params = Parameters.new
    Sketchup.active_model.select_tool(Tool.new(params))
  end

  # ── メニュー & コンテキストメニューの登録 ───────────────────────────────────
  # `unless @menus_registered` で二重登録を防ぐ。

  unless @menus_registered
    # 1. 拡張機能メニュー（Plugins > MakeWall）
    plugins_menu = UI.menu('Plugins')
    plugins_menu.add_item('MakeWall') { SuMakeWall.activate_tool }

    # 2. 右クリック コンテキストメニュー
    UI.add_context_menu_handler do |context_menu|
      context_menu.add_separator
      context_menu.add_item('MakeWall') { SuMakeWall.activate_tool }
    end

    @menus_registered = true
  end

  # ── 開発用リロードヘルパー ──────────────────────────────────────────────────
  def self.reload
    dir = File.dirname(__FILE__)
    [
      File.join(dir, 'constants'),
      File.join(dir, 'parameters'),
      File.join(dir, 'wall_builder'),
      File.join(dir, 'ui_dialog'),
      File.join(dir, 'tool'),
      __FILE__
    ].each { |f| load "#{f}.rb" }
    puts '[MakeWall] reloaded.'
  end
end
