const std = @import("std");
const xev = @import("xev");
const Block = @import("blockchain.zig").Block;
const Blockchain = @import("blockchain.zig").Blockchain;
const builtin = @import("builtin");

/// 设置 socket 为非阻塞模式
fn setNonBlocking(fd: std.posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        // Windows 使用不同的方式
        return;
    }
    // macOS/Linux: 使用 fcntl
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const O_NONBLOCK: i32 = 0x0004; // macOS

    const flags = std.posix.system.fcntl(fd, F_GETFL, @as(i32, 0));
    if (flags != -1) {
        _ = std.posix.system.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
}

/// 消息类型
pub const MessageType = enum(u8) {
    block = 0,
    request_blocks = 1,
    response_blocks = 2,
};

/// 网络消息
pub const Message = union(MessageType) {
    block: Block,
    request_blocks: u32, // 从哪个索引开始请求
    response_blocks: []Block,
};

/// 序列化消息
pub fn serializeMessage(allocator: std.mem.Allocator, msg: Message) ![]u8 {
    var buffer = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
    errdefer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

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
        .request_blocks => |start_index| {
            try writer.writeInt(u32, start_index, .little);
        },
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

/// 反序列化消息
pub fn deserializeMessage(allocator: std.mem.Allocator, data: []const u8) !Message {
    if (data.len < 1) return error.InvalidMessage;
    const msg_type: MessageType = @enumFromInt(data[0]);
    var fbs = std.io.fixedBufferStream(data[1..]);
    const reader = fbs.reader();

    switch (msg_type) {
        .block => {
            const index = try reader.readInt(u32, .little);
            const timestamp = try reader.readInt(i64, .little);
            var prev_hash: [32]u8 = undefined;
            _ = try reader.readAll(&prev_hash);
            const data_len = try reader.readInt(u32, .little);
            const data_buf = try allocator.alloc(u8, data_len);
            errdefer allocator.free(data_buf);
            _ = try reader.readAll(data_buf);
            var hash: [32]u8 = undefined;
            _ = try reader.readAll(&hash);
            const nonce = try reader.readInt(u64, .little);

            return Message{ .block = Block{
                .index = index,
                .timestamp = timestamp,
                .prev_hash = prev_hash,
                .data = data_buf,
                .hash = hash,
                .nonce = nonce,
            } };
        },
        .request_blocks => {
            const start_index = try reader.readInt(u32, .little);
            return Message{ .request_blocks = start_index };
        },
        .response_blocks => {
            const num_blocks = try reader.readInt(u32, .little);
            const blocks = try allocator.alloc(Block, num_blocks);
            errdefer allocator.free(blocks);
            for (0..num_blocks) |i| {
                const index = try reader.readInt(u32, .little);
                const timestamp = try reader.readInt(i64, .little);
                var prev_hash: [32]u8 = undefined;
                _ = try reader.readAll(&prev_hash);
                const data_len = try reader.readInt(u32, .little);
                const data_buf = try allocator.alloc(u8, data_len);
                _ = try reader.readAll(data_buf);
                var hash: [32]u8 = undefined;
                _ = try reader.readAll(&hash);
                const nonce = try reader.readInt(u64, .little);

                blocks[i] = Block{
                    .index = index,
                    .timestamp = timestamp,
                    .prev_hash = prev_hash,
                    .data = data_buf,
                    .hash = hash,
                    .nonce = nonce,
                };
            }
            return Message{ .response_blocks = blocks };
        },
    }
}

/// 基于 libxev 的网络节点
pub const Node = struct {
    allocator: std.mem.Allocator,
    loop: xev.Loop,
    server: ?xev.TCP,
    port: u16,
    blockchain: *Blockchain,

    // 连接的对等节点 (只存储 fd)
    peer_fds: std.ArrayList(std.posix.fd_t),
    peers_mutex: std.Thread.Mutex,

    // 服务器相关
    server_completion: xev.Completion,

    // 新区块通知队列 (从挖矿线程到事件循环)
    block_queue: std.ArrayList(Block),
    block_queue_mutex: std.Thread.Mutex,

    // 运行状态
    running: bool,

    // 读取缓冲区 (用于接收连接)
    read_buf: [4096]u8,

    // 连接完成状态
    connect_completion: xev.Completion,
    connect_tcp: ?xev.TCP,

    pub fn init(allocator: std.mem.Allocator, port: u16, blockchain: *Blockchain) !*Node {
        const node = try allocator.create(Node);
        node.* = Node{
            .allocator = allocator,
            .loop = try xev.Loop.init(.{}),
            .server = null,
            .port = port,
            .blockchain = blockchain,
            .peer_fds = std.ArrayList(std.posix.fd_t).initCapacity(allocator, 0) catch unreachable,
            .peers_mutex = .{},
            .server_completion = .{},
            .block_queue = std.ArrayList(Block).initCapacity(allocator, 0) catch unreachable,
            .block_queue_mutex = .{},
            .running = true,
            .read_buf = undefined,
            .connect_completion = .{},
            .connect_tcp = null,
        };
        return node;
    }

    pub fn deinit(self: *Node) void {
        self.running = false;

        // 关闭所有对等连接
        self.peers_mutex.lock();
        for (self.peer_fds.items) |fd| {
            std.posix.close(fd);
        }
        self.peer_fds.deinit(self.allocator);
        self.peers_mutex.unlock();

        // 清理区块队列
        self.block_queue_mutex.lock();
        self.block_queue.deinit(self.allocator);
        self.block_queue_mutex.unlock();

        self.loop.deinit();
        self.allocator.destroy(self);
    }

    /// 启动服务器
    pub fn startServer(self: *Node) !void {
        const address = try std.net.Address.parseIp4("127.0.0.1", self.port);
        var server = try xev.TCP.init(address);
        try server.bind(address);
        try server.listen(128);
        self.server = server;

        std.debug.print("Server listening on port {}\n", .{self.port});

        // 开始接受连接
        server.accept(&self.loop, &self.server_completion, Node, self, acceptCallback);
    }

    fn acceptCallback(
        node_opt: ?*Node,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        const node = node_opt orelse return .disarm;

        if (result) |client_tcp| {
            std.debug.print("New connection accepted\n", .{});

            // 设置为非阻塞模式
            setNonBlocking(client_tcp.fd);

            // 保存 fd
            node.peers_mutex.lock();
            node.peer_fds.append(node.allocator, client_tcp.fd) catch {};
            node.peers_mutex.unlock();
        } else |err| {
            std.debug.print("Accept error: {}\n", .{err});
        }

        // 继续接受新连接
        return .rearm;
    }

    /// 处理收到的区块，返回需要同步的起始索引（如果需要的话）
    fn handleReceivedBlock(self: *Node, block: Block, _: std.posix.fd_t) ?u32 {
        self.blockchain.mutex.lock();
        defer self.blockchain.mutex.unlock();

        const local_height = self.blockchain.blocks.items.len;
        std.debug.print("[RECV] Block index={}, local_height={}\n", .{ block.index, local_height });

        if (block.index == local_height) {
            if (local_height > 0) {
                const prev_block = &self.blockchain.blocks.items[block.index - 1];
                const hash_match = std.mem.eql(u8, &block.prev_hash, &prev_block.hash);
                const valid_hash = std.mem.eql(u8, &block.hash, &block.calculateHash());

                if (hash_match and valid_hash) {
                    self.blockchain.addBlockUnsafe(block) catch {};
                    std.debug.print("[RECV] Added block: {}\n", .{block.index});
                } else {
                    std.debug.print("[RECV] Rejected block {}: hash_match={}, valid_hash={}\n", .{ block.index, hash_match, valid_hash });
                }
            }
            return null;
        } else if (block.index > local_height) {
            std.debug.print("[RECV] Block {} is ahead, need sync from {}\n", .{ block.index, local_height });
            return @intCast(local_height);
        } else {
            std.debug.print("[RECV] Block {} already exists or is old\n", .{block.index});
            return null;
        }
    }

    /// 连接到对等节点 (同步方式，简化处理)
    pub fn connectToPeer(self: *Node, address: std.net.Address) !void {
        // 使用标准库的同步连接
        const stream = std.net.tcpConnectToAddress(address) catch |err| {
            std.debug.print("Connect error: {}\n", .{err});
            return err;
        };

        // 设置为非阻塞模式
        setNonBlocking(stream.handle);

        std.debug.print("Connected to peer\n", .{});

        self.peers_mutex.lock();
        self.peer_fds.append(self.allocator, stream.handle) catch {};
        self.peers_mutex.unlock();
    }

    /// 广播消息给所有对等节点
    pub fn broadcastMessage(self: *Node, msg: Message) !void {
        const data = try serializeMessage(self.allocator, msg);
        defer self.allocator.free(data);

        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        for (self.peer_fds.items) |fd| {
            const stream = std.net.Stream{ .handle = fd };
            _ = stream.write(data) catch continue;
        }
    }

    /// 将区块加入广播队列（从挖矿线程调用）
    pub fn queueBlockBroadcast(self: *Node, block: Block) void {
        self.block_queue_mutex.lock();
        defer self.block_queue_mutex.unlock();
        self.block_queue.append(self.allocator, block) catch {};
    }

    /// 处理队列中的区块广播
    pub fn processPendingBroadcasts(self: *Node) void {
        self.block_queue_mutex.lock();
        const blocks = self.block_queue.toOwnedSlice(self.allocator) catch {
            self.block_queue_mutex.unlock();
            return;
        };
        self.block_queue_mutex.unlock();

        defer self.allocator.free(blocks);

        for (blocks) |block| {
            self.broadcastMessage(Message{ .block = block }) catch continue;
        }
    }

    /// 轮询接收数据 (非阻塞)
    pub fn pollReceive(self: *Node) void {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        for (self.peer_fds.items) |fd| {
            // 非阻塞读取
            var buf: [4096]u8 = undefined;
            const n = std.posix.read(fd, &buf) catch |err| {
                if (err == error.WouldBlock) continue;
                std.debug.print("[POLL] Read error: {}\n", .{err});
                continue;
            };

            if (n == 0) continue; // 连接关闭

            std.debug.print("[POLL] Received {} bytes\n", .{n});

            if (deserializeMessage(self.allocator, buf[0..n])) |msg| {
                switch (msg) {
                    .block => |block| {
                        const need_sync = self.handleReceivedBlock(block, fd);
                        if (need_sync) |start_index| {
                            // 请求缺失的区块
                            self.requestBlocks(fd, start_index);
                        }
                    },
                    .request_blocks => |start_index| {
                        self.handleBlockRequest(fd, start_index);
                    },
                    .response_blocks => |blocks| {
                        self.handleBlocksResponse(blocks);
                    },
                }
            } else |err| {
                std.debug.print("[POLL] Deserialize error: {}\n", .{err});
            }
        }
    }

    /// 请求区块
    fn requestBlocks(self: *Node, fd: std.posix.fd_t, start_index: u32) void {
        std.debug.print("[SYNC] Requesting blocks from index {}\n", .{start_index});
        const data = serializeMessage(self.allocator, Message{ .request_blocks = start_index }) catch return;
        defer self.allocator.free(data);
        const stream = std.net.Stream{ .handle = fd };
        _ = stream.write(data) catch {};
    }

    /// 处理区块请求
    fn handleBlockRequest(self: *Node, fd: std.posix.fd_t, start_index: u32) void {
        self.blockchain.mutex.lock();
        defer self.blockchain.mutex.unlock();

        const len = self.blockchain.blocks.items.len;
        if (start_index >= len) return;

        // 最多发送 10 个区块
        const end_index = @min(start_index + 10, len);
        const blocks_to_send = self.blockchain.blocks.items[start_index..end_index];

        std.debug.print("[SYNC] Sending blocks {} to {}\n", .{ start_index, end_index - 1 });

        const data = serializeMessage(self.allocator, Message{ .response_blocks = blocks_to_send }) catch return;
        defer self.allocator.free(data);
        const stream = std.net.Stream{ .handle = fd };
        _ = stream.write(data) catch {};
    }

    /// 处理区块响应 - 实现最长链规则
    fn handleBlocksResponse(self: *Node, blocks: []Block) void {
        if (blocks.len == 0) return;

        self.blockchain.mutex.lock();
        defer self.blockchain.mutex.unlock();

        std.debug.print("[SYNC] Received {} blocks, first={}, last={}\n", .{ blocks.len, blocks[0].index, blocks[blocks.len - 1].index });

        // 找到分叉点：第一个收到的区块的前一个区块
        const first_block = blocks[0];

        // 验证第一个区块能否接上
        if (first_block.index == 0) {
            // 创世块，忽略
            return;
        }

        if (first_block.index > self.blockchain.blocks.items.len) {
            std.debug.print("[SYNC] Still missing blocks before {}\n", .{first_block.index});
            return;
        }

        // 检查是否能接上本地链
        if (first_block.index <= self.blockchain.blocks.items.len) {
            const local_prev = &self.blockchain.blocks.items[first_block.index - 1];
            if (!std.mem.eql(u8, &first_block.prev_hash, &local_prev.hash)) {
                // 分叉！检查收到的链是否更长
                // 简化处理：如果收到的区块能形成更长的链，替换本地分叉部分
                std.debug.print("[SYNC] Fork detected at index {}, replacing local chain\n", .{first_block.index});

                // 移除本地分叉的区块
                while (self.blockchain.blocks.items.len > first_block.index - 1) {
                    if (self.blockchain.blocks.pop()) |removed| {
                        var block_copy = removed;
                        block_copy.deinit(self.allocator);
                    } else break;
                }
            }
        }

        // 依次添加区块
        for (blocks) |block| {
            if (block.index == self.blockchain.blocks.items.len) {
                if (self.blockchain.blocks.items.len > 0) {
                    const prev_block = &self.blockchain.blocks.items[block.index - 1];
                    if (std.mem.eql(u8, &block.prev_hash, &prev_block.hash) and
                        std.mem.eql(u8, &block.hash, &block.calculateHash()))
                    {
                        self.blockchain.addBlockUnsafe(block) catch {};
                        std.debug.print("[SYNC] Added block: {}\n", .{block.index});
                    } else {
                        std.debug.print("[SYNC] Block {} validation failed\n", .{block.index});
                        break;
                    }
                }
            }
        }
    }

    /// 运行事件循环
    pub fn run(self: *Node) !void {
        try self.loop.run(.until_done);
    }

    /// 运行一次事件循环迭代
    pub fn tick(self: *Node) !void {
        // 处理待广播的区块
        self.processPendingBroadcasts();

        // 轮询接收数据
        self.pollReceive();

        // 运行一次事件循环 (主要用于 accept)
        try self.loop.run(.no_wait);
    }
};
