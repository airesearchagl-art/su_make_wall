# frozen_string_literal: true

# =============================================================================
# su_make_wall.rb — MakeWall プラグイン ローダー
#
# SketchUp の Extensions フォルダ直下に置く唯一のエントリーポイント。
# SketchupExtension を登録し、実体コードは su_make_wall/ サブフォルダへ委譲する。
# =============================================================================

require 'sketchup.rb'
require 'extensions.rb'

module SuMakeWall
  # 二重ロード防止（開発中の reload でも安全に動作する）
  unless defined?(@extension)
    loader_path = File.join(File.dirname(__FILE__), 'su_make_wall', 'main')

    @extension = SketchupExtension.new('MakeWall', loader_path)
    @extension.creator     = 'MakeWall Plugin'
    @extension.description = 'Revit ライクな壁描画ツール。始点・終点クリックで ' \
                             '厚み・高さ・基準線を持つ 3D 壁を連続生成します。'
    @extension.version     = '0.1.0'
    @extension.copyright   = '2024'

    Sketchup.register_extension(@extension, true)
  end
end
