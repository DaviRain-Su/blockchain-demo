const std = @import("std");
const Blockchain = @import("blockchain.zig").Blockchain;
const Node = @import("network.zig").Node;
const Message = @import("network.zig").Message;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // program name

    const port_str = args.next() orelse "8000";
    const peer_port_str = args.next() orelse "8001";

    const port = try std.fmt.parseInt(u16, port_str, 10);
    const peer_port = try std.fmt.parseInt(u16, peer_port_str, 10);

    var bc = Blockchain.init(allocator);
    defer bc.deinit();

    // Create genesis block
    try bc.createGenesisBlock("Genesis Block");

    var node = Node.init(allocator, port);
    defer node.deinit();

    // Connect to peer if different port
    if (port != peer_port) {
        const peer_address = try std.net.Address.parseIp4("127.0.0.1", peer_port);
        node.connectToPeer(peer_address) catch |err| {
            std.debug.print("Failed to connect to peer: {}\n", .{err});
        };
    }

    // Start server in a thread
    const server_thread = try std.Thread.spawn(.{}, Node.startServer, .{ &node, &bc });
    defer server_thread.join();

    // Start mining in a thread
    const mining_thread = try std.Thread.spawn(.{}, miningLoop, .{ &bc, &node });
    defer mining_thread.join();

    // Wait
    std.Thread.sleep(std.time.ns_per_s * 10);
}

fn miningLoop(bc: *Blockchain, node: *Node) void {
    while (true) {
        const latest = bc.getLatestBlock() orelse continue;
        const timestamp = std.time.timestamp();
        var new_block = @import("blockchain.zig").Block.init(bc.allocator, latest.index + 1, timestamp, latest.hash, "New Block");
        new_block.mine(24);

        bc.mutex.lock();
        defer bc.mutex.unlock();
        if (new_block.index == bc.blocks.items.len) {
            bc.addBlockUnsafe(new_block) catch {};
            node.broadcastMessage(Message{ .block = new_block }) catch {};
            std.debug.print("Mined new block: {}\n", .{new_block.index});
        }
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
