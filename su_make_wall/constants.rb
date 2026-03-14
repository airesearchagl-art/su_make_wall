# frozen_string_literal: true

module SuMakeWall
  # =============================================================================
  # Constants — プラグイン全体で共有する定数
  # =============================================================================
  module Constants
    # ── デフォルトパラメータ ─────────────────────────────────────────────────
    DEFAULT_HEIGHT        = 2400.mm   # 壁の高さ（内部単位 = インチに変換済み）
    DEFAULT_THICKNESS     = 150.mm    # 壁の厚み
    DEFAULT_JUSTIFICATION = :center   # 基準線: :center / :left / :right

    # ── プレビュー描画スタイル ────────────────────────────────────────────────
    # 通常プレビュー（青）
    PREVIEW_COLOR      = Sketchup::Color.new(0, 120, 215).freeze
    # コーナートリム端部のハイライト（赤）— Step 4 / Step 7 で使用
    PREVIEW_COLOR_TRIM = Sketchup::Color.new(220, 50, 50).freeze
    # プレビュー線幅
    PREVIEW_LINE_WIDTH = 2

    # ── 最小壁長（これ以下は生成しない） ─────────────────────────────────────
    MIN_WALL_LENGTH = 1.mm
  end
end
