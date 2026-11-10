#+build !linux
package platform

// No list of the interfaces here yet: nil.
interface_addresses :: proc(allocator := context.allocator) -> []Interface_Address { return nil }
