#+build !linux
package crashsite

// Off Linux: nothing to arm (Windows: gt:testkit/unwatched names the module and offset).
arm :: proc() {}
