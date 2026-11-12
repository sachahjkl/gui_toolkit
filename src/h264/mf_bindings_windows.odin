#+build windows
package tk_h264

// Media Foundation's interfaces and calls, declared with no projection (as src/capture/capture_wgc_windows.odin does):
// vtables in the order of the SDK's headers (mfobjects.h, mftransform.h, strmif.h for ICodecAPI); the methods this
// package calls are typed, the others are placeholders that keep the offsets. mfplat.dll is loaded at run time: an
// N edition of Windows has no Media Foundation, and the program starts all the same.

import "core:sync"
import win "core:sys/windows"
import winrt "../winrt"

@(private) GUID :: winrt.GUID
@(private) HRESULT :: win.HRESULT

@(private) MF_VERSION :: 0x0002_0070
@(private) MFSTARTUP_FULL :: 0

@(private) MFT_ENUM_FLAG_SYNCMFT :: 0x01
@(private) MFT_ENUM_FLAG_HARDWARE :: 0x04
@(private) MFT_ENUM_FLAG_SORTANDFILTER :: 0x40

@(private) MFT_MESSAGE_COMMAND_DRAIN :: 0x1
@(private) MFT_MESSAGE_NOTIFY_BEGIN_STREAMING :: 0x1000_0000
@(private) MFT_MESSAGE_NOTIFY_END_STREAMING :: 0x1000_0001
@(private) MFT_MESSAGE_NOTIFY_END_OF_STREAM :: 0x1000_0002
@(private) MFT_MESSAGE_NOTIFY_START_OF_STREAM :: 0x1000_0003

@(private) MFT_OUTPUT_STREAM_PROVIDES_SAMPLES :: 0x100
@(private) MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES :: 0x200

@(private) ME_TRANSFORM_NEED_INPUT :: 601
@(private) ME_TRANSFORM_HAVE_OUTPUT :: 602
@(private) ME_TRANSFORM_DRAIN_COMPLETE :: 603
@(private) MF_EVENT_FLAG_NO_WAIT :: 1

@(private) MF_E_TRANSFORM_NEED_MORE_INPUT :: 0xC00D6D72
@(private) MF_E_TRANSFORM_STREAM_CHANGE :: 0xC00D6D61
@(private) MF_E_NOTACCEPTING :: 0xC00D36B5
@(private) MF_E_NO_EVENTS_AVAILABLE :: 0xC00D3E80
@(private) E_NOTIMPL :: 0x80004001

@(private) MF_VIDEO_INTERLACE_PROGRESSIVE :: 2
@(private) MF_NOMINAL_RANGE_16_235 :: 2
@(private) MF_VIDEO_TRANSFER_MATRIX_BT709 :: 1
@(private) MF_VIDEO_PRIMARIES_BT709 :: 2
@(private) MF_VIDEO_TRANSFER_FUNCTION_709 :: 5

@(private) AV_ENC_H264_PROFILE_MAIN :: 77
@(private) AV_ENC_H264_PROFILE_HIGH :: 100

@(private) AV_ENC_RATE_CONTROL_CBR :: 0
@(private) AV_ENC_RATE_CONTROL_UNCONSTRAINED_VBR :: 2
@(private) AV_ENC_RATE_CONTROL_QUALITY :: 3

@(private) VT_BOOL :: 11
@(private) VT_UI4 :: 19
@(private) VT_UI8 :: 21
@(private) VARIANT_TRUE :: 0xFFFF

// The ids, as variables: the calls take their addresses.
@(private) MFT_CATEGORY_VIDEO_ENCODER := GUID{0xf79eac7d, 0xe545, 0x4387, {0xbd, 0xee, 0xd6, 0x47, 0xd7, 0xbd, 0xe4, 0x2a}}
@(private) MF_MEDIA_TYPE_VIDEO := GUID{0x73646976, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
@(private) MF_VIDEO_FORMAT_NV12 := GUID{0x3231564E, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
@(private) MF_VIDEO_FORMAT_H264 := GUID{0x34363248, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
@(private) MF_MT_MAJOR_TYPE := GUID{0x48eba18e, 0xf8c9, 0x4687, {0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f}}
@(private) MF_MT_SUBTYPE := GUID{0xf7e34c9a, 0x42e8, 0x4714, {0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5}}
@(private) MF_MT_FRAME_SIZE := GUID{0x1652c33d, 0xd6b2, 0x4012, {0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d}}
@(private) MF_MT_FRAME_RATE := GUID{0xc459a2e8, 0x3d2c, 0x4e44, {0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0}}
@(private) MF_MT_PIXEL_ASPECT_RATIO := GUID{0xc6376a1e, 0x8d0a, 0x4027, {0xbe, 0x45, 0x6d, 0x9a, 0x0a, 0xd3, 0x9b, 0xb6}}
@(private) MF_MT_INTERLACE_MODE := GUID{0xe2724bb8, 0xe676, 0x4806, {0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd}}
@(private) MF_MT_TRANSFER_FUNCTION := GUID{0x5fb0fce9, 0xbe5c, 0x4935, {0xa8, 0x11, 0xec, 0x83, 0x8f, 0x8e, 0xed, 0x93}}
@(private) MF_MT_VIDEO_PRIMARIES := GUID{0xdbfbe4d7, 0x0740, 0x4ee0, {0x81, 0x92, 0x85, 0x0a, 0xb0, 0xe2, 0x19, 0x35}}
@(private) MF_MT_YUV_MATRIX := GUID{0x3e23d450, 0x2c75, 0x4d25, {0xa0, 0x0e, 0xb9, 0x16, 0x70, 0xd1, 0x23, 0x27}}
@(private) MF_MT_VIDEO_NOMINAL_RANGE := GUID{0xc21b8ee5, 0xb956, 0x4071, {0x8d, 0xaf, 0x32, 0x5e, 0xdf, 0x5c, 0xab, 0x11}}
@(private) MF_MT_AVG_BITRATE := GUID{0x20332624, 0xfb0d, 0x4d9e, {0xbd, 0x0d, 0xcb, 0xf6, 0x78, 0x6c, 0x10, 0x2e}}
@(private) MF_MT_MPEG2_PROFILE := GUID{0xad76a80b, 0x2d5c, 0x4e0b, {0xb3, 0x75, 0x64, 0xe5, 0x20, 0x13, 0x70, 0x36}}
@(private) MF_MT_MPEG_SEQUENCE_HEADER := GUID{0x3c036de7, 0x3ad0, 0x4c9e, {0x92, 0x16, 0xee, 0x6d, 0x6a, 0xc2, 0x1c, 0xb3}}
@(private) MF_TRANSFORM_ASYNC := GUID{0xf81a699a, 0x649a, 0x497d, {0x8c, 0x73, 0x29, 0xf8, 0xfe, 0xd6, 0xad, 0x7a}}
@(private) MF_TRANSFORM_ASYNC_UNLOCK := GUID{0xe5666d6b, 0x3422, 0x4eb6, {0xa4, 0x21, 0xda, 0x7d, 0xb1, 0xf8, 0xe2, 0x07}}
@(private) MF_SAMPLE_EXTENSION_CLEAN_POINT := GUID{0x9cdf01d8, 0xa0f0, 0x43ba, {0xb0, 0x77, 0xea, 0xa0, 0x6c, 0xbd, 0x72, 0x8a}}
@(private) IID_IMFTransform := GUID{0xbf94c121, 0x5b05, 0x4e6f, {0x80, 0x00, 0xba, 0x59, 0x89, 0x61, 0x41, 0x4d}}
@(private) IID_IMFMediaEventGenerator := GUID{0x2cd0bd52, 0xbcd5, 0x4b89, {0xb6, 0x2c, 0xea, 0xdc, 0x0c, 0x03, 0x1e, 0x7d}}
@(private) IID_ICodecAPI := GUID{0x901db4c7, 0x31ce, 0x41a2, {0x85, 0xdc, 0x8f, 0xa0, 0xbf, 0x41, 0xb8, 0xda}}
@(private) CODECAPI_AVEncCommonRateControlMode := GUID{0x1c0608e9, 0x370c, 0x4710, {0x8a, 0x58, 0xcb, 0x61, 0x81, 0xc4, 0x24, 0x23}}
@(private) CODECAPI_AVEncCommonQuality := GUID{0xfcbf57a3, 0x7ea5, 0x4b0c, {0x96, 0x44, 0x69, 0xb4, 0x0c, 0x39, 0xc3, 0x91}}
@(private) CODECAPI_AVEncCommonMeanBitRate := GUID{0xf7222374, 0x2144, 0x4815, {0xb5, 0x50, 0xa3, 0x7f, 0x8e, 0x12, 0xee, 0x52}}
@(private) CODECAPI_AVEncVideoEncodeQP := GUID{0x2cb5696b, 0x23fb, 0x4ce1, {0xa0, 0xf9, 0xef, 0x5b, 0x90, 0xfd, 0x55, 0xca}}
@(private) CODECAPI_AVEncVideoForceKeyFrame := GUID{0x398c1b98, 0x8353, 0x475a, {0x9e, 0xf2, 0x8f, 0x26, 0x5d, 0x26, 0x03, 0x45}}
@(private) CODECAPI_AVEncMPVGOPSize := GUID{0x95f31b26, 0x95a4, 0x41aa, {0x93, 0x03, 0x24, 0x6a, 0x7f, 0xc6, 0xee, 0xf1}}
@(private) CODECAPI_AVEncMPVDefaultBPictureCount := GUID{0x8d390aac, 0xdc5c, 0x4200, {0xb5, 0x7f, 0x81, 0x4d, 0x04, 0xba, 0xba, 0xb2}}
@(private) CODECAPI_AVLowLatencyMode := GUID{0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}}

@(private)
MFT_Register_Type_Info :: struct {
	major_type: GUID,
	subtype:    GUID,
}

@(private)
MFT_Output_Stream_Info :: struct {
	flags:     u32,
	size:      u32,
	alignment: u32,
}

@(private)
MFT_Output_Data_Buffer :: struct {
	stream_id: u32,
	sample:    rawptr,   // IMFSample
	status:    u32,
	events:    rawptr,   // IMFCollection
}

// A VARIANT as ICodecAPI reads it: its type, then the value in the union (24 bytes on 64 bits; on 32 bits the struct is
// larger than Windows' 16, which SetValue only reads).
@(private)
Variant :: struct {
	vt:       u16,
	reserved: [3]u16,
	value:    u64,
	record:   rawptr,
}

@(private)
IUnknown_Vtbl :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: rawptr) -> u32,
	Release:        proc "system" (this: rawptr) -> u32,
}

@(private)
IMFAttributes_Vtbl :: struct {
	using unknown:      IUnknown_Vtbl,
	GetItem:            rawptr,
	GetItemType:        rawptr,
	CompareItem:        rawptr,
	Compare:            rawptr,
	GetUINT32:          proc "system" (this: rawptr, key: ^GUID, value: ^u32) -> HRESULT,
	GetUINT64:          rawptr,
	GetDouble:          rawptr,
	GetGUID:            rawptr,
	GetStringLength:    rawptr,
	GetString:          rawptr,
	GetAllocatedString: rawptr,
	GetBlobSize:        proc "system" (this: rawptr, key: ^GUID, size: ^u32) -> HRESULT,
	GetBlob:            proc "system" (this: rawptr, key: ^GUID, buffer: [^]u8, size: u32, written: ^u32) -> HRESULT,
	GetAllocatedBlob:   rawptr,
	GetUnknown:         rawptr,
	SetItem:            rawptr,
	DeleteItem:         rawptr,
	DeleteAllItems:     rawptr,
	SetUINT32:          proc "system" (this: rawptr, key: ^GUID, value: u32) -> HRESULT,
	SetUINT64:          proc "system" (this: rawptr, key: ^GUID, value: u64) -> HRESULT,
	SetDouble:          rawptr,
	SetGUID:            proc "system" (this: rawptr, key: ^GUID, value: ^GUID) -> HRESULT,
	SetString:          rawptr,
	SetBlob:            rawptr,
	SetUnknown:         rawptr,
	LockStore:          rawptr,
	UnlockStore:        rawptr,
	GetCount:           rawptr,
	GetItemByIndex:     rawptr,
	CopyAllItems:       rawptr,
}

@(private)
IMFMediaType_Vtbl :: struct {
	using attributes:   IMFAttributes_Vtbl,
	GetMajorType:       rawptr,
	IsCompressedFormat: rawptr,
	IsEqual:            rawptr,
	GetRepresentation:  rawptr,
	FreeRepresentation: rawptr,
}

@(private)
IMFSample_Vtbl :: struct {
	using attributes:          IMFAttributes_Vtbl,
	GetSampleFlags:            rawptr,
	SetSampleFlags:            rawptr,
	GetSampleTime:             proc "system" (this: rawptr, time: ^i64) -> HRESULT,
	SetSampleTime:             proc "system" (this: rawptr, time: i64) -> HRESULT,
	GetSampleDuration:         rawptr,
	SetSampleDuration:         proc "system" (this: rawptr, duration: i64) -> HRESULT,
	GetBufferCount:            rawptr,
	GetBufferByIndex:          rawptr,
	ConvertToContiguousBuffer: proc "system" (this: rawptr, buffer: ^rawptr) -> HRESULT,
	AddBuffer:                 proc "system" (this: rawptr, buffer: rawptr) -> HRESULT,
	RemoveBufferByIndex:       rawptr,
	RemoveAllBuffers:          rawptr,
	GetTotalLength:            rawptr,
	CopyToBuffer:              rawptr,
}

@(private)
IMFMediaBuffer_Vtbl :: struct {
	using unknown:    IUnknown_Vtbl,
	Lock:             proc "system" (this: rawptr, data: ^[^]u8, max_length: ^u32, current_length: ^u32) -> HRESULT,
	Unlock:           proc "system" (this: rawptr) -> HRESULT,
	GetCurrentLength: proc "system" (this: rawptr, length: ^u32) -> HRESULT,
	SetCurrentLength: proc "system" (this: rawptr, length: u32) -> HRESULT,
	GetMaxLength:     rawptr,
}

@(private)
IMFActivate_Vtbl :: struct {
	using attributes: IMFAttributes_Vtbl,
	ActivateObject:   proc "system" (this: rawptr, riid: ^GUID, object: ^rawptr) -> HRESULT,
	ShutdownObject:   proc "system" (this: rawptr) -> HRESULT,
	DetachObject:     rawptr,
}

@(private)
IMFMediaEventGenerator_Vtbl :: struct {
	using unknown: IUnknown_Vtbl,
	GetEvent:      proc "system" (this: rawptr, flags: u32, event: ^rawptr) -> HRESULT,
	BeginGetEvent: rawptr,
	EndGetEvent:   rawptr,
	QueueEvent:    rawptr,
}

@(private)
IMFMediaEvent_Vtbl :: struct {
	using attributes: IMFAttributes_Vtbl,
	GetType:          proc "system" (this: rawptr, type: ^u32) -> HRESULT,
	GetExtendedType:  rawptr,
	GetStatus:        proc "system" (this: rawptr, status: ^HRESULT) -> HRESULT,
	GetValue:         rawptr,
}

@(private)
IMFTransform_Vtbl :: struct {
	using unknown:             IUnknown_Vtbl,
	GetStreamLimits:           rawptr,
	GetStreamCount:            rawptr,
	GetStreamIDs:              proc "system" (this: rawptr, input_size: u32, input_ids: [^]u32, output_size: u32, output_ids: [^]u32) -> HRESULT,
	GetInputStreamInfo:        rawptr,
	GetOutputStreamInfo:       proc "system" (this: rawptr, stream: u32, info: ^MFT_Output_Stream_Info) -> HRESULT,
	GetAttributes:             proc "system" (this: rawptr, attributes: ^rawptr) -> HRESULT,
	GetInputStreamAttributes:  rawptr,
	GetOutputStreamAttributes: rawptr,
	DeleteInputStream:         rawptr,
	AddInputStreams:           rawptr,
	GetInputAvailableType:     rawptr,
	GetOutputAvailableType:    proc "system" (this: rawptr, stream: u32, index: u32, type: ^rawptr) -> HRESULT,
	SetInputType:              proc "system" (this: rawptr, stream: u32, type: rawptr, flags: u32) -> HRESULT,
	SetOutputType:             proc "system" (this: rawptr, stream: u32, type: rawptr, flags: u32) -> HRESULT,
	GetInputCurrentType:       rawptr,
	GetOutputCurrentType:      proc "system" (this: rawptr, stream: u32, type: ^rawptr) -> HRESULT,
	GetInputStatus:            rawptr,
	GetOutputStatus:           rawptr,
	SetOutputBounds:           rawptr,
	ProcessEvent:              rawptr,
	ProcessMessage:            proc "system" (this: rawptr, message: u32, param: uintptr) -> HRESULT,
	ProcessInput:              proc "system" (this: rawptr, stream: u32, sample: rawptr, flags: u32) -> HRESULT,
	ProcessOutput:             proc "system" (this: rawptr, flags: u32, count: u32, buffers: [^]MFT_Output_Data_Buffer, status: ^u32) -> HRESULT,
}

@(private)
ICodecAPI_Vtbl :: struct {
	using unknown:            IUnknown_Vtbl,
	IsSupported:              rawptr,
	IsModifiable:             rawptr,
	GetParameterRange:        rawptr,
	GetParameterValues:       rawptr,
	GetDefaultValue:          rawptr,
	GetValue:                 rawptr,
	SetValue:                 proc "system" (this: rawptr, api: ^GUID, value: ^Variant) -> HRESULT,
	RegisterForEvent:         rawptr,
	UnregisterForEvent:       rawptr,
	SetAllDefaults:           rawptr,
	SetValueWithNotify:       rawptr,
	SetAllDefaultsWithNotify: rawptr,
	GetAllSettings:           rawptr,
	SetAllSettings:           rawptr,
	SetAllSettingsWithNotify: rawptr,
}

// The vtable of a COM object as `T`.
@(private)
vtable_of :: #force_inline proc(object: rawptr, $T: typeid) -> ^T { return (^^T)(object)^ }

@(private)
com_release :: proc(object: rawptr) {
	if object != nil { vtable_of(object, IUnknown_Vtbl).Release(object) }
}

@(private)
com_query :: proc(object: rawptr, iid: ^GUID) -> rawptr {
	out: rawptr
	if vtable_of(object, IUnknown_Vtbl).QueryInterface(object, iid, &out) < 0 { return nil }
	return out
}

@(private)
MF_Library :: struct {
	startup:              proc "system" (version: u32, flags: u32) -> HRESULT,
	shutdown:             proc "system" () -> HRESULT,
	enum_ex:              proc "system" (category: GUID, flags: u32, input: ^MFT_Register_Type_Info, output: ^MFT_Register_Type_Info, activates: ^[^]rawptr, count: ^u32) -> HRESULT,
	create_media_type:    proc "system" (type: ^rawptr) -> HRESULT,
	create_sample:        proc "system" (sample: ^rawptr) -> HRESULT,
	create_memory_buffer: proc "system" (max_length: u32, buffer: ^rawptr) -> HRESULT,
}

@(private) mf: MF_Library
@(private = "file") mf_once: sync.Once
@(private = "file") mf_found: bool

// mfplat.dll, once for the process; false on a system without Media Foundation.
@(private)
mf_load :: proc() -> bool {
	sync.once_do(&mf_once, proc() {
		h := win.LoadLibraryW(win.L("mfplat.dll"))
		if h == nil { return }
		mf.startup = auto_cast win.GetProcAddress(h, "MFStartup")
		mf.shutdown = auto_cast win.GetProcAddress(h, "MFShutdown")
		mf.enum_ex = auto_cast win.GetProcAddress(h, "MFTEnumEx")
		mf.create_media_type = auto_cast win.GetProcAddress(h, "MFCreateMediaType")
		mf.create_sample = auto_cast win.GetProcAddress(h, "MFCreateSample")
		mf.create_memory_buffer = auto_cast win.GetProcAddress(h, "MFCreateMemoryBuffer")
		if mf.startup == nil || mf.shutdown == nil || mf.enum_ex == nil || mf.create_media_type == nil ||
		   mf.create_sample == nil || mf.create_memory_buffer == nil {
			mf = {}
			win.FreeLibrary(h)
			return
		}
		mf_found = true
	})
	return mf_found
}
