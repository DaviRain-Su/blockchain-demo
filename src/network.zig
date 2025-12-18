const std = @import("std");
const Block = @import("blockchain.zig").Block;
const Blockchain = @import("blockchain.zig").Blockchain;

pub const MessageType = enum(u8) {
    block,
    request_blocks,
    response_blocks,
};

pub const Message = union(MessageType) {
    block: Block,
    request_blocks: void,
    response_blocks: []Block,
};

pub fn serializeMessage(allocator: std.mem.Allocator, msg: Message) ![]u8 {
    var buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);

    try writer.writeByte(@intFromEnum(msg));
    switch (msg) {
        .block => |block| {
            try writer.writeInt(u32, block.index, .little);
            try writer.writeInt(i64, block.timestamp, .little);
            try writer.writeAll(&block.prev_hash);
            try writer.writeInt(u32, @intCast(block.data.len), .little);
            try writer.writeAll(block.data);
            try writer.writeAll(&block.hash);
            try writer.writeInt(u64, block.nonce, .little);
        },
        .request_blocks => {},
        .response_blocks => |blocks| {
            try writer.writeInt(u32, @intCast(blocks.len), .little);
            for (blocks) |block| {
                try writer.writeInt(u32, block.index, .little);
                try writer.writeInt(i64, block.timestamp, .little);
                try writer.writeAll(&block.prev_hash);
                try writer.writeInt(u32, @intCast(block.data.len), .little);
                try writer.writeAll(block.data);
                try writer.writeAll(&block.hash);
                try writer.writeInt(u64, block.nonce, .little);
            }
        },
    }

    return buffer.toOwnedSlice(allocator);
}

pub fn deserializeMessage(allocator: std.mem.Allocator, data: []const u8) !Message {
    if (data.len < 1) return error.InvalidMessage;
    const msg_type = @as(MessageType, @enumFromInt(data[0]));
    var reader = std.io.fixedBufferStream(data[1..]);
    const r = reader.reader();

    switch (msg_type) {
        .block => {
            const index = try r.readInt(u32, .little);
            const timestamp = try r.readInt(i64, .little);
            var prev_hash: [32]u8 = undefined;
            _ = try r.readAll(&prev_hash);
            const data_len = try r.readInt(u32, .little);
            const data_buf = try allocator.alloc(u8, data_len);
            defer allocator.free(data_buf);
            _ = try r.readAll(data_buf);
            var hash: [32]u8 = undefined;
            _ = try r.readAll(&hash);
            const nonce = try r.readInt(u64, .little);

            var block = Block.init(allocator, index, timestamp, prev_hash, data_buf);
            block.hash = hash;
            block.nonce = nonce;
            return Message{ .block = block };
        },
        .request_blocks => return Message{ .request_blocks = {} },
        .response_blocks => {
            const num_blocks = try r.readInt(u32, .little);
            var blocks = try allocator.alloc(Block, num_blocks);
            for (0..num_blocks) |i| {
                const index = try r.readInt(u32, .little);
                const timestamp = try r.readInt(i64, .little);
                var prev_hash: [32]u8 = undefined;
                _ = try r.readAll(&prev_hash);
                const data_len = try r.readInt(u32, .little);
                const data_buf = try allocator.alloc(u8, data_len);
                defer allocator.free(data_buf);
                _ = try r.readAll(data_buf);
                var hash: [32]u8 = undefined;
                _ = try r.readAll(&hash);
                const nonce = try r.readInt(u64, .little);

                blocks[i] = Block.init(allocator, index, timestamp, prev_hash, data_buf);
                blocks[i].hash = hash;
                blocks[i].nonce = nonce;
            }
            return Message{ .response_blocks = blocks };
        },
    }
}

pub const Peer = struct {
    address: std.net.Address,
    stream: std.net.Stream,
};

pub const Node = struct {
    allocator: std.mem.Allocator,
    port: u16,
    peers: std.ArrayList(Peer),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, port: u16) Node {
        return Node{
            .allocator = allocator,
            .port = port,
            .peers = std.ArrayList(Peer).initCapacity(allocator, 0) catch unreachable,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Node) void {
        for (self.peers.items) |*peer| {
            peer.stream.close();
        }
        self.peers.deinit(self.allocator);
    }

    pub fn connectToPeer(self: *Node, address: std.net.Address) !void {
        const stream = try std.net.tcpConnectToAddress(address);
        const peer = Peer{ .address = address, .stream = stream };
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.peers.append(self.allocator, peer);
    }

    pub fn broadcastMessage(self: *Node, msg: Message) !void {
        const data = try serializeMessage(self.allocator, msg);
        defer self.allocator.free(data);

        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.peers.items) |*peer| {
            _ = peer.stream.write(data) catch {};
        }
    }

    pub fn startServer(self: *Node, blockchain: *Blockchain) !void {
        const address = try std.net.Address.parseIp4("127.0.0.1", self.port);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        while (true) {
            const conn = try server.accept();
            const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, conn.stream, blockchain });
            thread.detach();
        }
    }

    fn handleConnection(self: *Node, stream: std.net.Stream, blockchain: *Blockchain) void {
        defer stream.close();
        var buffer: [1024]u8 = undefined;
        while (true) {
            const bytes_read = stream.read(&buffer) catch break;
            if (bytes_read == 0) break;
            const msg = deserializeMessage(self.allocator, buffer[0..bytes_read]) catch continue;
            switch (msg) {
                .block => |block| {
                    // Validate and add block
                    blockchain.mutex.lock();
                    defer blockchain.mutex.unlock();
                    if (block.index == blockchain.blocks.items.len) {
                        const prev_block = &blockchain.blocks.items[block.index - 1];
                        if (std.mem.eql(u8, &block.prev_hash, &prev_block.hash) and std.mem.eql(u8, &block.hash, &block.calculateHash())) {
                            blockchain.addBlockUnsafe(block) catch {};
                        }
                    }
                },
                else => {},
            }
        }
    }
};
