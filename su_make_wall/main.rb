# frozen_string_literal: true

# =============================================================================
# main.rb — MakeWall Extension の初期化エントリーポイント
#
# su_make_wall.rb（ローダー）から SketchupExtension 経由でロードされる。
# サブファイルの読み込み、UI::Command 作成、メニュー・コンテキストメニュー・
# ツールバーの登録を行う。
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

  # ── UI::Command・メニュー・ツールバーの登録 ─────────────────────────────────
  # `unless @menus_registered` で二重登録を防ぐ（reload 対策）。

  unless @menus_registered
    # ── 1. UI::Command ────────────────────────────────────────────────────────
    # メニュー、コンテキストメニュー、ツールバーの呼び出しを一本化する。
    cmd = UI::Command.new('MakeWall') { SuMakeWall.activate_tool }

    cmd.tooltip         = 'MakeWall: 連続壁作成'
    cmd.status_bar_text = 'クリックして連続壁描画ツールを起動します'
    cmd.menu_text       = 'MakeWall'

    # ── 2. アイコン ────────────────────────────────────────────────────────────
    icon_path = File.join(__dir__, 'icons', 'makewall.png')
    if File.exist?(icon_path)
      cmd.small_icon = icon_path
      cmd.large_icon = icon_path
    end

    # ── 3. Plugins メニュー ───────────────────────────────────────────────────
    UI.menu('Plugins').add_item(cmd)

    # ── 4. 右クリック コンテキストメニュー ───────────────────────────────────
    UI.add_context_menu_handler do |context_menu|
      context_menu.add_separator
      context_menu.add_item(cmd)
    end

    # ── 5. ツールバー ─────────────────────────────────────────────────────────
    toolbar = UI::Toolbar.new('MakeWall')
    toolbar.add_item(cmd)
    # restore: 前回の表示状態を復元。初回は非表示のため show を呼ぶ。
    toolbar.restore
    UI.start_timer(0.1, false) { toolbar.show } unless toolbar.get_last_state == TB_VISIBLE

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
