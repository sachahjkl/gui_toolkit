type: Fixed

**Wrapped text**: the lines kept between builds no longer live in the allocator of the context at the first wrap (a program that changes `context.allocator` around a build freed them from another one).
