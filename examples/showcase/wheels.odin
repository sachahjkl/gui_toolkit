package showcase

// The wheels' scene: a delay in a duration field, its drums open below it (ui.duration_field); an alarm's time in a
// field of two parts (ui.parts_field); a date of three drums (a month's days follow its length); a lone drum of words.
// Each card says the value it holds.

import "core:fmt"
import lucide "gt:lucide"
import "gt:ui"

@(private = "file", rodata) MONTHS := [?]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
@(private = "file", rodata) SIZES := [?]string{"Small", "Medium", "Large", "Larger"}

wheels_build :: proc(app: ^App, em: f32) {
	heading("Wheels", "A field of parts is typed or stepped part by part (Left, Right, Up, Down, digits); a click opens its drums. ui.wheel turns a column of values on a drum: the wheel, a drag and a throw, a click on a row, the keys. It rests on a row with a detent, and the program gets one change, at rest.", em)
	left :: proc(app: ^App, em: f32) {
		delay_card(app, em)
		alarm_card(app, em)
	}
	right :: proc(app: ^App, em: f32) {
		date_card(app, em)
		size_card(app, em)
	}
	columns(app, "###wheels_columns", em, left, right)
}

// The value a card holds, under its control.
@(private = "file")
said :: proc(text: string, em: f32) {
	ui.spacer(ui.px(em * 0.6))
	if ui.muted() { ui.label(text) }
}

@(private = "file")
delay_card :: proc(app: ^App, em: f32) {
	if ui.card("Lock the screen after", lucide.TIMER) {
		// (open at the first build: the picture shows the drums)
		if app.builds <= 1 { app.delay_open = true }
		ui.duration_field("###delay", &app.delay, least = 60, o = {open = &app.delay_open})
		h, m := app.delay / 3600, app.delay % 3600 / 60
		said(h > 0 ? fmt.tprintf("%d h %02d min###delay_said", h, m) : fmt.tprintf("%d min###delay_said", m), em)
		// (room for the drums below the field, over the card's foot)
		ui.spacer(ui.px(em * 9))
	}
}

@(private = "file")
alarm_card :: proc(app: ^App, em: f32) {
	if ui.card("Alarm", lucide.ALARM_CLOCK) {
		parts := [2]ui.Field_Part{{hi = 23, format = "%02d", wrap = true}, {hi = 55, step = 5, format = "%02d", before = ":", wrap = true}}
		values := [2]int{app.alarm_h, app.alarm_m}
		if ui.parts_field("###alarm", parts[:], values[:]) { app.alarm_h, app.alarm_m = values[0], values[1] }
		said(fmt.tprintf("Rings at %02d:%02d###alarm_said", app.alarm_h, app.alarm_m), em)
	}
}

@(private = "file")
date_card :: proc(app: ^App, em: f32) {
	if ui.card("Date", lucide.CALENDAR) {
		month := app.month - 1
		if ui.wheels("###date") {
			ui.wheel_number("###day", &app.day, 1, days_in(app.month, app.year), o = {wrap = true})
			if ui.wheel("###month", MONTHS[:], &month, {wrap = true}) { app.month = month + 1 }
			ui.wheel_number("###year", &app.year, 1970, 2100)
		}
		app.day = min(app.day, days_in(app.month, app.year))
		said(fmt.tprintf("%d %s %d###date_said", app.day, MONTHS[app.month - 1], app.year), em)
	}
}

@(private = "file")
size_card :: proc(app: ^App, em: f32) {
	if ui.card("Size", lucide.RULER) {
		ui.wheel("###size", SIZES[:], &app.size, {rows = 3})
		said(fmt.tprintf("%s###size_said", SIZES[app.size]), em)
	}
}

@(private = "file")
days_in :: proc(month, year: int) -> int {
	switch month {
	case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
	case 4, 6, 9, 11: return 30
	}
	return 31
}
