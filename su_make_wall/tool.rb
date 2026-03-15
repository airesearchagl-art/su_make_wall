# frozen_string_literal: true

module SuMakeWall
  # =============================================================================
  # Tool — Sketchup::Tool の実装
  #
  # 状態遷移:
  #   IDLE    : 始点待ち。左クリックで DRAWING へ。
  #   DRAWING : 終点待ち。マウス移動でプレビューを更新。
  #             左クリック or VCB 数値入力で壁を確定し連続描画を継続。
  #             右クリック / ESC で IDLE に戻る。
  #
  # Step 3: PushPull による 3D 壁の生成（WallBuilder で有効化済み）
  # Step 5: VCB（onUserText）による数値指定・矢印キーによる軸ロック
  # Step 6: UIDialog によるモードレスパラメータ設定
  # =============================================================================
  class Tool
    # ── 状態定数 ──────────────────────────────────────────────────────────────
    STATE_IDLE    = :idle
    STATE_DRAWING = :drawing

    # ── 初期化 ────────────────────────────────────────────────────────────────

    def initialize(params)
      @params     = params
      @state      = STATE_IDLE
      @start_pt   = nil   # Geom::Point3d — 確定した始点
      @end_pt     = nil   # Geom::Point3d — マウス追従中の仮終点
      @ip_start   = Sketchup::InputPoint.new
      @ip_end     = Sketchup::InputPoint.new
      @lock_dir   = nil   # Geom::Vector3d または nil — 軸ロック中の方向
      @vcb_length = nil   # Float または nil — 最後の VCB 入力値（内部単位）
    end

    # ── Sketchup::Tool コールバック（公開） ───────────────────────────────────

    def activate
      # UIDialog を表示（または前面に移動）し、@params オブジェクトを紐づける。
      # Tool と UIDialog は同じ Parameters インスタンスを共有するため、
      # ダイアログでの変更は次の draw() 呼び出しに即座に反映される。
      UIDialog.show(@params)
      update_status_bar
    end

    def deactivate(view)
      # ダイアログはモードレスなので閉じない。
      # ユーザーが × ボタンで閉じた場合は UIDialog 側でインスタンスをリセット済み。
      view.invalidate
    end

    def resume(view)
      update_status_bar
      view.invalidate
    end

    def suspend(view)
      view.invalidate
    end

    # 左クリック: 始点記録 / 壁確定（連続描画）
    def onLButtonDown(_flags, x, y, view)
      @ip_end.pick(view, x, y, (@state == STATE_DRAWING ? @ip_start : nil))
      pt = @ip_end.position

      case @state
      when STATE_IDLE
        @start_pt = pt
        @ip_start.copy!(@ip_end)
        @state = STATE_DRAWING
        update_status_bar

      when STATE_DRAWING
        unless pt == @start_pt
          commit_wall(@start_pt, pt)
          # 連続描画: 終点を次の始点にする
          @start_pt = pt
          @ip_start.copy!(@ip_end)
        end
      end

      view.invalidate
    end

    # 右クリック: 連続描画を中断して IDLE へ
    def onRButtonDown(_flags, _x, _y, view)
      reset_to_idle
      view.invalidate
    end

    # マウス移動: InputPoint を更新してプレビューを再描画
    def onMouseMove(_flags, x, y, view)
      if @state == STATE_DRAWING
        @ip_end.pick(view, x, y, @ip_start)
      else
        @ip_end.pick(view, x, y)
      end

      raw_pt = @ip_end.position

      # 軸ロック中は始点を通るロック軸へ射影、それ以外はスナップ位置をそのまま使う
      if @lock_dir && @start_pt
        @end_pt = raw_pt.project_to_line([@start_pt, @lock_dir])
      else
        @end_pt = raw_pt
      end

      view.tooltip = @ip_end.tooltip
      view.invalidate
    end

    # キー入力: ESC でキャンセル、矢印キーで軸ロック
    # return true でキーイベントを消費し SketchUp のデフォルト動作を抑制する。
    def onKeyDown(key, _repeat, _flags, view)
      case key
      when VK_ESCAPE
        if @state == STATE_DRAWING
          reset_to_idle
        else
          Sketchup.active_model.select_tool(nil)
        end
        view.invalidate
        return true

      when VK_RIGHT
        # 赤軸（X 軸）にロック
        @lock_dir = X_AXIS
        update_status_bar
        view.invalidate
        return true

      when VK_LEFT
        # 緑軸（Y 軸）にロック
        @lock_dir = Y_AXIS
        update_status_bar
        view.invalidate
        return true

      when VK_UP
        # 青軸（Z 軸）にロック（壁ツールでは稀だが完全性のため対応）
        @lock_dir = Z_AXIS
        update_status_bar
        view.invalidate
        return true

      when VK_DOWN
        # 軸ロック解除
        @lock_dir = nil
        update_status_bar
        view.invalidate
        return true
      end
    end

    # ESC キー / ツール切替 / Undo で SketchUp フレームワークから呼ばれるコールバック。
    # onKeyDown の ESC 処理と論理的に同等だが、version によってどちらか一方のみ呼ばれる。
    # 二重呼び出しになっても reset_to_idle は冪等なので問題ない。
    #
    #   reason 0 : ESC キー押下
    #   reason 1 : 別のツールが選択された（切替直前）
    #   reason 2 : Undo 操作
    def onCancel(reason, view)
      case reason
      when 0
        # ESC: onKeyDown と同じロジック
        if @state == STATE_DRAWING
          reset_to_idle
        else
          Sketchup.active_model.select_tool(nil)
        end
      else
        # ツール切替 / Undo: 状態のリセットのみ（ツール終了は呼び出し元が担う）
        reset_to_idle
      end
      view.invalidate
    end

    # VCB（右下の寸法入力欄）にユーザーが数値を入力して Enter を押したときに呼ばれる。
    # フォーマット: "3000"（mm）/ "3000mm" / "3.0m"
    # DRAWING 状態かつ始点が確定済みのときのみ処理する。
    def onUserText(text, view)
      return unless @state == STATE_DRAWING && @start_pt

      distance_mm = parse_vcb_input(text)
      unless distance_mm && distance_mm > 0
        UI.beep
        Sketchup.status_text = 'MakeWall: 有効な距離を入力してください（例: 3000 / 3000mm / 3.0m）'
        return
      end

      # ── 方向ベクトルの決定（軸ロック優先 → 現在マウス方向） ────────────────
      dir = if @lock_dir
              @lock_dir
            elsif @end_pt && @end_pt != @start_pt
              v = Geom::Vector3d.new(@end_pt.x - @start_pt.x,
                                     @end_pt.y - @start_pt.y,
                                     0.0)
              if v.length < Constants::MIN_WALL_LENGTH
                UI.beep
                Sketchup.status_text = 'MakeWall: まずマウスで方向を指定してください。'
                return
              end
              v.normalize
            else
              UI.beep
              Sketchup.status_text = 'MakeWall: まずマウスで方向を指定してください。'
              return
            end

      # ── 終点を計算して壁を確定 ───────────────────────────────────────────────
      @vcb_length  = distance_mm.mm
      computed_end = @start_pt.offset(dir, @vcb_length)

      commit_wall(@start_pt, computed_end)

      # 連続描画: 確定した終点を次の始点にする
      @start_pt = computed_end
      @ip_start = Sketchup::InputPoint.new(computed_end)
      @end_pt   = computed_end

      update_status_bar
      view.invalidate
    end

    # プレビュー描画（毎フレーム呼ばれる。モデルを変更してはいけない）
    def draw(view)
      @ip_end.draw(view) if @ip_end.valid?
      draw_preview(view) if @state == STATE_DRAWING && @start_pt && @end_pt
    end

    # draw() が描画するジオメトリの包含ボックス（カメラ自動フィット用）
    def getExtents
      bb = Geom::BoundingBox.new
      bb.add(@start_pt) if @start_pt
      bb.add(@end_pt)   if @end_pt
      bb
    end

    # VCB を有効化（onUserText を実装済み）
    def enableVCB?
      true
    end

    private

    # ── 壁の確定 ──────────────────────────────────────────────────────────────

    def commit_wall(pt1, pt2)
      group = WallBuilder.new(@params).build(pt1, pt2)
      Sketchup.status_text = '壁の長さが短すぎます。別の点をクリックしてください。' if group.nil?
      group
    end

    # ── プレビュー描画 ─────────────────────────────────────────────────────────

    def draw_preview(view)
      data = WallBuilder.preview_vertices(@start_pt, @end_pt, @params)

      # 壁のワイヤーフレーム（始点と終点が有効なときのみ）
      if data
        bottom = data[:bottom]
        top    = data[:top]

        view.line_width    = Constants::PREVIEW_LINE_WIDTH
        view.drawing_color = Constants::PREVIEW_COLOR

        view.draw(GL_LINE_LOOP, bottom)
        view.draw(GL_LINE_LOOP, top)

        vertical_edges = bottom.each_with_index.flat_map { |bp, i| [bp, top[i]] }
        view.draw(GL_LINES, vertical_edges)
      end

      # 軸ロック中: ロック方向の延長線を軸の色で描画する
      draw_lock_axis(view) if @lock_dir && @start_pt

      # ── Step 4 で追加: コーナー端部の赤ハイライト ──────────────────────────
      # draw_trim_highlight(view, data[:bottom], data[:top]) if @prev_dir && data
    end

    # 軸ロック中の延長線を軸色で描く
    def draw_lock_axis(view)
      axis_color = case @lock_dir
                   when X_AXIS then Sketchup::Color.new(255, 0, 0)    # 赤軸
                   when Y_AXIS then Sketchup::Color.new(0, 128, 0)    # 緑軸
                   when Z_AXIS then Sketchup::Color.new(0, 0, 255)    # 青軸
                   else Constants::PREVIEW_COLOR
                   end

      # 延長線の終点: 現在の終点をロック軸に射影、なければ 1m 先
      far_pt = if @end_pt && @end_pt != @start_pt
                 @end_pt.project_to_line([@start_pt, @lock_dir])
               else
                 @start_pt.offset(@lock_dir, 1000.mm)
               end

      view.line_width    = 1
      view.drawing_color = axis_color
      view.draw(GL_LINES, [@start_pt, far_pt])
    end

    # ── VCB 入力パース ─────────────────────────────────────────────────────────

    # テキストを Float（mm 値）に変換する。パース失敗時は nil を返す。
    # "mm" を先に評価することで "m"（メートル）との誤マッチを防ぐ。
    # 対応フォーマット:
    #   "3000"     → 3000.0 mm
    #   "3000mm"   → 3000.0 mm
    #   "3.0m"     → 3000.0 mm（メートル換算）
    def parse_vcb_input(text)
      s = text.to_s.strip.downcase
      case s
      when /\A([0-9]*\.?[0-9]+)\s*mm\z/ then $1.to_f             # "3000mm"
      when /\A([0-9]*\.?[0-9]+)\s*m\z/  then $1.to_f * 1000.0   # "3.0m"
      when /\A([0-9]*\.?[0-9]+)\z/       then $1.to_f             # "3000"
      # マッチなし → nil（= パース失敗）
      end
    end

    # ── ユーティリティ ─────────────────────────────────────────────────────────

    def reset_to_idle
      @state      = STATE_IDLE
      @start_pt   = nil
      @end_pt     = nil
      @lock_dir   = nil
      @vcb_length = nil
      update_status_bar
    end

    def update_status_bar
      case @state
      when STATE_IDLE
        Sketchup.status_text = "MakeWall: 始点をクリックしてください  | #{@params}"

      when STATE_DRAWING
        lock_hint = if @lock_dir
                      axis_name = { X_AXIS => '赤軸', Y_AXIS => '緑軸', Z_AXIS => '青軸' }
                                  .fetch(@lock_dir, '軸')
                      "【#{axis_name}ロック中】 "
                    else
                      ''
                    end
        Sketchup.status_text =
          "MakeWall: #{lock_hint}終点クリック または 距離入力 " \
          '| →赤軸 ←緑軸 ↑青軸 ↓解除 | 右クリック: リセット | ESC: 終了'
      end
    end
  end
end
