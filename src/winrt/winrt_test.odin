package tk_winrt

import "core:testing"

// The IDs of generic instances, computed from their signatures, are those of the SDK's headers.
@(test)
generic_ids_are_those_of_the_sdk :: proc(t: ^testing.T) {
	op, handler := async_iids(SIG_STRING)
	// IAsyncOperation<HSTRING>, AsyncOperationCompletedHandler<HSTRING> (windows.foundation.h)
	testing.expect_value(t, guid_string(op), "{3e1fe603-f897-5263-b328-0806426b8a79}")
	testing.expect_value(t, guid_string(handler), "{b79a741f-7fb5-50ae-9e99-911201ec3d41}")
	// IVectorView<HSTRING> (windows.foundation.collections.h)
	testing.expect_value(t, guid_string(piid_of(sig_generic(PIID_IVectorView, SIG_STRING))), "{2f13c006-a03a-5f69-b090-75a43e33423e}")
}

@(test)
signatures_are_written_as_windows_reads_them :: proc(t: ^testing.T) {
	iid := GUID{0xe6dfdee6, 0x0ee2, 0x52e3, {0x85, 0x2b, 0xf2, 0x95, 0xdb, 0x65, 0x93, 0x9a}}
	testing.expect_value(t, sig_class("Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult", iid),
		"rc(Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult;{e6dfdee6-0ee2-52e3-852b-f295db65939a})")
	testing.expect_value(t, sig_generic(PIID_IAsyncOperation, SIG_STRING), "pinterface({9fc2b0bb-e446-44e2-aa61-9cab8f636af2};string)")
}

// TypedEventHandler<ToastNotification, T>: the IDs of windows.ui.notifications.h (the toasts' events, platform/notify_windows.odin).
@(test)
typed_event_handler_ids_are_those_of_the_sdk :: proc(t: ^testing.T) {
	toast := sig_class("Windows.UI.Notifications.ToastNotification", GUID{0x997e2675, 0x059e, 0x4e60, {0x8b, 0x06, 0x17, 0x60, 0x91, 0x7c, 0x8b, 0x80}})
	dismissed := sig_class("Windows.UI.Notifications.ToastDismissedEventArgs", GUID{0x3f89d935, 0xd9cb, 0x4538, {0xa0, 0xf0, 0xff, 0xe7, 0x65, 0x99, 0x38, 0xf8}})
	failed := sig_class("Windows.UI.Notifications.ToastFailedEventArgs", GUID{0x35176862, 0xcfd4, 0x44f8, {0xad, 0x64, 0xf5, 0x00, 0xfd, 0x89, 0x6c, 0x3b}})
	testing.expect_value(t, guid_string(typed_event_handler_iid(toast, SIG_INSPECTABLE)), "{ab54de2d-97d9-5528-b6ad-105afe156530}")
	testing.expect_value(t, guid_string(typed_event_handler_iid(toast, dismissed)), "{61c2402f-0ed0-5a18-ab69-59f4aa99a368}")
	testing.expect_value(t, guid_string(typed_event_handler_iid(toast, failed)), "{95e3e803-c969-5e3a-9753-ea2ad22a9a33}")
}
