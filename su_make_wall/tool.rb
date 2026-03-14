# frozen_string_literal: true

module SuMakeWall
  # =============================================================================
  # Tool — Sketchup::Tool の実装
  #
  # 状態遷移:
  #   IDLE    : 始点待ち。左クリックで DRAWING へ。
  #   DRAWING : 終点待ち。マウス移動でプレビューを更新。
  #             左クリックで壁を確定し、終点を次の始点として DRAWING を継続。
  #             右クリック / ESC で IDLE に戻る。
  #
  # Step 1-2 の実装範囲:
  #   - ツールの状態機械と基本的なマウスイベント処理
  #   - InputPoint によるスナップ
  #   - 2D 底面ポリゴンの生成（WallBuilder 経由）
  #   - 3D ワイヤーフレームのリアルタイムプレビュー（draw メソッド）
  #
  # Step 3 以降で追加予定:
  #   - PushPull による高さ（face.pushpull を WallBuilder で有効化）
  #   - VCB（onUserText）による数値入力
  #   - コーナー端部の赤ハイライト（@prev_dir の導入）
  # =============================================================================
  class Tool
    # ── 状態定数 ──────────────────────────────────────────────────────────────
    STATE_IDLE    = :idle
    STATE_DRAWING = :drawing

    # ── 初期化 ────────────────────────────────────────────────────────────────

    def initialize(params)
      @params   = params
      @state    = STATE_IDLE
      @start_pt = nil            # Geom::Point3d — 確定した始点
      @end_pt   = nil            # Geom::Point3d — マウス追従中の仮終点
      @ip_start = Sketchup::InputPoint.new
      @ip_end   = Sketchup::InputPoint.new
    end

    # ── Sketchup::Tool コールバック ───────────────────────────────────────────

    def activate
      update_status_bar
    end

    def deactivate(view)
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
        # 始点を確定して DRAWING 状態へ移行
        @start_pt = pt
        @ip_start.copy!(@ip_end)
        @state = STATE_DRAWING
        update_status_bar

      when STATE_DRAWING
        # 終点が始点と同じ場合はスキップ（誤クリック防止）
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
        # @ip_start を渡すと始点からの軸推定（緑・赤・青軸ロック）が有効になる
        @ip_end.pick(view, x, y, @ip_start)
      else
        @ip_end.pick(view, x, y)
      end

      @end_pt      = @ip_end.position
      view.tooltip = @ip_end.tooltip
      view.invalidate
    end

    # キー入力: ESC でキャンセル
    def onKeyDown(key, _repeat, _flags, view)
      if key == VK_ESCAPE
        if @state == STATE_DRAWING
          # DRAWING 中は IDLE に戻るだけ（ツール自体は終了しない）
          reset_to_idle
        else
          # IDLE 状態での ESC はツールを終了
          Sketchup.active_model.select_tool(nil)
        end
        view.invalidate
      end
    end

    # プレビュー描画（毎フレーム呼ばれる。モデルを変更してはいけない）
    def draw(view)
      # InputPoint のスナップインジケーター（十字・推定ラベルなど）を描画
      @ip_end.draw(view) if @ip_end.valid?

      # DRAWING 状態のときのみ壁プレビューを描画
      draw_preview(view) if @state == STATE_DRAWING && @start_pt && @end_pt
    end

    # draw() が描画するジオメトリの包含ボックス（カメラの自動フィット用）
    def getExtents
      bb = Geom::BoundingBox.new
      bb.add(@start_pt) if @start_pt
      bb.add(@end_pt)   if @end_pt
      bb
    end

    # VCB（Value Control Box / 寸法入力欄）を有効化
    # Step 5 で onUserText を実装したときに本格利用する
    def enableVCB?
      true
    end

    private

    # ── 壁の確定 ──────────────────────────────────────────────────────────────

    def commit_wall(pt1, pt2)
      group = WallBuilder.new(@params).build(pt1, pt2)
      if group.nil?
        # 長さが短すぎる場合など — ユーザーへは status_text で通知
        Sketchup.status_text = '壁の長さが短すぎます。別の点をクリックしてください。'
      end
      group
    end

    # ── プレビュー描画 ─────────────────────────────────────────────────────────

    # ワイヤーフレームで壁の仮形状を描画する。
    # 通常は青（PREVIEW_COLOR）。
    # Step 4 以降でコーナー端部（始点側）を赤（PREVIEW_COLOR_TRIM）で描画予定。
    def draw_preview(view)
      data = WallBuilder.preview_vertices(@start_pt, @end_pt, @params)
      return unless data

      bottom = data[:bottom]
      top    = data[:top]

      view.line_width    = Constants::PREVIEW_LINE_WIDTH
      view.drawing_color = Constants::PREVIEW_COLOR

      # 底面の輪郭
      view.draw(GL_LINE_LOOP, bottom)

      # 上面の輪郭
      view.draw(GL_LINE_LOOP, top)

      # 縦方向の 4 辺（底面頂点と上面頂点を対で渡す）
      vertical_edges = bottom.each_with_index.flat_map { |bp, i| [bp, top[i]] }
      view.draw(GL_LINES, vertical_edges)

      # ── Step 4 で追加: コーナー端部の赤ハイライト ──────────────────────────
      # @prev_dir（前セグメントの方向ベクトル）が存在する場合、
      # 始点側の 2 頂点（bottom[0], bottom[3], top[0], top[3]）を赤で描画する。
      # draw_trim_highlight(view, bottom, top) if @prev_dir
    end

    # ── ユーティリティ ─────────────────────────────────────────────────────────

    def reset_to_idle
      @state    = STATE_IDLE
      @start_pt = nil
      @end_pt   = nil
      update_status_bar
    end

    def update_status_bar
      case @state
      when STATE_IDLE
        msg = "MakeWall: 始点をクリックしてください  " \
              "| #{@params}"
        Sketchup.status_text = msg
      when STATE_DRAWING
        Sketchup.status_text =
          'MakeWall: 終点をクリック（連続描画）' \
          ' | 右クリック: リセット | ESC: 終了'
      end
    end
  end
end
