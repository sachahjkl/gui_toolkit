#+build !windows
#+build !linux
package platform

// Printing on the systems with no implementation yet (print.odin): the dialog is not there.
print_image :: proc(owner: ^Window, title: string, rgba: []u8, size: [2]int) -> Print_Status { return .Unsupported }
