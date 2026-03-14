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

      prompts  = ['高さ (mm)', '厚み (mm)', '基準線 (center / left / right)']
      defaults = [default_h, default_t, default_j]

      input = UI.inputbox(prompts, defaults, 'MakeWall — パラメータ設定')
      return nil unless input  # キャンセル

      height_mm    = [input[0].to_f, 1.0].max  # 最低 1mm
      thickness_mm = [input[1].to_f, 1.0].max
      just_sym     = input[2].strip.downcase.to_sym

      unless VALID_JUSTIFICATIONS.include?(just_sym)
        UI.messagebox("基準線には center / left / right のいずれかを入力してください。\n" \
                      "「#{input[2]}」は無効です。center を使用します。")
        just_sym = :center
      end

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
