# AGENTS.md

This document helps AI agents work effectively in this repository.

## Project Overview

A simple blockchain demonstration implemented in Zig. Features:
- Proof-of-work mining with configurable difficulty
- SHA-256 hashing for blocks
- Peer-to-peer networking over TCP
- Thread-safe blockchain operations
- Binary message serialization protocol

## Essential Commands

```bash
# Build the project
zig build

# Run the executable (default ports: 8000 listen, 8001 peer)
zig build run

# Run with custom ports: <listen_port> <peer_port>
zig build run -- 8001 8000

# Run all tests
zig build test

# Run tests with fuzz testing
zig build test --fuzz
```

## Project Structure

```
blockchain-demo/
├── build.zig           # Build configuration (defines targets, modules, steps)
├── build.zig.zon       # Package manifest (name, version, dependencies)
├── src/
│   ├── main.zig        # Entry point, CLI args, spawns server & mining threads
│   ├── blockchain.zig  # Block and Blockchain structs, mining logic
│   ├── network.zig     # Peer-to-peer networking, message serialization
│   └── root.zig        # Library module entry point (exposed to consumers)
├── zig-out/            # Build output directory
└── .zig-cache/         # Compilation cache
```

## Code Organization

### Modules

| Module | Purpose | Key Types |
|--------|---------|-----------|
| `blockchain.zig` | Core blockchain logic | `Block`, `Blockchain` |
| `network.zig` | P2P networking | `Node`, `Peer`, `Message`, `MessageType` |
| `root.zig` | Library exports | (utility functions) |
| `main.zig` | Application entry | `main()`, `miningLoop()` |

### Build System

- **Executable**: `blockchain_demo` (from `src/main.zig`)
- **Library module**: `blockchain_demo` (from `src/root.zig`)
- Tests run on both modules separately via `zig build test`

## Code Patterns

### Memory Management

- Uses `std.heap.GeneralPurposeAllocator` in main
- All allocating functions take `std.mem.Allocator` parameter
- Structs have explicit `init()` and `deinit()` methods
- `defer` used for cleanup: `defer bc.deinit();`

```zig
// Pattern: allocator-aware struct
pub fn init(allocator: std.mem.Allocator, ...) Type {
    return Type{
        .allocator = allocator,
        ...
    };
}

pub fn deinit(self: *Type) void {
    // Free allocator-owned memory
    self.allocator.free(...);
}
```

### Thread Safety

- Structs with shared state include `mutex: std.Thread.Mutex`
- Pattern: `mutex.lock(); defer mutex.unlock();`
- `addBlockUnsafe()` exists for when caller already holds lock

### Error Handling

- Functions return `!Type` for fallible operations
- `try` for propagating errors
- `catch unreachable` for "impossible" allocation failures in init
- `catch {}` or `catch |err| { ... }` for recoverable errors

### Naming Conventions

- Types: `PascalCase` (`Block`, `Blockchain`, `MessageType`)
- Functions/methods: `camelCase` (`calculateHash`, `addBlock`)
- Constants/fields: `snake_case` (`prev_hash`, `request_blocks`)
- Enums: `snake_case` variants (`request_blocks`, `response_blocks`)

## Key Implementation Details

### Block Structure

```zig
Block {
    index: u32,           // Block number in chain
    timestamp: i64,       // Unix timestamp
    prev_hash: [32]u8,    // SHA-256 of previous block
    data: []const u8,     // Block payload
    hash: [32]u8,         // This block's hash
    nonce: u64,           // Proof-of-work value
}
```

### Mining (Proof of Work)

- Difficulty measured in leading zero bits
- Default difficulty: 2 (first 2 bits must be zero)
- Uses `std.crypto.hash.sha2.Sha256`

### Network Protocol

- TCP-based peer connections on localhost
- Binary serialization with little-endian integers
- Message types: `block`, `request_blocks`, `response_blocks`
- Fixed 1024-byte read buffer for incoming messages

## Testing

Tests are embedded in source files using Zig's built-in test framework:

```zig
test "test name" {
    // Use std.testing.allocator for memory leak detection
    const allocator = std.testing.allocator;
    ...
    try std.testing.expectEqual(expected, actual);
}
```

### Test Locations

- `main.zig`: Basic tests and fuzz test example
- `root.zig`: `add` function test

### Fuzz Testing

```bash
zig build test --fuzz
```

Example in `main.zig:75-84` shows fuzz testing pattern.

## Dependencies

- **External**: None (uses Zig standard library only)
- **Minimum Zig version**: 0.15.2

## Gotchas and Non-Obvious Patterns

1. **ArrayList initialization**: Uses `initCapacity(allocator, 0) catch unreachable` pattern rather than `.init(allocator)`

2. **Deinit requires allocator**: ArrayList `deinit` takes allocator: `self.blocks.deinit(self.allocator)`

3. **Writer pattern**: ArrayList writer needs allocator: `buffer.writer(allocator)`

4. **Mining loop runs forever**: `miningLoop()` in main.zig has `while (true)` - main sleeps 10 seconds then exits

5. **Unsafe block addition**: `addBlockUnsafe()` skips locking - caller must hold mutex

6. **Enum to int**: Use `@intFromEnum()` and `@enumFromInt()` for serialization

7. **Fixed buffer reads**: Network reads into fixed 1024-byte buffer - large messages may truncate

8. **Genesis block**: Created with difficulty 2, all-zero previous hash

## Common Tasks

### Adding a new message type

1. Add variant to `MessageType` enum in `network.zig`
2. Add corresponding field to `Message` union
3. Add serialization case in `serializeMessage()`
4. Add deserialization case in `deserializeMessage()`
5. Handle in `Node.handleConnection()` switch

### Changing mining difficulty

Currently hardcoded to 2 in multiple places:
- `blockchain.zig:81` - genesis block
- `blockchain.zig:90` - new blocks via `addBlock()`
- `main.zig:55` - mining loop

Consider extracting to constant or making configurable.

### Running multiple nodes

```bash
# Terminal 1
zig build run -- 8000 8001

# Terminal 2  
zig build run -- 8001 8000
```
