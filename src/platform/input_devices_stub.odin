#+build !windows
package platform

// The systems without an implementation say they have a mouse and nothing else.
@(private)
input_devices_query :: proc() -> Input_Devices { return Input_Devices{mouse = true} }
