#+build windows
package font

import win "core:sys/windows"

@(private) SPI_GETFONTSMOOTHING :: 0x004A
@(private) SPI_GETFONTSMOOTHINGTYPE :: 0x200A
@(private) SPI_GETFONTSMOOTHINGORIENTATION :: 0x2012
@(private) FE_FONTSMOOTHINGCLEARTYPE :: 2
@(private) FE_FONTSMOOTHINGORIENTATIONBGR :: 0

// What the system does with text: its ClearType setting, and the order of the stripes the tuner found.
system_subpixel_text :: proc() -> Subpixel_Text {
	on: win.BOOL
	kind, order: u32
	if !win.SystemParametersInfoW(SPI_GETFONTSMOOTHING, 0, &on, 0) || !on { return .Off }
	if !win.SystemParametersInfoW(SPI_GETFONTSMOOTHINGTYPE, 0, &kind, 0) || kind != FE_FONTSMOOTHINGCLEARTYPE { return .Off }
	if !win.SystemParametersInfoW(SPI_GETFONTSMOOTHINGORIENTATION, 0, &order, 0) { return .Rgb }
	return order == FE_FONTSMOOTHINGORIENTATIONBGR ? .Bgr : .Rgb
}
