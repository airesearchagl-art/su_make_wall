# frozen_string_literal: true

module SuMakeWall
  # =============================================================================
  # Parameters — 壁生成パラメータの保持と単位変換
  #
  # Step 6 で HtmlDialog に移行したため from_inputbox を削除。
  # UIDialog の update_param コールバックが set_*_mm / set_justification を呼ぶ。
  # Tool は同じ Parameters オブジェクトへの参照を保持するため、
  # UIDialog による変更は即座に Tool のプレビューにも反映される。
  # =============================================================================
  class Parameters
    VALID_JUSTIFICATIONS = %i[center left right].freeze

    attr_accessor :height, :thickness, :justification

    def initialize(
      height:        Constants::DEFAULT_HEIGHT,
      thickness:     Constants::DEFAULT_THICKNESS,
      justification: Constants::DEFAULT_JUSTIFICATION
    )
      @height        = height
      @thickness     = thickness
      @justification = justification
    end

    # ── mm 単位での読み取り（HtmlDialog への初期値送信用） ────────────────────

    # 高さをミリメートル単位の整数で返す
    def height_mm
      (@height / 1.mm).round
    end

    # 厚みをミリメートル単位の整数で返す
    def thickness_mm
      (@thickness / 1.mm).round
    end

    # ── mm 単位でのセット（UIDialog の update_param コールバックから呼ばれる） ──

    # 高さを mm 値で設定する。1mm 未満はクランプ。
    def set_height_mm(mm)
      @height = [mm.to_f, 1.0].max.mm
    end

    # 厚みを mm 値で設定する。1mm 未満はクランプ。
    def set_thickness_mm(mm)
      @thickness = [mm.to_f, 1.0].max.mm
    end

    # 基準線を文字列で設定する。不正値は無視して現状維持。
    def set_justification(str)
      sym = str.to_s.strip.downcase.to_sym
      @justification = sym if VALID_JUSTIFICATIONS.include?(sym)
    end

    # ── デバッグ用 ────────────────────────────────────────────────────────────

    def to_s
      "Parameters(height=#{height_mm}mm, thickness=#{thickness_mm}mm, justification=#{justification})"
    end
  end
end
