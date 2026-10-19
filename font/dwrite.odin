#+build windows
package font

// DirectWrite bindings: only the interfaces and methods the font package calls. Vtable layouts follow the Windows SDK
// (cross-checked against mingw-w64's widl-generated dwrite*.h); methods the package never calls are kept as rawptr
// slots so the order stays exact. Interfaces implemented here (font file loader and stream, text analysis source and
// sink) are in com.odin.

import win "core:sys/windows"

foreign import dwrite_lib "system:dwrite.lib"

HRESULT :: win.HRESULT
BOOL    :: win.BOOL
IID     :: win.IID
IUnknown :: win.IUnknown
IUnknown_VTable :: win.IUnknown_VTable

S_OK :: HRESULT(0)
E_NOINTERFACE :: HRESULT(-2147467262)          // 0x80004002
E_INVALIDARG :: HRESULT(-2147024809)           // 0x80070057
E_FAIL :: HRESULT(-2147467259)                 // 0x80004005
E_NOT_SUFFICIENT_BUFFER :: HRESULT(-2147024774) // 0x8007007A
DWRITE_E_NOCOLOR :: HRESULT(-2003283956)       // 0x8898500C

DWRITE_FACTORY_TYPE :: enum u32 { SHARED = 0, ISOLATED = 1 }

@(default_calling_convention = "system")
foreign dwrite_lib {
	DWriteCreateFactory :: proc(factory_type: DWRITE_FACTORY_TYPE, iid: ^IID, factory: ^rawptr) -> HRESULT ---
}

IID_IDWriteFactory := IID{0xb859ee5a, 0xd838, 0x4b5b, {0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48}}
IID_IDWriteFactory2 := IID{0x0439fc60, 0xca44, 0x4994, {0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec}}
IID_IDWriteFactory4 := IID{0x4b0b5bd3, 0x0797, 0x4549, {0x8a, 0xc5, 0xfe, 0x91, 0x5c, 0xc5, 0x38, 0x56}}
IID_IDWriteFontFace2 := IID{0xd8b768ff, 0x64bc, 0x4e66, {0x98, 0x2b, 0xec, 0x8e, 0x87, 0xf6, 0x93, 0xf7}}
IID_IDWriteFontFace4 := IID{0x27f2a904, 0x4eb8, 0x441d, {0x96, 0x78, 0x05, 0x63, 0xf5, 0x3e, 0x3e, 0x2f}}
IID_IDWriteFontFace5 := IID{0x98eff3a5, 0xb667, 0x479a, {0xb1, 0x45, 0xe2, 0xfa, 0x5b, 0x9f, 0xdc, 0x29}}
IID_IDWriteFontFileLoader := IID{0x727cad4e, 0xd6af, 0x4c9e, {0x8a, 0x08, 0xd6, 0x95, 0xb1, 0x1c, 0xaa, 0x49}}
IID_IDWriteFontFileStream := IID{0x6d4865fe, 0x0ab8, 0x4d91, {0x8f, 0x62, 0x5d, 0xd6, 0xbe, 0x34, 0xa3, 0xe0}}
IID_IDWriteTextAnalysisSource := IID{0x688e1a58, 0x5094, 0x47c8, {0xad, 0xc8, 0xfb, 0xce, 0xa6, 0x0a, 0xe9, 0x2b}}
IID_IDWriteTextAnalysisSink := IID{0x5810cd44, 0x0ca0, 0x4701, {0xb3, 0xfa, 0xbe, 0xc5, 0x18, 0x2a, 0xe4, 0xf6}}
IID_IDWriteColorGlyphRunEnumerator1 := IID{0x7c5f86da, 0xc7a1, 0x4f05, {0xb8, 0xe1, 0x55, 0xa1, 0x79, 0xfe, 0x5a, 0x35}}
IID_IUnknown := IID{0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}

////////////////////////////////
// Enums and structs

DWRITE_FONT_WEIGHT  :: u32   // 1..999
DWRITE_FONT_STRETCH :: u32   // 1 ultra-condensed .. 5 normal .. 9 ultra-expanded
DWRITE_FONT_STYLE   :: enum u32 { NORMAL = 0, OBLIQUE = 1, ITALIC = 2 }

DWRITE_FONT_SIMULATIONS :: distinct u32
DWRITE_FONT_SIMULATIONS_BOLD    :: DWRITE_FONT_SIMULATIONS(1)
DWRITE_FONT_SIMULATIONS_OBLIQUE :: DWRITE_FONT_SIMULATIONS(2)

DWRITE_FONT_FILE_TYPE :: u32
DWRITE_FONT_FACE_TYPE :: u32
DWRITE_FONT_FACE_TYPE_UNKNOWN :: DWRITE_FONT_FACE_TYPE(6)

DWRITE_READING_DIRECTION :: enum u32 { LEFT_TO_RIGHT = 0, RIGHT_TO_LEFT = 1, TOP_TO_BOTTOM = 2, BOTTOM_TO_TOP = 3 }

DWRITE_RENDERING_MODE :: enum u32 {
	DEFAULT = 0, ALIASED = 1, GDI_CLASSIC = 2, GDI_NATURAL = 3, NATURAL = 4, NATURAL_SYMMETRIC = 5, OUTLINE = 6,
}
DWRITE_MEASURING_MODE :: enum u32 { NATURAL = 0, GDI_CLASSIC = 1, GDI_NATURAL = 2 }
DWRITE_GRID_FIT_MODE :: enum u32 { DEFAULT = 0, DISABLED = 1, ENABLED = 2 }
DWRITE_TEXT_ANTIALIAS_MODE :: enum u32 { CLEARTYPE = 0, GRAYSCALE = 1 }
DWRITE_TEXTURE_TYPE :: enum u32 { ALIASED_1x1 = 0, CLEARTYPE_3x1 = 1 }

DWRITE_GLYPH_IMAGE_FORMATS :: distinct u32
DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE :: DWRITE_GLYPH_IMAGE_FORMATS(0x1)
DWRITE_GLYPH_IMAGE_FORMATS_CFF      :: DWRITE_GLYPH_IMAGE_FORMATS(0x2)
DWRITE_GLYPH_IMAGE_FORMATS_COLR     :: DWRITE_GLYPH_IMAGE_FORMATS(0x4)
DWRITE_GLYPH_IMAGE_FORMATS_SVG      :: DWRITE_GLYPH_IMAGE_FORMATS(0x8)
DWRITE_GLYPH_IMAGE_FORMATS_PNG      :: DWRITE_GLYPH_IMAGE_FORMATS(0x10)
DWRITE_GLYPH_IMAGE_FORMATS_JPEG     :: DWRITE_GLYPH_IMAGE_FORMATS(0x20)
DWRITE_GLYPH_IMAGE_FORMATS_TIFF     :: DWRITE_GLYPH_IMAGE_FORMATS(0x40)
DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8 :: DWRITE_GLYPH_IMAGE_FORMATS(0x80)

DWRITE_FONT_METRICS :: struct {
	designUnitsPerEm:       u16,
	ascent:                 u16,
	descent:                u16,
	lineGap:                i16,
	capHeight:              u16,
	xHeight:                u16,
	underlinePosition:      i16,
	underlineThickness:     u16,
	strikethroughPosition:  i16,
	strikethroughThickness: u16,
}

DWRITE_GLYPH_METRICS :: struct {
	leftSideBearing:   i32,
	advanceWidth:      u32,
	rightSideBearing:  i32,
	topSideBearing:    i32,
	advanceHeight:     u32,
	bottomSideBearing: i32,
	verticalOriginY:   i32,
}

DWRITE_GLYPH_OFFSET :: struct { advanceOffset, ascenderOffset: f32 }

DWRITE_MATRIX :: struct { m11, m12, m21, m22, dx, dy: f32 }

DWRITE_GLYPH_RUN :: struct {
	fontFace:     ^IDWriteFontFace,
	fontEmSize:   f32,
	glyphCount:   u32,
	glyphIndices: [^]u16,
	glyphAdvances: [^]f32,
	glyphOffsets: [^]DWRITE_GLYPH_OFFSET,
	isSideways:   BOOL,
	bidiLevel:    u32,
}

DWRITE_GLYPH_RUN_DESCRIPTION :: struct {
	localeName:   [^]u16,
	string:       [^]u16,
	stringLength: u32,
	clusterMap:   [^]u16,
	textPosition: u32,
}

DWRITE_SCRIPT_SHAPES :: enum u32 { DEFAULT = 0, NO_VISUAL = 1 }

DWRITE_SCRIPT_ANALYSIS :: struct {
	script: u16,
	shapes: DWRITE_SCRIPT_SHAPES,
}

// bit fields: isShapedAlone (bit 0), canBreakShapingAfter (bit 2)
DWRITE_SHAPING_TEXT_PROPERTIES :: distinct u16
// bit fields: justification (bits 0-3), isClusterStart (bit 4), isDiacritic (bit 5), isZeroWidthSpace (bit 6)
DWRITE_SHAPING_GLYPH_PROPERTIES :: distinct u16
// bit fields: breakConditionBefore (bits 0-1), breakConditionAfter (bits 2-3), isWhitespace (bit 4), isSoftHyphen (bit 5)
DWRITE_LINE_BREAKPOINT :: distinct u8

DWRITE_BREAK_CONDITION :: enum u8 { NEUTRAL = 0, CAN_BREAK = 1, MAY_NOT_BREAK = 2, MUST_BREAK = 3 }

DWRITE_FONT_FEATURE :: struct {
	nameTag:   u32,   // DWRITE_MAKE_OPENTYPE_TAG: 'a' | 'b' << 8 | 'c' << 16 | 'd' << 24
	parameter: u32,
}

DWRITE_TYPOGRAPHIC_FEATURES :: struct {
	features:     [^]DWRITE_FONT_FEATURE,
	featureCount: u32,
}

DWRITE_COLOR_F :: struct { r, g, b, a: f32 }

DWRITE_COLOR_GLYPH_RUN :: struct {
	glyphRun:            DWRITE_GLYPH_RUN,
	glyphRunDescription: ^DWRITE_GLYPH_RUN_DESCRIPTION,
	baselineOriginX:     f32,
	baselineOriginY:     f32,
	runColor:            DWRITE_COLOR_F,
	paletteIndex:        u16,   // 0xFFFF: the text color
}

// C++ derives it from DWRITE_COLOR_GLYPH_RUN: its fields start after the base's padded size
DWRITE_COLOR_GLYPH_RUN1 :: struct {
	using base:       DWRITE_COLOR_GLYPH_RUN,
	glyphImageFormat: DWRITE_GLYPH_IMAGE_FORMATS,
	measuringMode:    DWRITE_MEASURING_MODE,
}

D2D1_POINT_2F :: struct { x, y: f32 }

DWRITE_GLYPH_IMAGE_DATA :: struct {
	imageData:             rawptr,
	imageDataSize:         u32,
	uniqueDataId:          u32,
	pixelsPerEm:           u32,
	pixelSize:             [2]u32,
	horizontalLeftOrigin:  [2]i32,
	horizontalRightOrigin: [2]i32,
	verticalTopOrigin:     [2]i32,
	verticalBottomOrigin:  [2]i32,
}

DWRITE_FONT_AXIS_VALUE :: struct {
	axisTag: u32,
	value:   f32,
}

DWRITE_FONT_AXIS_RANGE :: struct {
	axisTag:  u32,
	minValue: f32,
	maxValue: f32,
}

RECT :: win.RECT

////////////////////////////////
// Interfaces called by the package

IDWriteFactory :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteFactory_VTable,
}
IDWriteFactory_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetSystemFontCollection:       proc "system" (this: ^IDWriteFactory, collection: ^^IDWriteFontCollection, check_for_updates: BOOL) -> HRESULT,
	CreateCustomFontCollection:    rawptr,
	RegisterFontCollectionLoader:  rawptr,
	UnregisterFontCollectionLoader: rawptr,
	CreateFontFileReference:       proc "system" (this: ^IDWriteFactory, path: [^]u16, writetime: rawptr, file: ^^IDWriteFontFile) -> HRESULT,
	CreateCustomFontFileReference: proc "system" (this: ^IDWriteFactory, key: rawptr, key_size: u32, loader: ^IDWriteFontFileLoader, file: ^^IDWriteFontFile) -> HRESULT,
	CreateFontFace:                proc "system" (this: ^IDWriteFactory, face_type: DWRITE_FONT_FACE_TYPE, files_number: u32, files: [^]^IDWriteFontFile, index: u32, sims: DWRITE_FONT_SIMULATIONS, face: ^^IDWriteFontFace) -> HRESULT,
	CreateRenderingParams:         rawptr,
	CreateMonitorRenderingParams:  rawptr,
	CreateCustomRenderingParams:   rawptr,
	RegisterFontFileLoader:        proc "system" (this: ^IDWriteFactory, loader: ^IDWriteFontFileLoader) -> HRESULT,
	UnregisterFontFileLoader:      proc "system" (this: ^IDWriteFactory, loader: ^IDWriteFontFileLoader) -> HRESULT,
	CreateTextFormat:              rawptr,
	CreateTypography:              rawptr,
	GetGdiInterop:                 rawptr,
	CreateTextLayout:              rawptr,
	CreateGdiCompatibleTextLayout: rawptr,
	CreateEllipsisTrimmingSign:    rawptr,
	CreateTextAnalyzer:            proc "system" (this: ^IDWriteFactory, analyzer: ^^IDWriteTextAnalyzer) -> HRESULT,
	CreateNumberSubstitution:      rawptr,
	CreateGlyphRunAnalysis:        proc "system" (this: ^IDWriteFactory, run: ^DWRITE_GLYPH_RUN, pixels_per_dip: f32, transform: ^DWRITE_MATRIX, mode: DWRITE_RENDERING_MODE, measuring: DWRITE_MEASURING_MODE, x, y: f32, analysis: ^^IDWriteGlyphRunAnalysis) -> HRESULT,
}

IDWriteFactory1_VTable :: struct {
	using factory_vtable: IDWriteFactory_VTable,
	GetEudcFontCollection:        rawptr,
	CreateCustomRenderingParams1: rawptr,
}

IDWriteFactory2 :: struct #raw_union {
	#subtype factory: IDWriteFactory,
	using vtable: ^IDWriteFactory2_VTable,
}
IDWriteFactory2_VTable :: struct {
	using factory1_vtable: IDWriteFactory1_VTable,
	GetSystemFontFallback:        proc "system" (this: ^IDWriteFactory2, fallback: ^^IDWriteFontFallback) -> HRESULT,
	CreateFontFallbackBuilder:    rawptr,
	TranslateColorGlyphRun:       proc "system" (this: ^IDWriteFactory2, x, y: f32, run: ^DWRITE_GLYPH_RUN, desc: ^DWRITE_GLYPH_RUN_DESCRIPTION, mode: DWRITE_MEASURING_MODE, transform: ^DWRITE_MATRIX, palette: u32, layers: ^^IDWriteColorGlyphRunEnumerator) -> HRESULT,
	CreateCustomRenderingParams2: rawptr,
	CreateGlyphRunAnalysis2:      proc "system" (this: ^IDWriteFactory2, run: ^DWRITE_GLYPH_RUN, transform: ^DWRITE_MATRIX, mode: DWRITE_RENDERING_MODE, measuring: DWRITE_MEASURING_MODE, grid: DWRITE_GRID_FIT_MODE, aa: DWRITE_TEXT_ANTIALIAS_MODE, x, y: f32, analysis: ^^IDWriteGlyphRunAnalysis) -> HRESULT,
}

IDWriteFactory3_VTable :: struct {
	using factory2_vtable: IDWriteFactory2_VTable,
	CreateGlyphRunAnalysis3:         rawptr,
	CreateCustomRenderingParams3:    rawptr,
	CreateFontFaceReference_file:    rawptr,
	CreateFontFaceReference_path:    rawptr,
	GetSystemFontSet:                rawptr,
	CreateFontSetBuilder:            rawptr,
	CreateFontCollectionFromFontSet: rawptr,
	GetSystemFontCollection3:        rawptr,
	GetFontDownloadQueue:            rawptr,
}

IDWriteFactory4 :: struct #raw_union {
	#subtype factory: IDWriteFactory,
	using vtable: ^IDWriteFactory4_VTable,
}
IDWriteFactory4_VTable :: struct {
	using factory3_vtable: IDWriteFactory3_VTable,
	TranslateColorGlyphRun4: proc "system" (this: ^IDWriteFactory4, origin: D2D1_POINT_2F, run: ^DWRITE_GLYPH_RUN, desc: ^DWRITE_GLYPH_RUN_DESCRIPTION, formats: DWRITE_GLYPH_IMAGE_FORMATS, mode: DWRITE_MEASURING_MODE, transform: ^DWRITE_MATRIX, palette: u32, layers: ^^IDWriteColorGlyphRunEnumerator1) -> HRESULT,
	ComputeGlyphOrigins_:    rawptr,
	ComputeGlyphOrigins:     rawptr,
}

IDWriteFontFile :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteFontFile_VTable,
}
IDWriteFontFile_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetReferenceKey: proc "system" (this: ^IDWriteFontFile, key: ^rawptr, key_size: ^u32) -> HRESULT,
	GetLoader:       rawptr,
	Analyze:         proc "system" (this: ^IDWriteFontFile, supported: ^BOOL, file_type: ^DWRITE_FONT_FILE_TYPE, face_type: ^DWRITE_FONT_FACE_TYPE, faces: ^u32) -> HRESULT,
}

IDWriteLocalizedStrings :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteLocalizedStrings_VTable,
}
IDWriteLocalizedStrings_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetCount:            proc "system" (this: ^IDWriteLocalizedStrings) -> u32,
	FindLocaleName:      proc "system" (this: ^IDWriteLocalizedStrings, locale: [^]u16, index: ^u32, exists: ^BOOL) -> HRESULT,
	GetLocaleNameLength: rawptr,
	GetLocaleName:       rawptr,
	GetStringLength:     proc "system" (this: ^IDWriteLocalizedStrings, index: u32, length: ^u32) -> HRESULT,
	GetString:           proc "system" (this: ^IDWriteLocalizedStrings, index: u32, buffer: [^]u16, size: u32) -> HRESULT,
}

IDWriteFontFace :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteFontFace_VTable,
}
IDWriteFontFace_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetType:                      proc "system" (this: ^IDWriteFontFace) -> DWRITE_FONT_FACE_TYPE,
	GetFiles:                     proc "system" (this: ^IDWriteFontFace, count: ^u32, files: [^]^IDWriteFontFile) -> HRESULT,
	GetIndex:                     proc "system" (this: ^IDWriteFontFace) -> u32,
	GetSimulations:               proc "system" (this: ^IDWriteFontFace) -> DWRITE_FONT_SIMULATIONS,
	IsSymbolFont:                 proc "system" (this: ^IDWriteFontFace) -> BOOL,
	GetMetrics:                   proc "system" (this: ^IDWriteFontFace, metrics: ^DWRITE_FONT_METRICS),
	GetGlyphCount:                proc "system" (this: ^IDWriteFontFace) -> u16,
	GetDesignGlyphMetrics:        proc "system" (this: ^IDWriteFontFace, glyphs: [^]u16, count: u32, metrics: [^]DWRITE_GLYPH_METRICS, sideways: BOOL) -> HRESULT,
	GetGlyphIndices:              proc "system" (this: ^IDWriteFontFace, codepoints: [^]u32, count: u32, glyphs: [^]u16) -> HRESULT,
	TryGetFontTable:              proc "system" (this: ^IDWriteFontFace, tag: u32, data: ^rawptr, size: ^u32, ctx: ^rawptr, exists: ^BOOL) -> HRESULT,
	ReleaseFontTable:             proc "system" (this: ^IDWriteFontFace, ctx: rawptr),
	GetGlyphRunOutline:           rawptr,
	GetRecommendedRenderingMode:  proc "system" (this: ^IDWriteFontFace, em_size, pixels_per_dip: f32, measuring: DWRITE_MEASURING_MODE, params: rawptr, mode: ^DWRITE_RENDERING_MODE) -> HRESULT,
	GetGdiCompatibleMetrics:      rawptr,
	GetGdiCompatibleGlyphMetrics: rawptr,
}

IDWriteFontFace1_VTable :: struct {
	using face_vtable: IDWriteFontFace_VTable,
	GetMetrics1:                   rawptr,
	GetGdiCompatibleMetrics1:      rawptr,
	GetCaretMetrics:               rawptr,
	GetUnicodeRanges:              rawptr,
	IsMonospacedFont:              rawptr,
	GetDesignGlyphAdvances:        rawptr,
	GetGdiCompatibleGlyphAdvances: rawptr,
	GetKerningPairAdjustments:     rawptr,
	HasKerningPairs:               rawptr,
	GetRecommendedRenderingMode1:  rawptr,
	GetVerticalGlyphVariants:      rawptr,
	HasVerticalGlyphVariants:      rawptr,
}

IDWriteFontFace2 :: struct #raw_union {
	#subtype face: IDWriteFontFace,
	using vtable: ^IDWriteFontFace2_VTable,
}
IDWriteFontFace2_VTable :: struct {
	using face1_vtable: IDWriteFontFace1_VTable,
	IsColorFont:                  proc "system" (this: ^IDWriteFontFace2) -> BOOL,
	GetColorPaletteCount:         proc "system" (this: ^IDWriteFontFace2) -> u32,
	GetPaletteEntryCount:         proc "system" (this: ^IDWriteFontFace2) -> u32,
	GetPaletteEntries:            rawptr,
	GetRecommendedRenderingMode2: rawptr,
}

IDWriteFontFace3_VTable :: struct {
	using face2_vtable: IDWriteFontFace2_VTable,
	GetFontFaceReference:         rawptr,
	GetPanose:                    rawptr,
	GetWeight:                    rawptr,
	GetStretch:                   rawptr,
	GetStyle:                     rawptr,
	GetFamilyNames:               rawptr,
	GetFaceNames:                 rawptr,
	GetInformationalStrings:      rawptr,
	HasCharacter:                 rawptr,
	GetRecommendedRenderingMode3: rawptr,
	IsCharacterLocal:             rawptr,
	IsGlyphLocal:                 rawptr,
	AreCharactersLocal:           rawptr,
	AreGlyphsLocal:               rawptr,
}

IDWriteFontFace4 :: struct #raw_union {
	#subtype face: IDWriteFontFace,
	using vtable: ^IDWriteFontFace4_VTable,
}
IDWriteFontFace4_VTable :: struct {
	using face3_vtable: IDWriteFontFace3_VTable,
	GetGlyphImageFormats_range: proc "system" (this: ^IDWriteFontFace4, glyph: u16, ppem_first, ppem_last: u32, formats: ^DWRITE_GLYPH_IMAGE_FORMATS) -> HRESULT,
	GetGlyphImageFormats:       proc "system" (this: ^IDWriteFontFace4) -> DWRITE_GLYPH_IMAGE_FORMATS,
	GetGlyphImageData:          proc "system" (this: ^IDWriteFontFace4, glyph: u16, ppem: u32, format: DWRITE_GLYPH_IMAGE_FORMATS, data: ^DWRITE_GLYPH_IMAGE_DATA, ctx: ^rawptr) -> HRESULT,
	ReleaseGlyphImageData:      proc "system" (this: ^IDWriteFontFace4, ctx: rawptr),
}

IDWriteFontFace5 :: struct #raw_union {
	#subtype face: IDWriteFontFace,
	using vtable: ^IDWriteFontFace5_VTable,
}
IDWriteFontFace5_VTable :: struct {
	using face4_vtable: IDWriteFontFace4_VTable,
	GetFontAxisValueCount: proc "system" (this: ^IDWriteFontFace5) -> u32,
	GetFontAxisValues:     proc "system" (this: ^IDWriteFontFace5, values: [^]DWRITE_FONT_AXIS_VALUE, count: u32) -> HRESULT,
	HasVariations:         proc "system" (this: ^IDWriteFontFace5) -> BOOL,
	GetFontResource:       proc "system" (this: ^IDWriteFontFace5, resource: ^^IDWriteFontResource) -> HRESULT,
	Equals:                rawptr,
}

IDWriteFontResource :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteFontResource_VTable,
}
IDWriteFontResource_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFontFile:              rawptr,
	GetFontFaceIndex:         rawptr,
	GetFontAxisCount:         proc "system" (this: ^IDWriteFontResource) -> u32,
	GetDefaultFontAxisValues: proc "system" (this: ^IDWriteFontResource, values: [^]DWRITE_FONT_AXIS_VALUE, count: u32) -> HRESULT,
	GetFontAxisRanges:        proc "system" (this: ^IDWriteFontResource, ranges: [^]DWRITE_FONT_AXIS_RANGE, count: u32) -> HRESULT,
	GetFontAxisAttributes:    rawptr,
	GetAxisNames:             rawptr,
	GetAxisValueNameCount:    rawptr,
	GetAxisValueNames:        rawptr,
	HasVariations:            proc "system" (this: ^IDWriteFontResource) -> BOOL,
	CreateFontFace:           proc "system" (this: ^IDWriteFontResource, sims: DWRITE_FONT_SIMULATIONS, values: [^]DWRITE_FONT_AXIS_VALUE, count: u32, face: ^^IDWriteFontFace5) -> HRESULT,
	CreateFontFaceReference:  rawptr,
}

IDWriteFont :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteFont_VTable,
}
IDWriteFont_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFontFamily:           proc "system" (this: ^IDWriteFont, family: ^^IDWriteFontFamily) -> HRESULT,
	GetWeight:               proc "system" (this: ^IDWriteFont) -> DWRITE_FONT_WEIGHT,
	GetStretch:              proc "system" (this: ^IDWriteFont) -> DWRITE_FONT_STRETCH,
	GetStyle:                proc "system" (this: ^IDWriteFont) -> DWRITE_FONT_STYLE,
	IsSymbolFont:            proc "system" (this: ^IDWriteFont) -> BOOL,
	GetFaceNames:            proc "system" (this: ^IDWriteFont, names: ^^IDWriteLocalizedStrings) -> HRESULT,
	GetInformationalStrings: rawptr,
	GetSimulations:          proc "system" (this: ^IDWriteFont) -> DWRITE_FONT_SIMULATIONS,
	GetMetrics:              proc "system" (this: ^IDWriteFont, metrics: ^DWRITE_FONT_METRICS),
	HasCharacter:            proc "system" (this: ^IDWriteFont, value: u32, exists: ^BOOL) -> HRESULT,
	CreateFontFace:          proc "system" (this: ^IDWriteFont, face: ^^IDWriteFontFace) -> HRESULT,
}

IDWriteFontList :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteFontList_VTable,
}
IDWriteFontList_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFontCollection: rawptr,
	GetFontCount:      proc "system" (this: ^IDWriteFontList) -> u32,
	GetFont:           proc "system" (this: ^IDWriteFontList, index: u32, font: ^^IDWriteFont) -> HRESULT,
}

IDWriteFontFamily :: struct #raw_union {
	#subtype list: IDWriteFontList,
	using vtable: ^IDWriteFontFamily_VTable,
}
IDWriteFontFamily_VTable :: struct {
	using list_vtable: IDWriteFontList_VTable,
	GetFamilyNames:       proc "system" (this: ^IDWriteFontFamily, names: ^^IDWriteLocalizedStrings) -> HRESULT,
	GetFirstMatchingFont: proc "system" (this: ^IDWriteFontFamily, weight: DWRITE_FONT_WEIGHT, stretch: DWRITE_FONT_STRETCH, style: DWRITE_FONT_STYLE, font: ^^IDWriteFont) -> HRESULT,
	GetMatchingFonts:     rawptr,
}

IDWriteFontCollection :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteFontCollection_VTable,
}
IDWriteFontCollection_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFontFamilyCount:  proc "system" (this: ^IDWriteFontCollection) -> u32,
	GetFontFamily:       proc "system" (this: ^IDWriteFontCollection, index: u32, family: ^^IDWriteFontFamily) -> HRESULT,
	FindFamilyName:      proc "system" (this: ^IDWriteFontCollection, name: [^]u16, index: ^u32, exists: ^BOOL) -> HRESULT,
	GetFontFromFontFace: proc "system" (this: ^IDWriteFontCollection, face: ^IDWriteFontFace, font: ^^IDWriteFont) -> HRESULT,
}

IDWriteTextAnalyzer :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteTextAnalyzer_VTable,
}
IDWriteTextAnalyzer_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	AnalyzeScript:             proc "system" (this: ^IDWriteTextAnalyzer, source: ^IDWriteTextAnalysisSource, position, length: u32, sink: ^IDWriteTextAnalysisSink) -> HRESULT,
	AnalyzeBidi:               proc "system" (this: ^IDWriteTextAnalyzer, source: ^IDWriteTextAnalysisSource, position, length: u32, sink: ^IDWriteTextAnalysisSink) -> HRESULT,
	AnalyzeNumberSubstitution: rawptr,
	AnalyzeLineBreakpoints:    proc "system" (this: ^IDWriteTextAnalyzer, source: ^IDWriteTextAnalysisSource, position, length: u32, sink: ^IDWriteTextAnalysisSink) -> HRESULT,
	GetGlyphs: proc "system" (this: ^IDWriteTextAnalyzer, text: [^]u16, length: u32, face: ^IDWriteFontFace, sideways, rtl: BOOL,
		analysis: ^DWRITE_SCRIPT_ANALYSIS, locale: [^]u16, substitution: rawptr, features: [^]^DWRITE_TYPOGRAPHIC_FEATURES,
		feature_range_len: [^]u32, feature_ranges: u32, max_glyphs: u32, cluster_map: [^]u16, text_props: [^]DWRITE_SHAPING_TEXT_PROPERTIES,
		glyphs: [^]u16, glyph_props: [^]DWRITE_SHAPING_GLYPH_PROPERTIES, glyph_count: ^u32) -> HRESULT,
	GetGlyphPlacements: proc "system" (this: ^IDWriteTextAnalyzer, text: [^]u16, cluster_map: [^]u16, text_props: [^]DWRITE_SHAPING_TEXT_PROPERTIES,
		text_len: u32, glyphs: [^]u16, glyph_props: [^]DWRITE_SHAPING_GLYPH_PROPERTIES, glyph_count: u32, face: ^IDWriteFontFace,
		em_size: f32, sideways, rtl: BOOL, analysis: ^DWRITE_SCRIPT_ANALYSIS, locale: [^]u16, features: [^]^DWRITE_TYPOGRAPHIC_FEATURES,
		feature_range_len: [^]u32, feature_ranges: u32, advances: [^]f32, offsets: [^]DWRITE_GLYPH_OFFSET) -> HRESULT,
	GetGdiCompatibleGlyphPlacements: rawptr,
}

IDWriteGlyphRunAnalysis :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteGlyphRunAnalysis_VTable,
}
IDWriteGlyphRunAnalysis_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetAlphaTextureBounds: proc "system" (this: ^IDWriteGlyphRunAnalysis, type: DWRITE_TEXTURE_TYPE, bounds: ^RECT) -> HRESULT,
	CreateAlphaTexture:    proc "system" (this: ^IDWriteGlyphRunAnalysis, type: DWRITE_TEXTURE_TYPE, bounds: ^RECT, alpha: [^]u8, size: u32) -> HRESULT,
	GetAlphaBlendParams:   rawptr,
}

IDWriteFontFallback :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteFontFallback_VTable,
}
IDWriteFontFallback_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	MapCharacters: proc "system" (this: ^IDWriteFontFallback, source: ^IDWriteTextAnalysisSource, position, length: u32,
		base_collection: ^IDWriteFontCollection, base_family: [^]u16, weight: DWRITE_FONT_WEIGHT, style: DWRITE_FONT_STYLE,
		stretch: DWRITE_FONT_STRETCH, mapped_length: ^u32, mapped_font: ^^IDWriteFont, scale: ^f32) -> HRESULT,
}

IDWriteColorGlyphRunEnumerator :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IDWriteColorGlyphRunEnumerator_VTable,
}
IDWriteColorGlyphRunEnumerator_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	MoveNext:      proc "system" (this: ^IDWriteColorGlyphRunEnumerator, has_run: ^BOOL) -> HRESULT,
	GetCurrentRun: proc "system" (this: ^IDWriteColorGlyphRunEnumerator, run: ^^DWRITE_COLOR_GLYPH_RUN) -> HRESULT,
}

IDWriteColorGlyphRunEnumerator1 :: struct #raw_union {
	#subtype base: IDWriteColorGlyphRunEnumerator,
	using vtable: ^IDWriteColorGlyphRunEnumerator1_VTable,
}
IDWriteColorGlyphRunEnumerator1_VTable :: struct {
	using base_vtable: IDWriteColorGlyphRunEnumerator_VTable,
	GetCurrentRun1: proc "system" (this: ^IDWriteColorGlyphRunEnumerator1, run: ^^DWRITE_COLOR_GLYPH_RUN1) -> HRESULT,
}

////////////////////////////////
// Interfaces implemented by the package (com.odin)

IDWriteFontFileStream :: struct {
	vtable: ^IDWriteFontFileStream_VTable,
}
IDWriteFontFileStream_VTable :: struct {
	QueryInterface:      proc "system" (this: ^IDWriteFontFileStream, riid: ^IID, out: ^rawptr) -> HRESULT,
	AddRef:              proc "system" (this: ^IDWriteFontFileStream) -> u32,
	Release:             proc "system" (this: ^IDWriteFontFileStream) -> u32,
	ReadFileFragment:    proc "system" (this: ^IDWriteFontFileStream, start: ^rawptr, offset, size: u64, ctx: ^rawptr) -> HRESULT,
	ReleaseFileFragment: proc "system" (this: ^IDWriteFontFileStream, ctx: rawptr),
	GetFileSize:         proc "system" (this: ^IDWriteFontFileStream, size: ^u64) -> HRESULT,
	GetLastWriteTime:    proc "system" (this: ^IDWriteFontFileStream, time: ^u64) -> HRESULT,
}

IDWriteFontFileLoader :: struct {
	vtable: ^IDWriteFontFileLoader_VTable,
}
IDWriteFontFileLoader_VTable :: struct {
	QueryInterface:      proc "system" (this: ^IDWriteFontFileLoader, riid: ^IID, out: ^rawptr) -> HRESULT,
	AddRef:              proc "system" (this: ^IDWriteFontFileLoader) -> u32,
	Release:             proc "system" (this: ^IDWriteFontFileLoader) -> u32,
	CreateStreamFromKey: proc "system" (this: ^IDWriteFontFileLoader, key: rawptr, key_size: u32, stream: ^^IDWriteFontFileStream) -> HRESULT,
}

IDWriteTextAnalysisSource :: struct {
	vtable: ^IDWriteTextAnalysisSource_VTable,
}
IDWriteTextAnalysisSource_VTable :: struct {
	QueryInterface:               proc "system" (this: ^IDWriteTextAnalysisSource, riid: ^IID, out: ^rawptr) -> HRESULT,
	AddRef:                       proc "system" (this: ^IDWriteTextAnalysisSource) -> u32,
	Release:                      proc "system" (this: ^IDWriteTextAnalysisSource) -> u32,
	GetTextAtPosition:            proc "system" (this: ^IDWriteTextAnalysisSource, position: u32, text: ^[^]u16, length: ^u32) -> HRESULT,
	GetTextBeforePosition:        proc "system" (this: ^IDWriteTextAnalysisSource, position: u32, text: ^[^]u16, length: ^u32) -> HRESULT,
	GetParagraphReadingDirection: proc "system" (this: ^IDWriteTextAnalysisSource) -> DWRITE_READING_DIRECTION,
	GetLocaleName:                proc "system" (this: ^IDWriteTextAnalysisSource, position: u32, length: ^u32, locale: ^[^]u16) -> HRESULT,
	GetNumberSubstitution:        proc "system" (this: ^IDWriteTextAnalysisSource, position: u32, length: ^u32, substitution: ^rawptr) -> HRESULT,
}

IDWriteTextAnalysisSink :: struct {
	vtable: ^IDWriteTextAnalysisSink_VTable,
}
IDWriteTextAnalysisSink_VTable :: struct {
	QueryInterface:        proc "system" (this: ^IDWriteTextAnalysisSink, riid: ^IID, out: ^rawptr) -> HRESULT,
	AddRef:                proc "system" (this: ^IDWriteTextAnalysisSink) -> u32,
	Release:               proc "system" (this: ^IDWriteTextAnalysisSink) -> u32,
	SetScriptAnalysis:     proc "system" (this: ^IDWriteTextAnalysisSink, position, length: u32, analysis: ^DWRITE_SCRIPT_ANALYSIS) -> HRESULT,
	SetLineBreakpoints:    proc "system" (this: ^IDWriteTextAnalysisSink, position, length: u32, breakpoints: [^]DWRITE_LINE_BREAKPOINT) -> HRESULT,
	SetBidiLevel:          proc "system" (this: ^IDWriteTextAnalysisSink, position, length: u32, explicit_level, resolved_level: u8) -> HRESULT,
	SetNumberSubstitution: proc "system" (this: ^IDWriteTextAnalysisSink, position, length: u32, substitution: rawptr) -> HRESULT,
}

// Releases a COM object (nil-safe).
com_release :: proc "contextless" (p: ^$T) {
	if p != nil {
		u := (^IUnknown)(p)
		u->Release()
	}
}

com_query :: proc "contextless" (p: ^$T, iid: ^IID, $U: typeid) -> ^U {
	if p == nil { return nil }
	out: rawptr
	u := (^IUnknown)(p)
	if u->QueryInterface(iid, &out) < 0 { return nil }
	return (^U)(out)
}

ot_tag :: proc "contextless" (s: string) -> u32 {
	t: [4]u8 = {' ', ' ', ' ', ' '}
	for i in 0 ..< min(len(s), 4) { t[i] = s[i] }
	return u32(t[0]) | u32(t[1]) << 8 | u32(t[2]) << 16 | u32(t[3]) << 24
}
