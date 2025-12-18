const std = @import("std");
const Blockchain = @import("blockchain.zig").Blockchain;
const Block = @import("blockchain.zig").Block;
const Node = @import("network.zig").Node;
const Message = @import("network.zig").Message;

/// 挖矿线程上下文
const MiningContext = struct {
    blockchain: *Blockchain,
    node: *Node,
    running: *bool,
    difficulty: u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 解析命令行参数
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // 跳过程序名

    const port_str = args.next() orelse "8000";
    const peer_port_str = args.next() orelse "8001";

    const port = try std.fmt.parseInt(u16, port_str, 10);
    const peer_port = try std.fmt.parseInt(u16, peer_port_str, 10);

    // 创建区块链
    var bc = Blockchain.init(allocator);
    defer bc.deinit();

    // 创建创世块
    try bc.createGenesisBlock("Genesis Block");
    std.debug.print("Genesis block created\n", .{});

    // 创建网络节点
    var node = try Node.init(allocator, port, &bc);
    defer node.deinit();

    // 启动服务器
    try node.startServer();

    // 连接到对等节点（如果端口不同）
    if (port != peer_port) {
        const peer_address = try std.net.Address.parseIp4("127.0.0.1", peer_port);
        node.connectToPeer(peer_address) catch |err| {
            std.debug.print("Failed to connect to peer: {}\n", .{err});
        };
    }

    // 运行状态
    var running: bool = true;

    // 挖矿上下文
    var mining_ctx = MiningContext{
        .blockchain = &bc,
        .node = node,
        .running = &running,
        .difficulty = 24,
    };

    // 启动挖矿线程
    const mining_thread = try std.Thread.spawn(.{}, miningLoop, .{&mining_ctx});

    // 主循环：运行事件循环
    std.debug.print("Starting event loop...\n", .{});

    var last_log_time: i64 = std.time.timestamp();

    while (running) {
        // 运行事件循环的一次迭代
        node.tick() catch |err| {
            std.debug.print("Event loop error: {}\n", .{err});
            break;
        };

        // 每5秒显示当前区块高度
        const now = std.time.timestamp();
        if (now - last_log_time >= 5) {
            bc.mutex.lock();
            const height = bc.blocks.items.len;
            bc.mutex.unlock();
            std.debug.print("[STATUS] Current blockchain height: {}\n", .{height});
            last_log_time = now;
        }

        // 短暂休眠避免CPU空转
        std.Thread.sleep(std.time.ns_per_ms * 10);
    }

    // 等待挖矿线程结束
    running = false;
    mining_thread.join();

    std.debug.print("Shutdown complete\n", .{});
}

/// 挖矿循环（在独立线程中运行）
fn miningLoop(ctx: *MiningContext) void {
    std.debug.print("Mining thread started\n", .{});

    while (ctx.running.*) {
        // 获取最新区块
        const latest = ctx.blockchain.getLatestBlock() orelse continue;

        // 创建新区块
        const timestamp = std.time.timestamp();
        var new_block = Block.init(
            ctx.blockchain.allocator,
            latest.index + 1,
            timestamp,
            latest.hash,
            "New Block",
        );

        // 执行工作量证明（CPU密集型操作）
        new_block.mine(ctx.difficulty);

        // 尝试添加区块
        ctx.blockchain.mutex.lock();
        defer ctx.blockchain.mutex.unlock();

        // 检查区块是否仍然有效（可能其他节点已添加了区块）
        if (new_block.index == ctx.blockchain.blocks.items.len) {
            ctx.blockchain.addBlockUnsafe(new_block) catch continue;

            std.debug.print("Mined new block: {}\n", .{new_block.index});

            // 将区块加入广播队列
            ctx.node.queueBlockBroadcast(new_block);
        } else {
            // 区块已过时，释放资源
            new_block.deinit(ctx.blockchain.allocator);
        }
    }

    std.debug.print("Mining thread stopped\n", .{});
}
