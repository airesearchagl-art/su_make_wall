# frozen_string_literal: true

module SuMakeWall
  # =============================================================================
  # WallBuilder — 壁ジオメトリの計算と生成
  #
  # Tool クラスから分離することで、ジオメトリロジックの単体テストや
  # コーナーマイター処理の追加が容易になる。
  #
  # 座標系メモ:
  #   dir    = (pt2 - pt1).normalize   # 壁の進行方向ベクトル（Z=0 に射影）
  #   normal = (-dir.y, dir.x, 0)      # 左手法線（進行方向に対して左 = +normal 方向）
  #
  # Justification とオフセット:
  #   :center → d_left = t/2,  d_right = t/2   （基準線が壁の中心）
  #   :left   → d_left = 0,    d_right = t      （基準線が壁の左端）
  #   :right  → d_left = t,    d_right = 0      （基準線が壁の右端）
  #
  # 底面4頂点（上から見て反時計回り → 法線が +Z = 上向き → pushpull が上方向）:
  #   v0 = pt1 + normal * d_left   （始点・左端）  index 0
  #   v1 = pt2 + normal * d_left   （終点・左端）  index 1
  #   v2 = pt2 - normal * d_right  （終点・右端）  index 2
  #   v3 = pt1 - normal * d_right  （始点・右端）  index 3
  #
  # Step 7 マイター処理:
  #   連続描画時、コーナー（前の壁の終点 == 今の壁の始点）で 2 本の
  #   オフセット直線の交点を求め、前の壁の終点頂点を移動させると同時に
  #   今の壁をマイター済みの始点で生成する。
  #   交点計算は line_line_intersection_2d（Cramer's rule）による。
  # =============================================================================
  class WallBuilder
    # マイター交点が厚みの何倍以上離れたらフォールバックするか（鋭角コーナー対策）
    MITER_MAX_FACTOR = 10.0
    # 交点の行列式がこれ以下なら平行と判断
    MITER_DET_EPSILON = 1e-8
    # 頂点探索の許容距離（グループ内頂点の同定用）
    VERTEX_SNAP_TOL   = 0.5.mm

    def initialize(params)
      @params = params
    end

    # ── 公開 API ───────────────────────────────────────────────────────────────

    # 四角い壁（マイターなし）をモデルに追加する。
    # @return [Sketchup::Group, nil]
    def build(pt1, pt2)
      data = vertices_hash(pt1, pt2)
      return nil unless data

      model = Sketchup.active_model
      model.start_operation('Make Wall', true)
      begin
        group = add_wall_group(data[:bottom])
        model.commit_operation
        group
      rescue => e
        model.abort_operation
        raise e
      end
    end

    # マイター処理付き壁の生成。
    # 1. 前の壁（prev_group）の終点頂点を交点（マイター頂点）へ移動する。
    # 2. 新しい壁をマイター頂点を始点として生成する。
    # 両操作は1つの Operation に包まれるため Undo が1ステップで済む。
    #
    # @param pt1         [Geom::Point3d]  現在の壁の始点 = コーナー点
    # @param pt2         [Geom::Point3d]  現在の壁の終点
    # @param prev_group  [Sketchup::Group] 前の壁グループ（変更対象）
    # @param prev_dir    [Geom::Vector3d] 前の壁の進行方向（正規化済み）
    # @param prev_data   [Hash]           前の壁の vertices_hash（終点識別に使用）
    # @return [Sketchup::Group, nil]
    def build_mitered(pt1, pt2, prev_group:, prev_dir:, prev_data:)
      curr_data = vertices_hash(pt1, pt2)
      return nil unless curr_data

      # 現在の壁の進行方向
      curr_dir = Geom::Vector3d.new(pt2.x - pt1.x, pt2.y - pt1.y, 0.0)
      return build(pt1, pt2) if curr_dir.length < Constants::MIN_WALL_LENGTH

      curr_dir.normalize!

      miter = compute_miter_vertices(pt1, prev_dir, curr_dir, prev_data, curr_data)
      # 平行壁 / 鋭角すぎ → 通常の四角壁にフォールバック
      return build(pt1, pt2) unless miter

      model = Sketchup.active_model
      model.start_operation('Make Wall', true)
      begin
        # ① 前の壁の終点頂点をマイター頂点へ移動
        fix_wall_end(prev_group, prev_data, miter)

        # ② 新しい壁をマイター頂点を始点として生成
        bottom = [miter[:left_b], curr_data[:bottom][1],
                  curr_data[:bottom][2], miter[:right_b]]
        group  = add_wall_group(bottom)

        model.commit_operation
        group
      rescue => e
        model.abort_operation
        raise e
      end
    end

    # プレビュー用に頂点データのみを返す（ジオメトリ生成なし）。
    # @return [Hash{bottom:, top:}, nil]
    def self.preview_vertices(pt1, pt2, params)
      new(params).vertices_hash(pt1, pt2)
    end

    # 底面（:bottom）と上面（:top）の 4 頂点を計算して返す。
    # @return [Hash{bottom: Array<Geom::Point3d>, top: Array<Geom::Point3d>}, nil]
    def vertices_hash(pt1, pt2)
      dir = Geom::Vector3d.new(pt2.x - pt1.x, pt2.y - pt1.y, 0.0)
      return nil if dir.length < Constants::MIN_WALL_LENGTH

      dir.normalize!
      normal = Geom::Vector3d.new(-dir.y, dir.x, 0.0)

      t = @params.thickness
      case @params.justification
      when :center then d_left = t / 2.0; d_right = t / 2.0
      when :left   then d_left = 0.0;     d_right = t
      when :right  then d_left = t;       d_right = 0.0
      else              d_left = t / 2.0; d_right = t / 2.0
      end

      base_z = pt1.z
      v0 = offset_at_z(pt1, normal,  d_left,  base_z)   # 始点・左端
      v1 = offset_at_z(pt2, normal,  d_left,  base_z)   # 終点・左端
      v2 = offset_at_z(pt2, normal, -d_right, base_z)   # 終点・右端
      v3 = offset_at_z(pt1, normal, -d_right, base_z)   # 始点・右端

      bottom = [v0, v1, v2, v3]
      top    = bottom.map { |p| Geom::Point3d.new(p.x, p.y, p.z + @params.height) }

      { bottom: bottom, top: top }
    end

    private

    # ── ジオメトリ生成ヘルパー ──────────────────────────────────────────────────

    # 指定した底面頂点配列で壁グループを生成して返す。
    # Operation は呼び出し側が開閉すること。
    def add_wall_group(bottom_pts)
      group    = Sketchup.active_model.active_entities.add_group
      entities = group.entities
      face     = entities.add_face(bottom_pts)
      face.reverse! if face.normal.z < 0
      face.pushpull(-@params.height)
      group
    end

    # ── Step 7: マイター交点計算 ────────────────────────────────────────────────

    # コーナー点 pt1 を通る 2 壁のオフセット直線の交点（マイター頂点）を計算する。
    #
    # 左辺マイター:
    #   Line A: prev_data[:bottom][1] を通り prev_dir 方向（前の壁の左端ライン）
    #   Line B: curr_data[:bottom][0] を通り curr_dir 方向（現在の壁の左端ライン）
    # 右辺マイター:
    #   Line A: prev_data[:bottom][2] を通り prev_dir 方向（前の壁の右端ライン）
    #   Line B: curr_data[:bottom][3] を通り curr_dir 方向（現在の壁の右端ライン）
    #
    # @return [Hash{left_b:, right_b:, left_t:, right_t:}, nil]
    def compute_miter_vertices(pt1, prev_dir, curr_dir, prev_data, curr_data)
      base_z  = pt1.z
      height  = @params.height

      # ── 左辺交点 ─────────────────────────────────────────────────────────────
      miter_left_b = line_line_intersection_2d(
        prev_data[:bottom][1], prev_dir,    # 前の壁の終点・左端を通る直線
        curr_data[:bottom][0], curr_dir,    # 現在の壁の始点・左端を通る直線
        base_z
      )
      return nil unless miter_left_b

      # ── 右辺交点 ─────────────────────────────────────────────────────────────
      miter_right_b = line_line_intersection_2d(
        prev_data[:bottom][2], prev_dir,    # 前の壁の終点・右端を通る直線
        curr_data[:bottom][3], curr_dir,    # 現在の壁の始点・右端を通る直線
        base_z
      )
      return nil unless miter_right_b

      # ── 距離制限（鋭角コーナーで交点が遠すぎる場合はフォールバック） ──────────
      max_dist = @params.thickness * MITER_MAX_FACTOR
      return nil if pt1.distance(miter_left_b)  > max_dist
      return nil if pt1.distance(miter_right_b) > max_dist

      {
        left_b:  miter_left_b,
        right_b: miter_right_b,
        left_t:  Geom::Point3d.new(miter_left_b.x,  miter_left_b.y,  base_z + height),
        right_t: Geom::Point3d.new(miter_right_b.x, miter_right_b.y, base_z + height)
      }
    end

    # ── Step 7: 前の壁の終点頂点を移動 ─────────────────────────────────────────

    # prev_group の終点側4頂点（底・上それぞれ左右）を miter 頂点位置へ移動する。
    # transform_entities を使うことで接続するすべての Face を連動させる。
    def fix_wall_end(group, prev_data, miter)
      return unless group.respond_to?(:valid?) && group.valid?

      entities  = group.entities
      all_verts = entities.grep(Sketchup::Edge).flat_map(&:vertices).uniq

      # 移動マップ: { 期待される旧位置 => 新位置 }
      moves = {
        prev_data[:bottom][1] => miter[:left_b],
        prev_data[:bottom][2] => miter[:right_b],
        prev_data[:top][1]    => miter[:left_t],
        prev_data[:top][2]    => miter[:right_t]
      }

      moves.each do |old_pt, new_pt|
        # 旧位置に最も近い頂点を探す（スナップ許容内）
        vert = all_verts.min_by { |v| v.position.distance(old_pt) }
        next unless vert
        next if vert.position.distance(old_pt) > VERTEX_SNAP_TOL

        delta = new_pt - vert.position
        next if delta.length < MITER_DET_EPSILON   # すでに正しい位置

        entities.transform_entities(
          Geom::Transformation.translation(delta),
          [vert]
        )
      end
    end

    # ── 2D 直線交点計算（Cramer's rule）────────────────────────────────────────

    # XY 平面上の 2 直線の交点を求める。
    #
    #   Line 1: P1 + t * D1
    #   Line 2: P2 + s * D2
    #
    # 連立方程式:
    #   t * D1.x - s * D2.x = (P2.x - P1.x) = dx
    #   t * D1.y - s * D2.y = (P2.y - P1.y) = dy
    #
    # Cramer's rule:
    #   det = D1.x * D2.y - D1.y * D2.x   ← D1 × D2 の Z 成分
    #   t   = (dx * D2.y - dy * D2.x) / det
    #   交点 = P1 + t * D1
    #
    # @return [Geom::Point3d, nil]   平行（|det| < ε）のとき nil
    def line_line_intersection_2d(p1, d1, p2, d2, base_z)
      det = d1.x * d2.y - d1.y * d2.x
      return nil if det.abs < MITER_DET_EPSILON

      dx = p2.x - p1.x
      dy = p2.y - p1.y
      t  = (dx * d2.y - dy * d2.x) / det

      Geom::Point3d.new(p1.x + t * d1.x, p1.y + t * d1.y, base_z)
    end

    # ── 共通ユーティリティ ───────────────────────────────────────────────────────

    def offset_at_z(point, normal, distance, base_z)
      p = point.offset(normal, distance)
      Geom::Point3d.new(p.x, p.y, base_z)
    end
  end
end
