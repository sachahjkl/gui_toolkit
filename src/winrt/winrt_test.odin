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
