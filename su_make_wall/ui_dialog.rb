# frozen_string_literal: true

module SuMakeWall
  # =============================================================================
  # UIDialog — HtmlDialog ラッパー（Step 6）
  #
  # シングルトン管理:
  #   UIDialog.show(params) でダイアログを開く（既に表示中なら前面に移動）。
  #   ユーザーが × で閉じると @instance が nil にリセットされ、
  #   次回 show 時に新しいインスタンスが作られる。
  #
  # Ruby ↔ JS の連携フロー:
  #   1. show(params) → @dialog.show → HTML ロード開始
  #   2. JS の最終行が sketchup.ready() を呼ぶ
  #   3. 'ready' コールバック → push_to_html で初期値を JS へ送信
  #   4. ユーザーが値を変更 → JS が sketchup.update_param(key, value) を呼ぶ
  #   5. 'update_param' コールバック → @params を更新 → view.invalidate
  #   6. Tool#draw が @params を参照してプレビューを再描画
  # =============================================================================
  class UIDialog
    # HTML ファイルの絶対パス（require 時に解決）
    HTML_FILE = File.expand_path(
      File.join(File.dirname(__FILE__), 'dialogs', 'settings.html')
    ).freeze

    # ── シングルトン管理 ─────────────────────────────────────────────────────

    @instance = nil

    class << self
      attr_accessor :instance

      # params オブジェクトを渡してダイアログを表示する。
      # 既に開いている場合は前面に移動して params を更新するだけ。
      def show(params)
        if @instance.nil? || !@instance.visible?
          @instance = new          # 新規ダイアログを生成して表示
        else
          @instance.bring_to_front # 既存ウィンドウを前面へ
        end
        @instance.attach(params)
        @instance
      end
    end

    # ── インスタンスメソッド ─────────────────────────────────────────────────

    def initialize
      @params     = nil
      @html_ready = false          # JS から ready() が届いたか否か
      @dialog     = build_dialog
      setup_callbacks
      @dialog.set_file(HTML_FILE)
      @dialog.show
    end

    def visible?
      @dialog.visible?
    end

    def bring_to_front
      @dialog.bring_to_front
    end

    # Tool が変わった（連続起動など）ときに params を付け替える。
    # HTML がロード済みなら即座に初期値を送信し、未ロードなら ready() 後に送信。
    def attach(params)
      @params = params
      push_to_html if @html_ready
    end

    private

    # ── HtmlDialog の生成 ────────────────────────────────────────────────────

    def build_dialog
      UI::HtmlDialog.new(
        dialog_title:    'MakeWall',
        preferences_key: 'SuMakeWall_Settings',  # ウィンドウ位置を永続化
        scrollable:      false,
        resizable:       true,
        width:           290,
        height:          165,
        style:           UI::HtmlDialog::STYLE_UTILITY
      )
    end

    # ── コールバックの登録 ───────────────────────────────────────────────────

    def setup_callbacks
      # JS → Ruby: HTML のロード完了通知
      # ここで push_to_html を呼ぶことで、ダイアログ表示直後に初期値が反映される。
      @dialog.add_action_callback('ready') do |_ctx|
        @html_ready = true
        push_to_html
      end

      # JS → Ruby: ユーザーがパラメータを変更した
      @dialog.add_action_callback('update_param') do |_ctx, key, raw_value|
        next unless @params

        case key
        when 'height'
          @params.set_height_mm([raw_value.to_f, 1.0].max)
        when 'thickness'
          @params.set_thickness_mm([raw_value.to_f, 1.0].max)
        when 'justification'
          @params.set_justification(raw_value)
        end

        # Tool のプレビューを即座に再描画
        # active_view は常に最新のビューを返すためモデル切替にも対応
        Sketchup.active_model.active_view.invalidate
      end

      # ダイアログを × で閉じたときにシングルトンをリセット
      @dialog.set_on_closed do
        UIDialog.instance = nil
      end
    end

    # ── Ruby → JS: 現在の params 値を HTML に送信 ───────────────────────────

    # @params の現在値を JSON にして updateFromRuby() を呼び出す。
    # execute_script は HTML ロード済み状態でのみ正常に動作するため、
    # @html_ready フラグが true のときだけ呼ぶ（setup_callbacks と attach で保証）。
    def push_to_html
      return unless @params

      h = @params.height_mm
      t = @params.thickness_mm
      j = @params.justification.to_s
      # 値はすべてサニタイズ済み（整数 + 固定文字列）なので文字列結合で安全
      json = "{\"height\":#{h},\"thickness\":#{t},\"justification\":\"#{j}\"}"
      @dialog.execute_script("updateFromRuby(#{json})")
    end
  end
end
