#+build linux
package tk_desktop

// Linux system context-menu parsers: KIO service menus, Nemo actions, and Thunar uca.xml against synthetic Xdg_Roots,
// plus command expansion and end-to-end invocation.

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

@(test)
linux_context_menu_parses_kio_nemo_and_thunar :: proc(t: ^testing.T) {
	base := fmt.tprintf("%s/gt_ctxmenu_%d", os.temp_dir(context.temp_allocator), os.get_pid())
	_ = os.remove_all(base)
	defer _ = os.remove_all(base)

	data_dir := fmt.tprintf("%s/data", base)
	cfg_dir  := fmt.tprintf("%s/config", base)
	work_dir := fmt.tprintf("%s/work", base)
	sub_dir  := fmt.tprintf("%s/work/folder", base)
	out_file := fmt.tprintf("%s/ran.txt", base)
	photo    := fmt.tprintf("%s/pic.png", work_dir)
	doc      := fmt.tprintf("%s/note.txt", work_dir)

	for d in ([?]string{
		fmt.tprintf("%s/mime", data_dir),
		fmt.tprintf("%s/kio/servicemenus", data_dir),
		fmt.tprintf("%s/nemo/actions", data_dir),
		fmt.tprintf("%s/Thunar", cfg_dir),
		sub_dir,
	}) {
		testing.expect(t, os.make_directory_all(d) == nil, d)
	}
	_ = os.write_entire_file(photo, transmute([]u8)string("png"))
	_ = os.write_entire_file(doc, transmute([]u8)string("txt"))
	_ = os.write_entire_file(fmt.tprintf("%s/mime/globs2", data_dir), transmute([]u8)string("50:image/png:*.png\n50:text/plain:*.txt\n"))

	// KIO service menu with submenu for images
	kio_desktop := fmt.tprintf(`[Desktop Entry]
Type=Service
MimeType=image/*;
Actions=optimize;flip;
X-KDE-Submenu=Image Tools

[Desktop Action optimize]
Name=Optimize PNG
Exec=/bin/sh -c "printf 'kio:%%s\n' \"$1\" >> '%s'" sh %%f

[Desktop Action flip]
Name=Flip Horizontal
Exec=/bin/echo %%f
`, out_file)
	_ = os.write_entire_file(fmt.tprintf("%s/kio/servicemenus/images.desktop", data_dir), transmute([]u8)kio_desktop)

	// Nemo action for txt files only
	nemo_action := `[Nemo Action]
Name=Count Lines
Exec=/bin/wc -l %F
Selection=s
Extensions=txt;
`
	_ = os.write_entire_file(fmt.tprintf("%s/nemo/actions/count.nemo_action", data_dir), transmute([]u8)nemo_action)

	// Thunar custom action for directories
	thunar_uca := `<?xml version="1.0" encoding="UTF-8"?>
<actions>
<action>
	<name>Open Terminal Here</name>
	<submenu></submenu>
	<command>/bin/echo %f</command>
	<patterns>*</patterns>
	<directories/>
</action>
<action>
	<name>Inspect Image</name>
	<submenu>Extras</submenu>
	<command>/bin/echo %f</command>
	<patterns>*.png</patterns>
	<image-files/>
</action>
</actions>
`
	_ = os.write_entire_file(fmt.tprintf("%s/Thunar/uca.xml", cfg_dir), transmute([]u8)thunar_uca)

	roots := Xdg_Roots{data = {data_dir}, config = {cfg_dir}}
	db := mime_database(roots, context.temp_allocator)
	ns: Context_Menu_Native
	defer context_menu_native_clear(&ns)

	// 1. Query on pic.png: matches KIO Image Tools submenu + Thunar Extras/Inspect Image; NOT Nemo txt or Thunar dir.
	img_items := linux_context_query(&ns, &db, roots, {paths = {photo}}, context.allocator)
	defer context_items_destroy(img_items, context.allocator)
	testing.expect_value(t, len(img_items), 2)
	kio_opt_id := u32(0)
	if len(img_items) == 2 {
		testing.expect_value(t, img_items[0].label, "Image Tools")
		testing.expect_value(t, len(img_items[0].children), 2)
		if len(img_items[0].children) == 2 {
			testing.expect_value(t, img_items[0].children[0].label, "Optimize PNG")
			kio_opt_id = img_items[0].children[0].id
		}
		testing.expect_value(t, img_items[1].label, "Extras")
		testing.expect_value(t, len(img_items[1].children), 1)
		if len(img_items[1].children) == 1 {
			testing.expect_value(t, img_items[1].children[0].label, "Inspect Image")
		}
	}

	// Invoke KIO Optimize PNG and verify the command actually ran with the photo path.
	testing.expect(t, kio_opt_id > 0 && context_menu_native_invoke(&ns, kio_opt_id, nil), "invoke KIO action")
	deadline := time.tick_add(time.tick_now(), 2 * time.Second)
	ran := ""
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if data, err := os.read_entire_file(out_file, context.temp_allocator); err == nil && len(data) > 0 {
			ran = string(data)
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, ran, fmt.tprintf("kio:%s\n", photo))

	// 2. Query on note.txt: matches Nemo Count Lines alone.
	context_menu_native_clear(&ns)
	txt_items := linux_context_query(&ns, &db, roots, {paths = {doc}}, context.allocator)
	defer context_items_destroy(txt_items, context.allocator)
	testing.expect_value(t, len(txt_items), 1)
	if len(txt_items) == 1 { testing.expect_value(t, txt_items[0].label, "Count Lines") }

	// 3. Query on folder: matches Thunar Open Terminal Here alone.
	context_menu_native_clear(&ns)
	dir_items := linux_context_query(&ns, &db, roots, {paths = {sub_dir}}, context.allocator)
	defer context_items_destroy(dir_items, context.allocator)
	testing.expect_value(t, len(dir_items), 1)
	if len(dir_items) == 1 { testing.expect_value(t, dir_items[0].label, "Open Terminal Here") }
}
