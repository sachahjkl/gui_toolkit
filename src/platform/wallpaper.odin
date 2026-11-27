package platform

// The desktop's background (src/md/features/wallpaper.md): set_wallpaper(path) gives a picture to the system, per
// system: Windows' SystemParametersInfo (SPI_SETDESKWALLPAPER), Linux's desktop portal
// (org.freedesktop.portal.Wallpaper, which GNOME's and KDE's portals answer), elsewhere Unsupported. It blocks until the
// system answers, and a portal may show the picture and ask the person first: call it on a worker (ui.task), never on
// the interface's thread.

Wallpaper_Result :: enum u8 {
	Set,           // the background is the picture
	Cancelled,     // the person said no (a portal's preview)
	Unsupported,   // this system, or this desktop, has no way the toolkit knows: the program says so
	Failed,        // the file could not be read, or the system refused it
}
