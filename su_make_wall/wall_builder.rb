# frozen_string_literal: true

module SuMakeWall
  # =============================================================================
  # WallBuilder — 壁ジオメトリの計算と生成
  #
  # Tool クラスから分離することで、ジオメトリロジックの単体テストや
  # 将来のコーナーマイター処理の追加が容易になる。
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
  #   v0 = pt1 + normal * d_left   （始点・左端）
  #   v1 = pt2 + normal * d_left   （終点・左端）
  #   v2 = pt2 - normal * d_right  （終点・右端）
  #   v3 = pt1 - normal * d_right  （始点・右端）
  # =============================================================================
  class WallBuilder
    def initialize(params)
      @params = params
    end

    # ── 公開 API ───────────────────────────────────────────────────────────────

    # ジオメトリを確定してモデルに Group を追加する（Undo 対応）。
    # 失敗時は nil を返す（Operation は abort 済み）。
    #
    # @param pt1 [Geom::Point3d] 始点
    # @param pt2 [Geom::Point3d] 終点
    # @return [Sketchup::Group, nil]
    def build(pt1, pt2)
      data = vertices_hash(pt1, pt2)
      return nil unless data

      model    = Sketchup.active_model
      model.start_operation('Make Wall', true)

      begin
        group    = model.active_entities.add_group
        entities = group.entities

        # 底面の Face を追加（法線が上向きになる反時計回り順）
        face = entities.add_face(data[:bottom])

        # ── Step 2 時点では PushPull なし（2D の底面のみ） ──────────────────
        # Step 3 で以下の 1 行を有効化する:
        #   face.reverse! if face.normal.z < 0   # 法線を必ず上向きに正規化
        #   face.pushpull(-@params.height)

        model.commit_operation
        group

      rescue => e
        model.abort_operation
        raise e
      end
    end

    # プレビュー用に頂点データのみを返す（ジオメトリ生成なし）。
    # draw() から毎フレーム呼ばれるため、Operation を開いてはいけない。
    #
    # @return [Hash{bottom: Array<Geom::Point3d>, top: Array<Geom::Point3d>}, nil]
    def self.preview_vertices(pt1, pt2, params)
      new(params).vertices_hash(pt1, pt2)
    end

    # ── 頂点計算（Tool・プレビュー双方から使用） ──────────────────────────────

    # 底面（:bottom）と上面（:top）の 4 頂点を計算して返す。
    # pt1 と pt2 が近すぎる場合（< MIN_WALL_LENGTH）は nil を返す。
    #
    # @return [Hash{bottom: Array<Geom::Point3d>, top: Array<Geom::Point3d>}, nil]
    def vertices_hash(pt1, pt2)
      # 1. 壁の進行方向ベクトル（XY 平面に射影して正規化）
      dir = Geom::Vector3d.new(pt2.x - pt1.x, pt2.y - pt1.y, 0.0)
      return nil if dir.length < Constants::MIN_WALL_LENGTH

      dir.normalize!

      # 2. 法線ベクトル（進行方向を Z 軸まわりに +90° 回転 = 左手法線）
      normal = Geom::Vector3d.new(-dir.y, dir.x, 0.0)

      # 3. Justification に応じた左右オフセット量（正値）
      t = @params.thickness
      case @params.justification
      when :center
        d_left  = t / 2.0
        d_right = t / 2.0
      when :left
        # 基準線 = 左端 → 左方向のオフセット 0、右方向へ全厚み
        d_left  = 0.0
        d_right = t
      when :right
        # 基準線 = 右端 → 左方向へ全厚み、右方向のオフセット 0
        d_left  = t
        d_right = 0.0
      else
        d_left  = t / 2.0
        d_right = t / 2.0
      end

      # 4. 底面 4 頂点（全て pt1.z と同じ高さ = 水平な底面を保証）
      base_z = pt1.z
      v0 = offset_at_z(pt1, normal,  d_left,  base_z)  # 始点・左端
      v1 = offset_at_z(pt2, normal,  d_left,  base_z)  # 終点・左端
      v2 = offset_at_z(pt2, normal, -d_right, base_z)  # 終点・右端
      v3 = offset_at_z(pt1, normal, -d_right, base_z)  # 始点・右端

      bottom = [v0, v1, v2, v3]
      top    = bottom.map { |p| Geom::Point3d.new(p.x, p.y, p.z + @params.height) }

      { bottom: bottom, top: top }
    end

    private

    # point を normal 方向に distance だけオフセットし、Z を base_z に固定した Point3d を返す。
    # Geom::Point3d#offset は XY をオフセットするが Z もソース点の値になるため、
    # base_z を明示的に上書きして底面を水平に保つ。
    def offset_at_z(point, normal, distance, base_z)
      p = point.offset(normal, distance)
      Geom::Point3d.new(p.x, p.y, base_z)
    end
  end
end
