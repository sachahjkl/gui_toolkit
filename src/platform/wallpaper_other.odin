#+build !windows
#+build !linux
package platform

set_wallpaper :: proc(path: string) -> Wallpaper_Result { return .Unsupported }
