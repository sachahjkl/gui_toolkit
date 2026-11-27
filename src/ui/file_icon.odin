package ui

// A file's icon by its type, for every list of files (the file tree; src/md/features/tree-view.md): Lucide's file
// icons, by the name's extension and a few whole names; code by the syntax package's languages.

import "core:strings"
import "../ascii"
import lucide "../lucide"
import syntax "../syntax"

// The glyph of an entry named `name`: a folder (open or closed), a link, or a file by its type.
file_icon :: proc(name: string, folder: bool, open := false, link := false) -> string {
	if folder {
		if name == ".git" { return lucide.FOLDER_GIT_2 }
		if link { return lucide.FOLDER_SYMLINK }
		return open ? lucide.FOLDER_OPEN : lucide.FOLDER
	}
	if link { return lucide.FILE_SYMLINK }
	switch ascii.lower(name) {
	case "dockerfile", "containerfile":                return lucide.FILE_BOX
	case "makefile", "justfile", "gnumakefile":        return lucide.FILE_TERMINAL
	case "license", "licence", "copying", "notice":    return lucide.FILE_BADGE_2
	case ".gitignore", ".gitattributes", ".gitmodules", ".editorconfig", ".envrc", ".env": return lucide.FILE_COG_2
	}
	dot := strings.last_index_byte(name, '.')
	if dot < 0 || dot == len(name) - 1 { return lucide.FILE }
	switch ascii.lower(name[dot + 1:]) {
	case "png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "ico", "tif", "tiff", "avif", "heic", "qoi": return lucide.FILE_IMAGE
	case "mp4", "mkv", "webm", "mov", "avi", "m4v":     return lucide.FILE_VIDEO_2
	case "mp3", "wav", "flac", "ogg", "opus", "m4a", "aac": return lucide.FILE_MUSIC
	case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "deb", "rpm": return lucide.FILE_ARCHIVE
	case "json", "jsonc", "json5":                      return lucide.FILE_BRACES
	case "yaml", "yml", "toml", "ini", "conf", "cfg", "properties": return lucide.FILE_COG_2
	case "md", "markdown", "rst", "txt", "log", "pdf", "rtf", "doc", "docx", "odt": return lucide.FILE_TEXT
	case "csv", "tsv", "xlsx", "xls", "ods", "db", "sqlite": return lucide.FILE_SPREADSHEET
	case "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd": return lucide.FILE_TERMINAL
	case "lock":                                        return lucide.FILE_LOCK_2
	case "pem", "key", "crt", "cer", "p12", "pfx", "pub", "asc", "gpg": return lucide.FILE_KEY_2
	case "ttf", "otf", "woff", "woff2":                 return lucide.FILE_TYPE
	case "diff", "patch":                               return lucide.FILE_DIFF
	case "exe", "dll", "so", "dylib", "bin", "wasm", "msi", "appimage": return lucide.FILE_BOX
	}
	if _, ok := syntax.language_of_file(name); ok { return lucide.FILE_CODE }
	return lucide.FILE
}
