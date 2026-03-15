# frozen_string_literal: true

module SuMakeWall
  # =============================================================================
  # Parameters — 壁生成パラメータの保持とバリデーション
  #
  # 現時点では UI.inputbox によるシンプルな入力を提供する。
  # Step 6 で HtmlDialog に移行する際は from_inputbox を差し替えるだけでよい。
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

    # UI.inputbox でパラメータを入力させる。キャンセル時は nil を返す。
    def self.from_inputbox
      # デフォルト値をミリメートル単位の文字列として表示する
      default_h = (Constants::DEFAULT_HEIGHT    / 1.mm).round.to_s
      default_t = (Constants::DEFAULT_THICKNESS / 1.mm).round.to_s
      default_j = Constants::DEFAULT_JUSTIFICATION.to_s

      # defaults[2] をパイプ区切りにすると UI.inputbox がドロップダウンとして表示する。
      # 先頭トークン "center" が初期選択値になる。
      prompts  = ['高さ (mm)', '厚み (mm)', '基準線']
      defaults = [default_h, default_t, 'center|left|right']

      input = UI.inputbox(prompts, defaults, 'MakeWall — パラメータ設定')
      return nil unless input  # キャンセル

      height_mm    = [input[0].to_f, 1.0].max  # 最低 1mm
      thickness_mm = [input[1].to_f, 1.0].max
      # ドロップダウンは "center" / "left" / "right" のいずれかのみ返すためバリデーション不要
      just_sym     = input[2].strip.downcase.to_sym

      new(
        height:        height_mm.mm,
        thickness:     thickness_mm.mm,
        justification: just_sym
      )
    end

    # デバッグ用の文字列表現
    def to_s
      h_mm = (height    / 1.mm).round
      t_mm = (thickness / 1.mm).round
      "Parameters(height=#{h_mm}mm, thickness=#{t_mm}mm, justification=#{justification})"
    end
  end
end
